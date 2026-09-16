package r3d_bridge

import "core:fmt"
import "rune:assets"
import "rune:terrain"
import rl "vendor:raylib"
import r3d "r3d:r3d"

Terrain_Layer_Set :: struct {
	atlases: [2]rl.Texture2D,
	parameters, controls: rl.Texture2D,
	signature: u64,
}

release_terrain_layer_set :: proc(set:^Terrain_Layer_Set) {
	for texture in ([4]rl.Texture2D{set.atlases[0],set.atlases[1],set.parameters,set.controls}) {
		if texture.id!=0 {rl.UnloadTexture(texture)}
	}
	set^={}
}

// Copy raw channels, including alpha: control-map A is the fourth layer weight.
copy_layer_pixels :: proc(destination:^rl.Image,source:rl.Image,x_offset,y_offset:i32) {
	src := ([^]rl.Color)(source.data)
	dst := ([^]rl.Color)(destination.data)
	for y:i32=0; y<source.height; y+=1 {for x:i32=0; x<source.width; x+=1 {
		dst[(y+y_offset)*destination.width+x+x_offset]=src[y*source.width+x]
	}}
}

pack_terrain_layers :: proc(layers:[]Terrain_Layer_Asset) -> (rl.Texture2D,bool) {
	size:i32=8
	for layer in layers {size=max(size,layer.texture.width)}
	atlas:=rl.GenImageColor(4*size,4*size,rl.WHITE)
	defer rl.UnloadImage(atlas)
	for layer,i in layers {
		image:=rl.LoadImageFromTexture(layer.texture)
		if image.data==nil {return {},false}
		rl.ImageFormat(&image,.UNCOMPRESSED_R8G8B8A8)
		rl.ImageResizeNN(&image,size,4*size)
		copy_layer_pixels(&atlas,image,i32(i)*size,0)
		rl.UnloadImage(image)
	}
	texture:=rl.LoadTextureFromImage(atlas)
	if !rl.IsTextureValid(texture) {return {},false}
	rl.GenTextureMipmaps(&texture)
	return texture,true
}

pack_terrain_controls :: proc(textures:[]rl.Texture2D) -> (rl.Texture2D,bool) {
	width,height:i32=1,1
	for texture in textures {width=max(width,texture.width); height=max(height,texture.height)}
	width,height=min(width,2048),min(height,2048)
	atlas:=rl.GenImageColor(width,2*height,rl.BLANK)
	defer rl.UnloadImage(atlas)
	for texture,i in textures {
		image:=rl.LoadImageFromTexture(texture)
		if image.data==nil {return {},false}
		rl.ImageFormat(&image,.UNCOMPRESSED_R8G8B8A8)
		rl.ImageResizeNN(&image,width,height)
		copy_layer_pixels(&atlas,image,0,i32(i)*height)
		rl.UnloadImage(image)
	}
	texture:=rl.LoadTextureFromImage(atlas)
	rl.SetTextureFilter(texture,.BILINEAR)
	rl.SetTextureWrap(texture,.CLAMP)
	return texture,rl.IsTextureValid(texture)
}

bind_terrain_layer_set :: proc(ctx:^Context,manager:^assets.Asset_Manager,set:^Terrain_Layer_Set,shader:^r3d.SurfaceShader,d:terrain.Description,base:r3d.Material,source:string) -> bool {
	layers:[terrain.MAX_LAYERS]Terrain_Layer_Asset
	controls:[2]rl.Texture2D
	signature:u64=1
	ready:=true
	for layer,i in d.layers {
		ok:bool
		layers[i],ok=terrain_layer(ctx,manager,layer.material,source,fmt.tprintf("layers[%d].material",i),base)
		ready=ready && ok
		signature=assets.hash_value(signature,layers[i].texture.id)
		signature=assets.hash_value(signature,layers[i].color)
		signature=assets.hash_value(signature,layers[i].pbr)
	}
	for path,i in d.control_maps {
		ok:bool
		controls[i],ok=assets.material_texture(manager,path,"bilinear",false,source,fmt.tprintf("control_maps[%d]",i))
		ready=ready && ok
		signature=assets.hash_value(signature,controls[i].id)
	}
	if ready && (set.parameters.id==0 || set.signature!=signature) {
		next:=Terrain_Layer_Set{signature=signature}
		ok:=true
		for group in 0..<2 {
			start:=min(group*4,len(d.layers)); end:=min(start+4,len(d.layers))
			next.atlases[group],ok=pack_terrain_layers(layers[start:end]); if !ok {break}
		}
		if ok {next.controls,ok=pack_terrain_controls(controls[:len(d.control_maps)])}
		if ok {
			parameters:[6][8][4]f32
			for layer,i in d.layers {
				sampling:=layers[i].sampling
				sampling[1]=f32(next.atlases[i/4].width/4)
				sampling[2]=f32(next.atlases[i/4].mipmaps-1) if layers[i].sampling[2]>0 else 0
				parameters[0][i]=layers[i].color; parameters[1][i]=layers[i].pbr
				parameters[2][i]=sampling
				parameters[3][i]={layer.tile_size[0],layer.tile_size[1],layer.weight,0}
				parameters[4][i]=layer.height; parameters[5][i]=layer.slope
			}
			image:=rl.Image{data=&parameters,width=8,height=6,mipmaps=1,format=.UNCOMPRESSED_R32G32B32A32}
			next.parameters=rl.LoadTextureFromImage(image)
			ok=rl.IsTextureValid(next.parameters)
		}
		if ok {release_terrain_layer_set(set); set^=next} else {
			release_terrain_layer_set(&next)
			assets.report_failure(manager,{kind=.Texture,operation=.Load,source_path=source,field="layers",asset_path=source,detail="could not pack terrain layers; retaining the previous set"})
		}
	}
	if set.parameters.id==0 {return false}
	r3d.SetSurfaceShaderSampler(shader,"u_layers_a",set.atlases[0])
	r3d.SetSurfaceShaderSampler(shader,"u_layers_b",set.atlases[1])
	r3d.SetSurfaceShaderSampler(shader,"u_parameters",set.parameters)
	r3d.SetSurfaceShaderSampler(shader,"u_controls",set.controls)
	info:=[4]f32{d.size[0],d.size[1],f32(len(d.layers)),1 if len(d.control_maps)>0 else 0}
	r3d.SetSurfaceShaderUniform(shader,"u_terrain",&info)
	return true
}
