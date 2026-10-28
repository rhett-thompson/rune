package assets

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import "rune:jobs"
import rl "vendor:raylib"

@(test)
texture_background_reload_limits_and_failed_attempts_are_bounded :: proc(t: ^testing.T) {
	directory,error:=os.make_directory_temp("build","texture-reload-limits-*",context.allocator)
	if !testing.expect(t,error==nil) {return}; defer delete(directory); defer os.remove(directory)
	path:=fmt.aprintf("%s/bad.png",directory); defer delete(path); defer os.remove(path)
	assert(os.write_entire_file(path,"bad image payload")==nil)
	pool:=jobs.create(1,1); if !testing.expect(t,pool!=nil) {return}; defer jobs.destroy(pool)
	m:=Asset_Manager{root=directory,textures=make(map[string]Texture_Asset),missing_textures=make(map[string]i64),
		retained_paths=make(map[string]string),diagnostics=init_diagnostic_log()}
	defer shutdown(&m)
	m.missing_textures[retain_path(&m,"bad.png")]=0
	limits:=Default_Texture_Reload_Limits; limits.max_input_bytes=64; limits.max_result_bytes=64; limits.max_reserved_bytes=256
	testing.expect(t,!configure_asset_jobs(nil,pool))
	assert(configure_asset_jobs(&m,pool,limits))
	state:=m.texture_reloads
	invalid:=limits; invalid.max_in_flight=0
	testing.expect(t,!configure_asset_jobs(&m,pool,invalid) && m.texture_reloads==state,"invalid limits preserve existing configuration")
	refresh_background(&m)
	testing.expect(t,texture_reload_stats(&m).in_flight==1 && texture_reload_stats(&m).reserved_bytes<=limits.max_reserved_bytes)
	request:=m.texture_reloads.requests["bad.png"]; jobs.wait(&request.group)
	testing.expect(t,!request.ok && request.image.pixels==nil,"invalid payloads produce an owned error without GPU access")
	testing.expect(t,pump_asset_jobs(&m)==0 && texture_reload_stats(&m).in_flight==0 && texture_reload_stats(&m).reserved_bytes==0)
	token:=state.next_token
	for _ in 0..<4 {refresh_background(&m)}
	testing.expect(t,state.next_token==token,"unchanged invalid content is attempted once")
	// A file that exceeds the input cap is rejected before any worker starts.
	limits.max_input_bytes=1; assert(configure_asset_jobs(&m,pool,limits))
	m.missing_textures["bad.png"]=0
	refresh_background(&m)
	testing.expect(t,texture_reload_stats(&m).in_flight==0 && m.texture_reloads.next_token==0)
	// A reservation that cannot fit also defers without an inline decode.
	limits.max_input_bytes=64; limits.max_reserved_bytes=64; assert(configure_asset_jobs(&m,pool,limits))
	m.missing_textures["bad.png"]=0
	refresh_background(&m)
	_,attempted:=m.texture_reloads.attempted["bad.png"]
	testing.expect(t,!attempted && texture_reload_stats(&m).in_flight==0,"byte pressure leaves the request retryable")
	assert(configure_asset_jobs(&m,nil)); testing.expect(t,m.texture_reloads==nil)
}

