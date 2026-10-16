package r3d_bridge

import "core:math"
import "core:testing"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
distortion_shortlist_rejects_hidden_invalid_and_subpixel_volumes_and_keeps_nearest :: proc(t: ^testing.T) {
	// An axis-aligned frustum is enough to test conservative culling without a
	// graphics context. View direction is -Z, bounded by X/Y +/-10, Z -100..-0.1.
	frustum:=r3d.Frustum{planes={{0,0,1,100},{0,0,-1,-0.1},{0,1,0,10},{0,-1,0,10},{-1,0,0,10},{1,0,0,10}}}
	camera:=rl.Camera3D{target={0,0,-1},up={0,1,0},fovy=60,projection=.PERSPECTIVE}
	volumes: [40]Distortion_Volume
	for i in 0..<len(volumes) {volumes[i]={position={0,0,-f32(40-i)},radius={1,1,1},strength=0.005,phase=f32(i)}}
	selected,count:=select_distortion_volumes(volumes[:],camera,&frustum,540)
	testing.expect(t,count==Max_Distortion_Volumes)
	testing.expect(t,selected[0].position[2]== -1 && selected[count-1].position[2]== -32,"the nearest 32 survive independently of caller order")
	valid:=Distortion_Volume{position={0,0,-5},radius={1,1,1},strength=0.005}
	invalid: [8]Distortion_Volume
	for &v in invalid {v=valid}
	invalid[0].position={0,0,5}
	invalid[1].position={30,0,-5}
	invalid[2].radius[0]=0
	invalid[3].radius[1]=math.nan_f32()
	invalid[4].strength=0
	invalid[5].phase=math.inf_f32(1)
	invalid[6].position[0]=math.nan_f32()
	invalid[7].radius={0.001,0.001,0.001}
	_,count=select_distortion_volumes(invalid[:],camera,&frustum,540)
	testing.expect(t,count==0,"behind-camera, off-screen, invalid and subpixel effects do not enter the pass")
	crossing:=valid; crossing.position={0,0,0}; crossing.radius={2,2,2}
	_,count=select_distortion_volumes([]Distortion_Volume{crossing},camera,&frustum,540)
	testing.expect(t,count==1,"a near-plane crossing stays visible when the camera enters the volume")
}

@(test)
distortion_packing_preserves_all_slots_and_simulation_clock :: proc(t: ^testing.T) {
	volumes: [Max_Distortion_Volumes]Distortion_Volume
	for &v,i in volumes {v={position={f32(i),2,3},radius={2,4,8},strength=0.005,phase=f32(i)*0.1}}
	settings:=Scene3D_Settings{material_time=0.75,material_time_override=true}
	packed:=pack_distortion_volumes(volumes[:],material_shader_clock(settings,100))
	for v,i in volumes {
		column:=(i%2)*2
		testing.expect(t,packed[i/2][column]==[4]f32{v.position[0],2,3,0.005})
		shape:=packed[i/2][column+1]
		testing.expect(t,shape[0]==0.5 && shape[1]==0.25 && shape[2]==0.125,"GLSL columns receive inverse world radii")
		testing.expect(t,abs(shape[3]-(v.phase+1.5))<0.00001,"paused simulation time drives every independent phase")
	}
	short:=pack_distortion_volumes(volumes[:1],0)
	testing.expect(t,short[0][2]==[4]f32{} && short[15]==[4][4]f32{},"shrinking the borrowed list clears old effects from the cached shader")
}
