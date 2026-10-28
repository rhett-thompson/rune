package assets

import core_runtime "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "rune:image_decode"
import "rune:jobs"
import "rune:pathutil"
import rl "vendor:raylib"

Texture_Reload_Limits :: struct {
	max_in_flight: int,
	max_input_bytes, max_result_bytes, max_reserved_bytes: u64,
	uploads_per_frame, starts_per_poll: int,
}
Default_Texture_Reload_Limits :: Texture_Reload_Limits{4,64*1024*1024,64*1024*1024,256*1024*1024,1,2}

Texture_Reload_State :: struct {
	pool: ^jobs.Pool, // borrowed until detached/drained before pool destruction
	limits: Texture_Reload_Limits,
	requests: map[string]^Texture_Reload_Request,
	attempted: map[string]i64,
	reserved_bytes: u64,
	next_token, uploaded, discarded: u64,
	allocator: mem.Allocator,
}
Texture_Reload_Request :: struct {
	group: jobs.Group,
	absolute_path: string,
	stamp: i64,
	token: u64,
	base_texture: u32,
	input_bytes, output_limit, reservation: u64,
	image: image_decode.Image,
	error: [256]u8,
	ok: bool,
}
Texture_Reload_Stats :: struct {in_flight: int, reserved_bytes, uploaded, discarded: u64}

texture_reload_stats :: proc(manager: ^Asset_Manager) -> Texture_Reload_Stats {
	if manager == nil || manager.texture_reloads == nil {return {}}
	s := manager.texture_reloads
	return {len(s.requests),s.reserved_bytes,s.uploaded,s.discarded}
}

// Configure on the manager's owning thread while the old pool is still alive.
// Reconfiguration drains old work; a nil pool restores synchronous refresh.
// The manager owns request storage, not the supplied pool.
configure_asset_jobs :: proc(manager: ^Asset_Manager, pool: ^jobs.Pool, limits: Texture_Reload_Limits = Default_Texture_Reload_Limits) -> bool {
	if manager == nil {return false}
	if pool != nil && (limits.max_in_flight < 1 || limits.max_in_flight > 64 || limits.max_input_bytes < 1 || limits.max_input_bytes > 1024*1024*1024 ||
		limits.max_result_bytes < 1 || limits.max_result_bytes > 1024*1024*1024 || limits.max_reserved_bytes < limits.max_result_bytes ||
		limits.max_reserved_bytes > u64(4)*1024*1024*1024 || limits.uploads_per_frame < 1 || limits.uploads_per_frame > 64 || limits.starts_per_poll < 1 || limits.starts_per_poll > 64) {return false}
	shutdown_texture_reloads(manager)
	if pool == nil {return true}
	s, error := mem.new(Texture_Reload_State)
	if error != nil {return false}
	s.pool=pool; s.limits=limits; s.allocator=context.allocator
	s.requests=make(map[string]^Texture_Reload_Request); s.attempted=make(map[string]i64)
	manager.texture_reloads=s
	return true
}

// Engine polling entry point. Initial texture loads remain synchronous. Raster
// replacements are prepared on workers; unsupported native formats and fonts
// preserve their legacy synchronous loaders. A full queue defers supported work.
refresh_background :: proc(manager: ^Asset_Manager) {
	if manager == nil {return}
	s := manager.texture_reloads
	if s == nil {refresh(manager); return}
	keys := make([dynamic]string,0,len(manager.textures)+len(manager.missing_textures),context.temp_allocator)
	for path in manager.textures {append(&keys,path)}
	for path in manager.missing_textures {if _,found:=manager.textures[path]; !found {append(&keys,path)}}
	slice.sort(keys[:])
	started := 0
	for path in keys {
		full_path:=resolve_path(manager,path); stamp:=modified_time(full_path)
		old, found:=manager.textures[path]
		if (found && old.modified_time==stamp) || (!found && manager.missing_textures[path]==stamp) {continue}
		if attempted,seen:=s.attempted[path]; seen && attempted==stamp {continue}
		if _,pending:=s.requests[path]; pending {continue} // one owned request per key
		if !image_decode.supports_extension(path) {s.attempted[path]=stamp; refresh_texture_native(manager,path,stamp); continue}
		if started >= s.limits.starts_per_poll {continue}
		if schedule_texture_reload(manager,path,stamp) {started+=1}
	}
	refresh_fonts(manager)
}

