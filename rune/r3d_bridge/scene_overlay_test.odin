package r3d_bridge

import "core:testing"
import rl "vendor:raylib"

@(test)
scene_overlay_uv_tracks_native_sampling_crop_and_texture_orientation :: proc(t: ^testing.T) {
	for size in ([4][2]i32{{960,540},{961,541},{540,960},{541,961}}) {
		for fovy in ([3]f32{68,72,75.8}) {
			camera:=rl.Camera3D{fovy=fovy,projection=.PERSPECTIVE}
			_,viewport,cropped:=scene_sampling_projection(camera,75.8,size)
			uv:=scene_overlay_uv_transform(size,viewport,cropped)
			if !cropped {viewport={0,0,f32(size[0]),f32(size[1])}}
			left,top:=i32(viewport.x+0.5),i32(viewport.y+0.5)
			width,height:=i32(viewport.width+0.5),i32(viewport.height+0.5)
			for screen_uv in ([5][2]f32{{0,0},{1,0},{0,1},{1,1},{0.35,0.7}}) {
				// Native final presentation uses bottom-left GL coordinates, while
				// its public viewport uses top-left window coordinates.
				scene_uv:=[2]f32{(screen_uv[0]*f32(size[0])-f32(left))/f32(width),(screen_uv[1]*f32(size[1])-f32(size[1]-top-height))/f32(height)}
				mapped:=[2]f32{scene_uv[0]*uv[0]+uv[2],scene_uv[1]*uv[1]+uv[3]}
				for axis in 0..<2 {testing.expect(t,abs(mapped[axis]-screen_uv[axis])<0.00001,"foreground texture stays aligned through lens animation and odd framebuffer sizes")}
			}
		}
	}
}

@(test)
scene_overlay_rejects_missing_textures_and_defaults_to_full_framebuffer :: proc(t: ^testing.T) {
	testing.expect(t,!scene_overlay_texture_valid({}))
	testing.expect(t,!scene_overlay_texture_valid({id=1,width=0,height=20}))
	testing.expect(t,!scene_overlay_texture_valid({id=1,width=20,height=-1}))
	testing.expect(t,scene_overlay_texture_valid({id=1,width=20,height=10}))
	testing.expect(t,scene_overlay_uv_transform({960,540},{},false)==[4]f32{1,1,0,0})
	testing.expect(t,scene_overlay_uv_transform({0,540},{},true)==[4]f32{1,1,0,0})
}
