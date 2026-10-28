package r3d_bridge

import "core:mem"
import "core:path/filepath"
import "rune:assets"
import "rune:image_decode"
import "rune:jobs"
import "rune:pathutil"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Two requests bound retained decoded pixels to 512 MiB plus at most one
// 64 MiB input and 16 MiB procedural workspace per running callback.
Material_Reload_Max_Pending :: 2
Material_Reload_Input_Limit :: u64(64*1024*1024)
Material_Reload_Output_Limit :: u64(256*1024*1024)

Material_Reload_Request :: struct {
	group:jobs.Group,
	allocator:mem.Allocator,
	data:assets.Material_Data,
	manager:^assets.Asset_Manager, // compared only by the owner; never read by a worker
	fingerprint,signature:u64,
	paths:[4]string,
	dependency_paths:[9]string,
	stamps:[9]i64,
	images:[4]image_decode.Image,
	procedural:assets.Procedural_Material_Images,
	error:[512]u8,
	last_requested,ready_tick:u64,
	ok:bool,
}

// Admission failures and stale completions can leave no accepted job whose
// completion would wake cached instance/terrain consumers. Retry at the next
// owner boundary without keeping those consumers dirty for ordinary busy jobs.
request_material_retry :: proc(ctx:^Context,manager:^assets.Asset_Manager) {
	if manager==nil {return}
	if ctx.material_reload_retries==nil {ctx.material_reload_retries=make(map[^assets.Asset_Manager]bool)}
	ctx.material_reload_retries[manager]=true
}

// Call before any material submission for a draw. Completion eligibility is
// frozen here: a worker finishing during native submission waits until the next
// boundary, so an earlier draw cannot reference a texture freed later that draw.
pump_material_jobs :: proc(ctx:^Context) {
	if ctx==nil {return}
	ctx.material_reload_tick+=1
	ctx.material_reload_uploads=0
	remove:=make([dynamic]string,context.temp_allocator)
	for path,request in ctx.material_reloads {
		if !jobs.is_complete(&request.group) {continue}
		if request.ready_tick==0 {
			// Cached instance batches may stop resolving their materials while
			// waiting. Wake owner-side consumers once completion becomes visible.
			request.last_requested=ctx.material_reload_tick
			request_material_retry(ctx,request.manager)
		} else if ctx.material_reload_tick-request.last_requested>2 {append(&remove,path);continue}
		request.ready_tick=ctx.material_reload_tick
	}
	for path in remove {
		request:=ctx.material_reloads[path]
		request_material_retry(ctx,request.manager)
		finish_material_reload(ctx,path,request);ctx.frame_stats.material_reload_discarded+=1
	}
	for manager in ctx.material_reload_retries {assets.bump_material_revision(manager)}
	clear(&ctx.material_reload_retries)
	ctx.frame_stats.material_reload_pending=len(ctx.material_reloads)
}

release_material_jobs :: proc(ctx:^Context) {
	for _,request in ctx.material_reloads {jobs.wait(&request.group);destroy_material_reload_request(request)}
	delete(ctx.material_reloads);ctx.material_reloads=nil
	delete(ctx.material_reload_retries);ctx.material_reload_retries=nil
}

material_reload_supported :: proc(data:assets.Material_Data) -> bool {
	// Separate-channel ORM retains its synchronous, leased manager path. Its
	// existing resize/color semantics are independent of direct image decoding.
	if data.ao_texture!="" || data.roughness_texture!="" || data.metallic_texture!="" {return false}
	useful:=material_needs_procedural_images(data)
	for path in ([4]string{data.texture,data.normal,data.emission,data.orm_texture}) {
		if path=="" {continue}
		if !image_decode.supports_extension(path) {return false}
		useful=true
	}
	return useful && image_decode.IS_SUPPORTED
}

material_needs_procedural_images :: proc(data:assets.Material_Data) -> bool {
	return data.procedural.enabled && (data.texture=="" ||
		(data.normal=="" && data.procedural.bump_strength>0) ||
		(data.orm_texture=="" && data.ao_texture=="" && data.roughness_texture=="" &&
		 data.metallic_texture=="" && data.procedural.roughness_variation>0))
}