schedule_texture_reload :: proc(manager: ^Asset_Manager, path: string, stamp: i64) -> bool {
	s:=manager.texture_reloads
	if s==nil || len(s.requests)>=s.limits.max_in_flight {return false}
	if _,pending:=s.requests[path]; pending {return false}
	full_path:=resolve_path(manager,path)
	info,stat_error:=os.stat(full_path,context.temp_allocator)
	if stat_error!=nil || info.type!=.Regular || info.size<=0 || u64(info.size)>s.limits.max_input_bytes {
		s.attempted[path]=stamp
		texture_reload_failure(manager,path,stamp,"image file is unavailable, empty, or exceeds the background input byte limit")
		return false
	}
	reservation:=u64(info.size)+s.limits.max_result_bytes
	if reservation>s.limits.max_reserved_bytes-s.reserved_bytes {return false}
	a:=core_runtime.default_context().allocator
	request,alloc_error:=mem.new(Texture_Reload_Request,a)
	if alloc_error!=nil {return false}
	absolute,path_error:=pathutil.absolute(full_path,a)
	if path_error!=nil {mem.free(request,a); return false}
	s.next_token+=1
	request.absolute_path=absolute; request.stamp=stamp; request.token=s.next_token
	request.base_texture=manager.textures[path].texture.id
	request.input_bytes=u64(info.size); request.output_limit=s.limits.max_result_bytes; request.reservation=reservation
	if !jobs.submit(s.pool,&request.group,texture_reload_worker,request) {
		free_texture_reload_request(request)
		return false
	}
	s.requests[path]=request; s.attempted[path]=stamp; s.reserved_bytes+=reservation
	return true
}

texture_reload_worker :: proc(data: rawptr) {
	r:=(^Texture_Reload_Request)(data)
	file,open_error:=os.open(r.absolute_path)
	if open_error!=nil {texture_reload_error(r,"could not open the image snapshot"); return}
	defer os.close(file)
	size,size_error:=os.file_size(file)
	if size_error!=nil || size<=0 || u64(size)>r.input_bytes {
		texture_reload_error(r,"image changed size or exceeds its reserved input bytes"); return
	}
	a:=core_runtime.default_context().allocator
	bytes,alloc_error:=make([]u8,int(size),a)
	if alloc_error!=nil {texture_reload_error(r,"could not allocate bounded image input"); return}
	defer delete(bytes,a)
	offset:=0
	for offset<len(bytes) {
		count,read_error:=os.read(file,bytes[offset:]); offset+=count
		if read_error!=nil || count==0 {texture_reload_error(r,"could not read the complete image snapshot"); return}
	}
	r.image,r.ok=image_decode.decode(bytes,r.error[:],r.output_limit)
}

texture_reload_error :: proc(request: ^Texture_Reload_Request, message: string) {
	count:=min(len(message),len(request.error)-1)
	copy(request.error[:count],transmute([]u8)message[:count]); request.error[count]=0
}

// Call once per frame on the graphics thread before rendering. Never waits for
// decoding. Newer edits discard obsolete pixels before any GPU upload.
pump_asset_jobs :: proc(manager: ^Asset_Manager) -> int {
	if manager==nil || manager.texture_reloads==nil {return 0}
	s:=manager.texture_reloads
	keys:=make([dynamic]string,0,len(s.requests),context.temp_allocator)
	for path in s.requests {append(&keys,path)}
	slice.sort(keys[:])
	stale:=make([dynamic]string,context.temp_allocator)
	uploaded:=0
	upload_attempts:=0
	for path in keys {
		r:=s.requests[path]
		if !jobs.is_complete(&r.group) {continue}
		stamp:=modified_time(r.absolute_path)
		if stamp!=r.stamp || manager.textures[path].texture.id!=r.base_texture {
			s.discarded+=1
			if stamp!=r.stamp {append(&stale,path)}
			release_texture_reload(s,path,r); continue
		}
		if !r.ok {
			texture_reload_failure(manager,path,r.stamp,image_decode.error_text(r.error[:]))
			release_texture_reload(s,path,r); continue
		}
		if upload_attempts>=s.limits.uploads_per_frame {continue}
		image,valid:=texture_reload_raylib_image(r.image)
		if !valid {texture_reload_failure(manager,path,r.stamp,"decoded image format cannot be uploaded by raylib"); release_texture_reload(s,path,r); continue}
		upload_attempts+=1
		texture:=rl.LoadTextureFromImage(image)
		if !rl.IsTextureValid(texture) {
			texture_reload_failure(manager,path,r.stamp,"could not upload the decoded image; keeping the previous texture")
			release_texture_reload(s,path,r); continue
		}
		old,found:=manager.textures[path]
		manager.textures[path]=Texture_Asset{texture=texture,modified_time=r.stamp}
		delete_key(&manager.missing_textures,path)
		resolve_asset_path_failures(manager,path)
		material_texture_committed(manager,path,r.stamp)
		if found {rl.UnloadTexture(old.texture)}
		uploaded+=1; s.uploaded+=1
		release_texture_reload(s,path,r)
	}
	// Coalesce a changed file into a fresh bounded request without waiting for
	// the next timestamp poll. Queue pressure still defers it without decoding.
	for path,index in stale {
		if index>=s.limits.starts_per_poll {break}
		schedule_texture_reload(manager,path,modified_time(resolve_path(manager,path)))
	}
	return uploaded
}

