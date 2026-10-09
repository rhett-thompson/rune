package r3d_bridge

import "core:math"
import "core:testing"
import rl "vendor:raylib"

@(test)
sampling_projection_preserves_world_point_presentation_and_native_lens :: proc(t:^testing.T) {
	fixed_fovy:=f32(75.8)
	fixed_tangent:=math.tan(f64(fixed_fovy)*math.PI/360)
	for size in ([4][2]i32{{960,540},{540,960},{961,541},{541,961}}) {
		width,height:=f64(size[0]),f64(size[1])
		for fovy in ([6]f32{68,70,72,74,75.8,70}) {
			visible:=rl.Camera3D{position={3,4,5},target={3,4,4},up={0,1,0},fovy=fovy,projection=.PERSPECTIVE}
			render,viewport,active:=scene_sampling_projection(visible,fixed_fovy,size)
			if !active {viewport={0,0,f32(size[0]),f32(size[1])}}
			testing.expect(t,render.fovy==fixed_fovy,"scene sampling uses the same projection throughout lens animation")
			testing.expect(t,render.position==visible.position && render.target==visible.target && render.up==visible.up,"only the sampling lens changes")
			testing.expect(t,visible.fovy==fovy,"the visible camera remains available for picking and overlays")
			aspect:=f64(viewport.width)/f64(viewport.height)
			testing.expect(t,abs(aspect-width/height)<0.000001,"presentation scaling must preserve native projection aspect")
			left,top:=f64(i32(viewport.x+0.5)),f64(i32(viewport.y+0.5))
			present_width,present_height:=f64(i32(viewport.width+0.5)),f64(i32(viewport.height+0.5))
			testing.expect(t,abs(left+present_width/2-width/2)<=0.5 && abs(top+present_height/2-height/2)<=0.5,"native integer presentation stays centered within half a pixel")
			visible_tangent:=math.tan(f64(fovy)*math.PI/360)
			// World points remain visible in every lens. Compare their direct visible
			// perspective projection with the fixed native projection after its crop.
			for depth in ([3]f64{2,20,200}) {
				for offset in ([5][2]f64{{0,0},{0.6,0.2},{-0.6,0.2},{0.6,-0.2},{-0.6,-0.2}}) {
					x,y:=offset[0]*depth,offset[1]*depth
					visible_point:=[2]f64{width/2+x*height/(2*visible_tangent*depth),height/2-y*height/(2*visible_tangent*depth)}
					presented:=[2]f64{left+(0.5+x/(2*aspect*fixed_tangent*depth))*present_width,top+(0.5-y/(2*fixed_tangent*depth))*present_height}
					for axis in 0..<2 {testing.expect(t,abs(visible_point[axis]-presented[axis])<1,"cropped scene and animated-lens overlays must project the same world points")}
				}
			}
		}
	}
}

@(test)
sampling_projection_rejects_invalid_and_unsupported_inputs :: proc(t:^testing.T) {
	camera:=rl.Camera3D{fovy=70,projection=.PERSPECTIVE}
	for angle in ([9]f32{0,-1,69,70,180,181,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		result,viewport,active:=scene_sampling_projection(camera,angle,{960,540})
		testing.expect(t,!active && result==camera && viewport==rl.Rectangle{},"default, narrower and invalid sampling lenses retain the original draw path")
	}
	for angle in ([7]f32{0,-1,180,181,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		invalid:=camera; invalid.fovy=angle
		_,viewport,active:=scene_sampling_projection(invalid,75.8,{960,540})
		testing.expect(t,!active && viewport==rl.Rectangle{},"invalid visible lenses cannot create a crop")
	}
	for size in ([4][2]i32{{0,540},{960,0},{-1,540},{960,-1}}) {
		result,viewport,active:=scene_sampling_projection(camera,75.8,size)
		testing.expect(t,!active && result==camera && viewport==rl.Rectangle{})
	}
	orthographic:=camera; orthographic.projection=.ORTHOGRAPHIC
	result,_,active:=scene_sampling_projection(orthographic,75.8,{960,540})
	testing.expect(t,!active && result==orthographic,"orthographic size is not a perspective angle")
	extreme:=camera; extreme.fovy=0.0001
	_,_,active=scene_sampling_projection(extreme,179,{960,540})
	testing.expect(t,!active,"unrepresentable native viewport coordinates fall back safely")
}
