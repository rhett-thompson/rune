package r3d_bridge

import "core:math"
import "core:testing"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
ssao_reference_lens_preserves_capped_world_reach_and_attenuation :: proc(t:^testing.T) {
	value:=r3d.EnvSSAO{enabled=true,radius=2,maxRadius=0.2,intensity=0.8,bias=0.03,sampleCount=64,power=1}
	depth:=f64(2)
	base_projection:=1/math.tan(f64(70)*math.PI/360)
	for viewport in ([2][2]f64{{960,540},{540,960}}) {
		height:=viewport[1]
		short_side:=min(viewport[0],viewport[1])
		base_cap:=f64(value.maxRadius)*short_side
		base_world_reach:=base_cap*depth/(base_projection*height*0.5)
		base_raw:=base_projection*height*0.5*f64(value.radius)/depth
		base_attenuation:=base_cap/base_raw
		for fovy in ([6]f32{68,70,72,74,72,70}) {
			camera:=rl.Camera3D{fovy=fovy,projection=.PERSPECTIVE}
			cap:=f64(ssao_max_radius_for_lens(value,camera,70))*short_side
			projection:=1/math.tan(f64(fovy)*math.PI/360)
			world_reach:=cap*depth/(projection*height*0.5)
			raw:=projection*height*0.5*f64(value.radius)/depth
			testing.expect(t,abs(world_reach-base_world_reach)<0.000001,"the clamp must enclose the same world-space radius through lens animation")
			testing.expect(t,abs(cap/raw-base_attenuation)<0.000001,"the clamp must not change close-range SSAO strength as FOV widens")
			testing.expect(t,ssao_max_radius_for_lens(value,camera,0)==value.maxRadius,"default settings preserve the fixed screen cap")
		}
	}
	testing.expect(t,value.maxRadius==0.2 && value.radius==2 && value.intensity==0.8,"lens correction leaves authored settings unchanged")
}

@(test)
ssao_reference_lens_ignores_disabled_orthographic_and_invalid_inputs :: proc(t:^testing.T) {
	value:=r3d.EnvSSAO{enabled=true,maxRadius=0.2}
	camera:=rl.Camera3D{fovy=74,projection=.PERSPECTIVE}
	for invalid in ([7]f32{0,-1,180,181,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		testing.expect(t,ssao_max_radius_for_lens(value,camera,invalid)==value.maxRadius)
		bad_camera:=camera; bad_camera.fovy=invalid
		testing.expect(t,ssao_max_radius_for_lens(value,bad_camera,70)==value.maxRadius)
	}
	orthographic:=camera; orthographic.projection=.ORTHOGRAPHIC
	testing.expect(t,ssao_max_radius_for_lens(value,orthographic,70)==value.maxRadius,"orthographic fovy is a height, not a perspective angle")
	disabled:=value; disabled.enabled=false
	testing.expect(t,ssao_max_radius_for_lens(disabled,camera,70)==value.maxRadius)
	for invalid in ([4]f32{0,-1,math.inf_f32(1),math.nan_f32()}) {
		bad_value:=value; bad_value.maxRadius=invalid
		result:=ssao_max_radius_for_lens(bad_value,camera,70)
		testing.expect(t,result==invalid || (math.is_nan(invalid) && math.is_nan(result)))
	}
}