texture_reload_raylib_image :: proc(image: image_decode.Image) -> (rl.Image,bool) {
	format:rl.PixelFormat
	if image.floating_point {
		switch image.channels {case 1:format=.UNCOMPRESSED_R32; case 3:format=.UNCOMPRESSED_R32G32B32; case 4:format=.UNCOMPRESSED_R32G32B32A32; case:return {},false}
	} else {
		switch image.channels {case 1:format=.UNCOMPRESSED_GRAYSCALE; case 2:format=.UNCOMPRESSED_GRAY_ALPHA; case 3:format=.UNCOMPRESSED_R8G8B8; case 4:format=.UNCOMPRESSED_R8G8B8A8; case:return {},false}
	}
	return rl.Image{data=image.pixels,width=image.width,height=image.height,mipmaps=1,format=format},true
}

texture_reload_failure :: proc(manager: ^Asset_Manager, path: string, stamp: i64, detail: string) {
	if _,missing:=manager.missing_textures[path]; missing {manager.missing_textures[path]=stamp}
	message:=detail
	if message=="" {message="image decoding failed"}
	report_failure(manager,{kind=.Texture,operation=.Reload,field="texture",asset_path=path,detail=fmt.tprint(message,"; keeping the last working texture")})
}

refresh_texture_native :: proc(manager: ^Asset_Manager, path: string, stamp: i64) {
	cpath,_:=strings.clone_to_cstring(resolve_path(manager,path)); defer delete(cpath)
	texture:=rl.LoadTexture(cpath)
	if !rl.IsTextureValid(texture) {texture_reload_failure(manager,path,stamp,"raylib could not reload this native texture format"); return}
	old,found:=manager.textures[path]
	manager.textures[path]=Texture_Asset{texture,stamp}; delete_key(&manager.missing_textures,path)
	resolve_asset_path_failures(manager,path); material_texture_committed(manager,path,stamp)
	if found {rl.UnloadTexture(old.texture)}
}

free_texture_reload_request :: proc(request: ^Texture_Reload_Request) {
	image_decode.destroy(&request.image)
	a:=core_runtime.default_context().allocator
	delete(request.absolute_path,a); mem.free(request,a)
}
release_texture_reload :: proc(state: ^Texture_Reload_State, path: string, request: ^Texture_Reload_Request) {
	state.reserved_bytes-=request.reservation; delete_key(&state.requests,path)
	free_texture_reload_request(request)
}
drain_texture_reloads :: proc(manager: ^Asset_Manager) {
	if manager==nil || manager.texture_reloads==nil {return}
	s:=manager.texture_reloads
	for _,request in s.requests {jobs.wait(&request.group); free_texture_reload_request(request)}
	clear(&s.requests); s.reserved_bytes=0
}
shutdown_texture_reloads :: proc(manager: ^Asset_Manager) {
	if manager==nil || manager.texture_reloads==nil {return}
	drain_texture_reloads(manager)
	s:=manager.texture_reloads; a:=s.allocator
	delete(s.requests); delete(s.attempted); mem.free(s,a)
	manager.texture_reloads=nil
}