when #config(RUNE_TEXTURE_RELOAD_GPU_TESTS,false) {
	Texture_Reload_Gate :: struct {started,release: sync.Sema}
	texture_reload_gate_worker :: proc(data: rawptr) {
		gate:=(^Texture_Reload_Gate)(data); sync.sema_post(&gate.started); sync.sema_wait(&gate.release)
	}
	texture_reload_write_png :: proc(path: string,color: rl.Color,stamp: i64) {
		image:=rl.GenImageColor(16,16,color); defer rl.UnloadImage(image)
		cpath:=fmt.ctprintf("%s",path); assert(rl.ExportImage(image,cpath))
		timestamp:=time.unix(1750000000+stamp,0); assert(os.change_times(path,timestamp,timestamp)==nil)
	}
	texture_reload_expect_color :: proc(t: ^testing.T,manager: ^Asset_Manager,path: string,color: rl.Color) {
		texture,ok:=texture(manager,path); if !testing.expect(t,ok) {return}
		image:=rl.LoadImageFromTexture(texture); defer rl.UnloadImage(image)
		testing.expect_value(t,rl.GetImageColor(image,0,0),color)
	}
	texture_reload_wait_requests :: proc(manager: ^Asset_Manager) {
		for _,request in manager.texture_reloads.requests {jobs.wait(&request.group)}
	}

	@(test)
	texture_background_reload_keeps_old_pixels_discards_stale_and_drains :: proc(t: ^testing.T) {
		rl.SetConfigFlags({.WINDOW_HIDDEN}); rl.InitWindow(64,64,"Texture reload regression"); defer rl.CloseWindow()
		if !testing.expect(t,rl.IsWindowReady()) {return}
		directory,error:=os.make_directory_temp("build","texture-reload-runtime-*",context.allocator)
		if !testing.expect(t,error==nil) {return}; defer delete(directory); defer os.remove(directory)
		a:=fmt.aprintf("%s/a.png",directory); defer delete(a); defer os.remove(a)
		b:=fmt.aprintf("%s/b.png",directory); defer delete(b); defer os.remove(b)
		missing:=fmt.aprintf("%s/missing.png",directory); defer delete(missing); defer os.remove(missing)
		first:=fmt.aprintf("%s/first.png",directory); defer delete(first); defer os.remove(first)
		texture_reload_write_png(a,rl.RED,1); texture_reload_write_png(b,rl.RED,1)
		pool:=jobs.create(1,1); if !testing.expect(t,pool!=nil) {return}; defer jobs.destroy(pool)
		m:=init(directory); defer shutdown(&m)
		initial_a,ok:=texture(&m,"a.png"); assert(ok); initial_b,b_ok:=texture(&m,"b.png"); assert(b_ok)
		_,missing_ok:=texture(&m,"missing.png"); testing.expect(t,!missing_ok)
		limits:=Default_Texture_Reload_Limits; limits.max_input_bytes=4096; limits.max_result_bytes=4096; limits.max_reserved_bytes=16384
		assert(configure_asset_jobs(&m,pool,limits))
		gate:Texture_Reload_Gate; group:jobs.Group
		assert(jobs.submit(pool,&group,texture_reload_gate_worker,&gate))
		defer sync.sema_post(&gate.release)
		if !testing.expect(t,sync.sema_wait_with_timeout(&gate.started,2*time.Second)) {return}
		texture_reload_write_png(first,rl.BLUE,1)
		first_texture,first_ok:=texture(&m,"first.png")
		testing.expect(t,first_ok && first_texture.id!=0 && len(m.texture_reloads.requests)==0,
			"first loads remain synchronous even while every worker is occupied")
		texture_reload_write_png(a,rl.BLUE,2); texture_reload_write_png(b,rl.BLUE,2)
		refresh_background(&m)
		testing.expect(t,len(m.texture_reloads.requests)==1,"the single queue slot defers a second texture")
		_,b_attempted:=m.texture_reloads.attempted["b.png"]
		testing.expect(t,!b_attempted && m.textures["a.png"].texture.id==initial_a.id && m.textures["b.png"].texture.id==initial_b.id,
			"queue pressure neither decodes inline nor publishes incomplete textures")
		texture_reload_write_png(a,rl.GREEN,3)
		refresh_background(&m); testing.expect(t,len(m.texture_reloads.requests)==1,"new edits coalesce behind one owned request")
		sync.sema_post(&gate.release); jobs.wait(&group); texture_reload_wait_requests(&m)
		testing.expect(t,pump_asset_jobs(&m)==0 && m.texture_reloads.discarded==1 && m.textures["a.png"].texture.id==initial_a.id,
			"obsolete completion is discarded before GPU upload")
		texture_reload_wait_requests(&m); testing.expect(t,pump_asset_jobs(&m)==1)
		texture_reload_expect_color(t,&m,"a.png",rl.GREEN)
		refresh_background(&m); texture_reload_wait_requests(&m); pump_asset_jobs(&m)
		texture_reload_expect_color(t,&m,"b.png",rl.BLUE)
		good_id:=m.textures["a.png"].texture.id
		assert(os.write_entire_file(a,"invalid PNG replacement")==nil)
		timestamp:=time.unix(1750000004,0); assert(os.change_times(a,timestamp,timestamp)==nil)
		refresh_background(&m); texture_reload_wait_requests(&m); testing.expect(t,pump_asset_jobs(&m)==0)
		token:=m.texture_reloads.next_token; refresh_background(&m)
		testing.expect(t,m.textures["a.png"].texture.id==good_id && m.texture_reloads.next_token==token,
			"invalid content keeps the good resource and is not retried until edited")
		texture_reload_write_png(a,rl.BLUE,5)
		tiny:=limits; tiny.max_result_bytes=1; assert(configure_asset_jobs(&m,pool,tiny))
		refresh_background(&m); texture_reload_wait_requests(&m); testing.expect(t,pump_asset_jobs(&m)==0)
		testing.expect(t,m.textures["a.png"].texture.id==good_id && texture_reload_stats(&m).reserved_bytes==0,
			"decoded byte limits reject replacements before any new GPU texture is installed")
		assert(configure_asset_jobs(&m,pool,limits))
		texture_reload_write_png(a,rl.BLUE,5); texture_reload_write_png(missing,rl.RED,1)
		refresh_background(&m); texture_reload_wait_requests(&m); pump_asset_jobs(&m)
		refresh_background(&m); texture_reload_wait_requests(&m); pump_asset_jobs(&m)
		texture_reload_expect_color(t,&m,"a.png",rl.BLUE); texture_reload_expect_color(t,&m,"missing.png",rl.RED)
		// Explicit refresh remains synchronous and cancels pending async installs.
		texture_reload_write_png(a,rl.RED,6); refresh_background(&m); refresh(&m)
		testing.expect(t,texture_reload_stats(&m).in_flight==0 && pump_asset_jobs(&m)==0)
		texture_reload_expect_color(t,&m,"a.png",rl.RED)
		// Complete two replacements before pumping to exercise the upload cap.
		texture_reload_write_png(a,rl.WHITE,7); texture_reload_write_png(b,rl.WHITE,7)
		refresh_background(&m); texture_reload_wait_requests(&m)
		refresh_background(&m); texture_reload_wait_requests(&m)
		testing.expect(t,len(m.texture_reloads.requests)==2)
		testing.expect(t,pump_asset_jobs(&m)==1 && len(m.texture_reloads.requests)==1)
		testing.expect(t,pump_asset_jobs(&m)==1 && len(m.texture_reloads.requests)==0)
		assert(configure_asset_jobs(&m,nil))
		texture_reload_write_png(a,rl.BLUE,8); refresh_background(&m); texture_reload_expect_color(t,&m,"a.png",rl.BLUE)
		assert(configure_asset_jobs(&m,pool,limits)); texture_reload_write_png(a,rl.GREEN,9); refresh_background(&m)
		shutdown(&m)
		testing.expect(t,m.texture_reloads==nil,"shutdown drains owned requests before freeing manager resources")
	}
}