// A true deferred result means the old cache stays installed. A ready request
// remains owned by the caller until finish_material_reload after GPU building.
prepare_material_reload :: proc(ctx:^Context,manager:^assets.Asset_Manager,path:string,data:assets.Material_Data,signature,fingerprint:u64,previous:R3D_Material_Asset) -> (ready:^Material_Reload_Request,deferred:bool) {
	if ctx.worker_pool==nil || ctx.material_reload_synchronous || manager==nil || path=="" || !material_reload_supported(data) {return nil,false}
	if request,found:=ctx.material_reloads[path];found {
		request.last_requested=ctx.material_reload_tick
		if request.fingerprint!=fingerprint || request.manager!=manager {
			// The original owner's completion cannot wake a replacement manager
			// whose cached instance batches already stopped resolving this path.
			if request.manager!=manager {request_material_retry(ctx,manager)}
			if jobs.is_complete(&request.group) {
				finish_material_reload(ctx,path,request);ctx.frame_stats.material_reload_discarded+=1
				request_material_retry(ctx,manager)
			}
			return nil,true
		}
		if !jobs.is_complete(&request.group) || request.ready_tick==0 || request.ready_tick!=ctx.material_reload_tick {return nil,true}
		for source,index in request.dependency_paths {
			if source!="" && assets.modified_time(source)!=request.stamps[index] {
				finish_material_reload(ctx,path,request);ctx.frame_stats.material_reload_discarded+=1
				request_material_retry(ctx,manager)
				return nil,true
			}
		}
		if !request.ok {
			assets.report_failure(manager,{kind=.Material,operation=.Reload,source_path=path,field="material",asset_path=path,
				detail=image_decode.error_text(request.error[:])})
			remember_material_reload_attempt(ctx,manager,path,previous,signature,fingerprint)
			finish_material_reload(ctx,path,request)
			return nil,true
		}
		if ctx.material_reload_uploads>=1 {request_material_retry(ctx,manager);return nil,true}
		ctx.material_reload_uploads+=1
		return request,false
	}
	if len(ctx.material_reloads)>=Material_Reload_Max_Pending {
		ctx.frame_stats.material_reload_deferred+=1;request_material_retry(ctx,manager);return nil,true
	}
	request,allocation_error:=mem.new(Material_Reload_Request)
	if allocation_error!=nil {request_material_retry(ctx,manager);return nil,true}
	request.allocator=context.allocator
	request.data=assets.clone_material_data(data)
	request.manager=manager;request.signature=signature;request.fingerprint=fingerprint
	request.last_requested=ctx.material_reload_tick
	for source,index in assets.material_dependency_paths(data) {
		if source=="" {continue}
		joined,_:=filepath.join({ctx.root,source},context.temp_allocator)
		absolute,error:=pathutil.absolute(source if filepath.is_abs(source) else joined)
		if error!=nil {destroy_material_reload_request(request);request_material_retry(ctx,manager);return nil,true}
		request.dependency_paths[index]=absolute;request.stamps[index]=assets.modified_time(absolute)
	}
	request.paths={request.dependency_paths[1],request.dependency_paths[2],request.dependency_paths[3],request.dependency_paths[4]}
	if !jobs.submit(ctx.worker_pool,&request.group,material_reload_worker,request) {
		destroy_material_reload_request(request);ctx.frame_stats.material_reload_deferred+=1;request_material_retry(ctx,manager);return nil,true
	}
	if ctx.material_reloads==nil {ctx.material_reloads=make(map[string]^Material_Reload_Request)}
	ctx.material_reloads[retain_path(ctx,path)]=request
	ctx.frame_stats.material_reload_started+=1
	return nil,true
}

remember_material_reload_attempt :: proc(ctx:^Context,manager:^assets.Asset_Manager,path:string,previous:R3D_Material_Asset,signature,fingerprint:u64) {
	retained:=previous
	retained.source_manager=manager
	retained.signature=signature;retained.dependency_fingerprint=fingerprint
	retained.path_revision=assets.material_path_revision(manager,path)
	retained.asset_revision=assets.material_asset_revision(manager)
	ctx.r3d_materials[path]=retained
}

material_reload_worker :: proc(pointer:rawptr) {
	request:=(^Material_Reload_Request)(pointer)
	remaining:=Material_Reload_Output_Limit
	if material_needs_procedural_images(request.data) {
		resolution:=request.data.procedural.resolution
		if resolution<8 || resolution>1024 {image_decode.decode_file_error(request.error[:],"invalid procedural resolution");return}
		remaining-=u64(resolution)*u64(resolution)*16 // three output maps plus temporary heights
	}
	for path,index in request.paths {
		if path=="" {continue}
		image,ok:=image_decode.decode_file(path,Material_Reload_Input_Limit,remaining,request.error[:])
		if !ok {return}
		request.images[index]=image;remaining-=image.size_bytes
	}
	if material_needs_procedural_images(request.data) {
		images,ok:=assets.generate_procedural_material_images(request.data.procedural)
		if !ok {image_decode.decode_file_error(request.error[:],"procedural material generation failed");return}
		request.procedural=images
	}
	request.ok=true
}

finish_material_reload :: proc(ctx:^Context,path:string,request:^Material_Reload_Request) {
	delete_key(&ctx.material_reloads,path)
	destroy_material_reload_request(request)
}

destroy_material_reload_request :: proc(request:^Material_Reload_Request) {
	a:=request.allocator
	context.allocator=a
	for &image in request.images {image_decode.destroy(&image)}
	assets.destroy_procedural_material_images(&request.procedural)
	for path in request.dependency_paths {delete(path,a)}
	assets.destroy_material_data(&request.data)
	mem.free(request,a)
}

prepared_material_texture :: proc(request:^Material_Reload_Request,index:int,data:assets.Material_Data,is_color:bool) -> (rl.Texture2D,bool) {
	image:=request.images[index]
	format:rl.PixelFormat
	if image.floating_point {
		switch image.channels {case 1:format=.UNCOMPRESSED_R32;case 3:format=.UNCOMPRESSED_R32G32B32;case 4:format=.UNCOMPRESSED_R32G32B32A32;case:return {},false}
	} else {
		switch image.channels {case 1:format=.UNCOMPRESSED_GRAYSCALE;case 2:format=.UNCOMPRESSED_GRAY_ALPHA;case 3:format=.UNCOMPRESSED_R8G8B8;case 4:format=.UNCOMPRESSED_R8G8B8A8;case:return {},false}
	}
	view:=rl.Image{data=image.pixels,width=image.width,height=image.height,mipmaps=1,format=format}
	texture:rl.Texture2D
	if is_color {
		// R3D consumes/reformats/frees this copy. Private decoder memory always
		// returns to its own allocator instead of crossing native CRT ownership.
		copy:=rl.ImageCopy(view)
		if copy.data==nil {return {},false}
		texture=r3d.LoadTextureFromImage(copy,true)
	} else {texture=rl.LoadTextureFromImage(view)}
	if !rl.IsTextureValid(texture) {return {},false}
	assets.configure_texture(&texture,data.filter,data.mipmaps,data.wrap)
	return texture,true
}
