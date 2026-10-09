package main

import "core:fmt"
import "core:math"
import r3d "r3d:r3d"
import rl "vendor:raylib"

when ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux) {
	when ODIN_OS == .Windows {
		foreign import native_light_lib "../../third_party/r3d-odin/r3d/windows/r3d.lib"
	} else {
		foreign import native_light_lib "../../third_party/r3d-odin/r3d/linux/libr3d.a"
	}
	// Only the first two fields of the pinned private layout are inspected.
	// Production bridge code uses no private structs or new native entry points.
	Native_Light_Prefix :: struct {frustum:[6]r3d.Frustum,projection:[6]rl.Matrix}
	@(default_calling_convention="c")
	foreign native_light_lib {
		@(link_name="r3d_light_get")
		native_light_get :: proc(id:r3d.Light) -> ^Native_Light_Prefix ---
		@(link_name="r3d_light_update_and_cull")
		native_light_update :: proc(frustum:^r3d.Frustum,camera:r3d.Camera,aspect:f64,shadows:^bool) ---
		@(link_name="r3d_light_shadow_get_size")
		native_shadow_size :: proc(kind:r3d.LightType) -> i32 ---
		@(link_name="r3d_light_shadow_should_be_updated")
		native_shadow_complete :: proc(light:^Native_Light_Prefix,will_be_updated:bool) -> bool ---
	}

	validate_directional_stability :: proc() {
		// This catches incompatible private core-state offsets in a rebuilt object.
		assert(native_shadow_size(.DIR)==r3d.GetHint(.SHADOW_DIR_SIZE))
		assert(native_shadow_size(.SPOT)==r3d.GetHint(.SHADOW_SPOT_SIZE))
		assert(native_shadow_size(.OMNI)==r3d.GetHint(.SHADOW_OMNI_SIZE))
		light:=r3d.CreateLight(.DIR); defer r3d.DestroyLight(light)
		r3d.EnableLight(light); r3d.EnableShadow(light)
		r3d.SetShadowUpdateMode(light,.CONTINUOUS)
		positions:=[3]rl.Vector3{{41.77910233,13.60000038,12.88047791},{0,0,0},{-42.017,90.913,-164.212}}
		directions:=[4]rl.Vector3{{0.15,-0.55,-0.82},{0,-1,0},{1,0,0},{0,0,-1}}
		orientations:=[8]rl.Vector3{{1,0,0},{-1,0,0},{0,0,1},{0,0,-1},{1,1,0},{1,-1,0},{-1,-1,-1},{1,3,1}}
		view_frustum:=r3d.ComputeFrustum(rl.Matrix(1))
		cases:=0
		for direction in directions {
			r3d.SetLightDirection(light,direction)
			for position in positions {
				for aspect in ([3]f64{16.0/9,4.0/3,9.0/16}) {
					for fov in ([3]f32{45,70,100}) {
						for range in ([3]f32{20,180,1000}) {
							r3d.SetLightRange(light,range)
							reference:rl.Matrix
							for orientation,index in orientations {
								camera:=r3d.CameraFromRL(rl.Camera3D{position=position,target=position+orientation,up={0,1,0},fovy=fov})
								visible:bool; native_light_update(&view_frustum,camera,aspect,&visible)
								assert(visible)
								projection:=native_light_get(light).projection[0]
								if index==0 {reference=projection}
								else {assert(projection==reference,"camera rotation must leave the complete shadow lookup matrix unchanged")}
								height:=range*math.tan(fov*math.PI/360)
								forward:=r3d.GetCameraForward(camera); right:=r3d.GetCameraRight(camera); up:=r3d.GetCameraUp(camera)
								for corner in 0..<4 {
									x:=f32(1) if corner&1!=0 else -1; y:=f32(1) if corner&2!=0 else -1
									point:=position+forward*range+right*(height*f32(aspect)*x)+up*(height*y)
									projected:=rl.Vector3Transform(point,projection)
									// Allow one snapped texel at the outermost coverage boundary.
									assert(math.abs(projected.x)<1.001 && math.abs(projected.y)<1.001 && math.abs(projected.z)<1.001,"far-plane corners must remain inside directional shadow coverage")
								}
								cases+=1
							}
						}
					}
				}
			}
		}
		// A manual map must retain its matching projection until explicitly refreshed.
		r3d.SetShadowUpdateMode(light,.MANUAL); r3d.UpdateShadowMap(light)
		camera:=r3d.CameraFromRL(rl.Camera3D{position={0,0,0},target={1,0,0},up={0,1,0},fovy=70})
		visible:bool; native_light_update(&view_frustum,camera,16.0/9,&visible)
		reference:=native_light_get(light).projection[0]
		assert(native_shadow_complete(native_light_get(light),true))
		camera.position={100,30,-50}
		native_light_update(&view_frustum,camera,16.0/9,&visible)
		assert(native_light_get(light).projection[0]==reference && !native_shadow_complete(native_light_get(light),false),"manual maps and lookup matrices must stay synchronized")
		r3d.UpdateShadowMap(light); native_light_update(&view_frustum,camera,16.0/9,&visible)
		assert(native_light_get(light).projection[0]!=reference && native_shadow_complete(native_light_get(light),true))
		fmt.println("Directional shadow rotation invariance and coverage passed",cases,"orientations")
	}
} else {
	validate_directional_stability :: proc() {}
}
