package r3d_bridge

import "core:fmt"
import "rune:assets"
import "rune:terrain"
import rl "vendor:raylib"
import r3d "r3d:r3d"

Terrain_Layer_Set :: struct {
	atlases: [2]rl.Texture2D,
	parameters: rl.Texture2D,
	signature: u64,
	paint: Terrain_Paint,
}

Terrain_Paint_Source :: struct {
	id: u32,
	revision: u64,
}

Terrain_Paint :: struct {
	texture: rl.Texture2D,
	manager: ^assets.Asset_Manager,
	sources: [2]Terrain_Paint_Source,
	controls: terrain.Control_Map,
}

release_terrain_paint :: proc(paint: ^Terrain_Paint) {
	if paint.texture.id != 0 {rl.UnloadTexture(paint.texture)}
	delete(paint.controls.pixels)
	paint^ = {}
}

release_terrain_layer_set :: proc(set:^Terrain_Layer_Set) {
	for texture in ([3]rl.Texture2D{set.atlases[0],set.atlases[1],set.parameters}) {
		if texture.id!=0 {rl.UnloadTexture(texture)}
	}
	release_terrain_paint(&set.paint)
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

pack_terrain_controls :: proc(paint: ^Terrain_Paint, textures: []rl.Texture2D) -> bool {
	width,height:i32=1,1
	for texture in textures {width=max(width,texture.width); height=max(height,texture.height)}
	width,height=min(width,2048),min(height,2048)
	pixels,allocation_error := make([]u8,8*int(width)*int(height))
	if allocation_error!=nil {return false}
	paint.controls = {width=int(width),height=int(height),pixels=pixels}
	atlas := rl.Image{data=raw_data(pixels),width=width,height=2*height,mipmaps=1,format=.UNCOMPRESSED_R8G8B8A8}
	for texture,i in textures {
		image:=rl.LoadImageFromTexture(texture)
		if image.data==nil {return false}
		rl.ImageFormat(&image,.UNCOMPRESSED_R8G8B8A8)
		rl.ImageResizeNN(&image,width,height)
		valid := image.data!=nil && image.format==.UNCOMPRESSED_R8G8B8A8 && image.width==width && image.height==height
		if valid {copy_layer_pixels(&atlas,image,0,i32(i)*height)}
		if image.data!=nil {rl.UnloadImage(image)}
		if !valid {return false}
	}
	paint.texture=rl.LoadTextureFromImage(atlas)
	if !rl.IsTextureValid(paint.texture) {return false}
	rl.SetTextureFilter(paint.texture,.BILINEAR)
	rl.SetTextureWrap(paint.texture,.CLAMP)
	return true
}

// A staging set owns only replaced resources. Its caller publishes it after
// the dependent detail batches are ready.
stage_terrain_layer_set :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, current,staged: ^Terrain_Layer_Set,
		d: terrain.Description, base: r3d.Material, source: string) {
	layers:[terrain.MAX_LAYERS]Terrain_Layer_Asset
	controls:[2]rl.Texture2D
	paint_sources:[2]Terrain_Paint_Source
	manager_changed := current.paint.manager!=manager
	signature:u64=1
	ready:=true
	for layer,i in d.layers {
		ok:bool
		layers[i],ok=terrain_layer(ctx,manager,layer.material,source,fmt.tprintf("layers[%d].material",i),base)
		ready=ready && ok
		signature=assets.hash_value(signature,layers[i].texture.id)
		signature=assets.hash_value(signature,layers[i].signature)
		signature=assets.hash_value(signature,layers[i].revision)
		signature=assets.hash_value(signature,layers[i].color)
		signature=assets.hash_value(signature,layers[i].pbr)
		signature=assets.hash_value(signature,layers[i].sampling)
	}
	for path,i in d.control_maps {
		ok:bool
		controls[i],ok=assets.material_texture(manager,path,"bilinear",false,source,fmt.tprintf("control_maps[%d]",i))
		ready=ready && ok
		paint_sources[i]={controls[i].id,assets.texture_revision(manager,path)}
	}
	if !ready {return}
	ok := true
	if current.parameters.id==0 || manager_changed || current.signature!=signature {
		staged.signature=signature
		ok=pack_terrain_layer_set(staged,d,layers[:len(d.layers)])
	}
	if ok && (current.paint.texture.id==0 || manager_changed || current.paint.sources!=paint_sources) {
		staged.paint.manager=manager
		staged.paint.sources=paint_sources
		ok=pack_terrain_controls(&staged.paint,controls[:len(d.control_maps)])
	}
	if !ok {
		release_terrain_layer_set(staged)
		assets.report_failure(manager,{kind=.Texture,operation=.Load,source_path=source,field="layers",asset_path=source,detail="could not pack terrain layers; retaining the previous set"})
		return
	}
	assets.resolve_asset_failure(manager,source,"layers",source)
}

pack_terrain_layer_set :: proc(set: ^Terrain_Layer_Set, d: terrain.Description, layers: []Terrain_Layer_Asset) -> bool {
	for group in 0..<2 {
		start,end := min(group*4,len(layers)),min(group*4+4,len(layers))
		texture,ok := pack_terrain_layers(layers[start:end])
		if !ok {return false}
		set.atlases[group]=texture
	}
	parameters:[6][8][4]f32
	for layer,i in d.layers {
		sampling:=layers[i].sampling
		sampling[1]=f32(set.atlases[i/4].width/4)
		sampling[2]=f32(set.atlases[i/4].mipmaps-1) if layers[i].sampling[2]>0 else 0
		parameters[0][i]=layers[i].color; parameters[1][i]=layers[i].pbr
		parameters[2][i]=sampling
		parameters[3][i]={layer.tile_size[0],layer.tile_size[1],layer.weight,f32(terrain.layer_weight_source(layer))}
		parameters[4][i]=layer.height; parameters[5][i]=layer.slope
	}
	image:=rl.Image{data=&parameters,width=8,height=6,mipmaps=1,format=.UNCOMPRESSED_R32G32B32A32}
	set.parameters=rl.LoadTextureFromImage(image)
	return rl.IsTextureValid(set.parameters)
}

publish_terrain_layer_set :: proc(current,staged: ^Terrain_Layer_Set) {
	if staged.parameters.id != 0 {
		current.atlases,staged.atlases = staged.atlases,current.atlases
		current.parameters,staged.parameters = staged.parameters,current.parameters
		current.signature = staged.signature
	}
	if staged.paint.texture.id != 0 {current.paint,staged.paint = staged.paint,current.paint}
}

bind_terrain_layer_set :: proc(set: ^Terrain_Layer_Set, shader: ^r3d.SurfaceShader, d: terrain.Description) {
	r3d.SetSurfaceShaderSampler(shader,"u_layers_a",set.atlases[0])
	r3d.SetSurfaceShaderSampler(shader,"u_layers_b",set.atlases[1])
	r3d.SetSurfaceShaderSampler(shader,"u_parameters",set.parameters)
	r3d.SetSurfaceShaderSampler(shader,"u_controls",set.paint.texture)
	info:=[4]f32{d.size[0],d.size[1],f32(len(d.layers)),1 if len(d.control_maps)>0 else 0}
	r3d.SetSurfaceShaderUniform(shader,"u_terrain",&info)
}
