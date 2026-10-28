// Hidden native regression for point-light bounds which cross the camera plane.
// The receiver samples are known to be inside the light sphere and face it.
// Shadows, ambient screen effects, and game-side occlusion are disabled.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Width :: 800
Height :: 450

Case :: struct {
    name: string,
    pixel: [2]int,
    camera_fovy, camera_yaw, receiver_distance: f32,
    light_position, receiver_point: [3]f32,
    light_distance, light_range: f32,
    camera_plane_crossing: bool,
    on_luminance, off_luminance, light_gain: f64,
    passed: bool,
}
Report :: struct {complete,window_hidden:bool,scope:string,cases:[dynamic]Case}

when ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux) {
    when ODIN_OS == .Windows {
        foreign import native_light_lib "../../third_party/r3d-odin/r3d/windows/r3d.lib"
    } else {
        foreign import native_light_lib "../../third_party/r3d-odin/r3d/linux/libr3d.a"
    }
    // Fixture-only mirror of pinned R3D 0.11 src/modules/r3d_light.h. Production
    // bridge code neither reads this private state nor exposes a test-only API.
    Native_Light_State :: struct {
        mode:r3d.ShadowUpdateMode,
        interval,timer:f32,
        shadow_update,matrix_update:bool,
    }
    Native_Light :: struct {
        frustum:[6]r3d.Frustum,
        view_projection:[6]rl.Matrix,
        bounds:rl.BoundingBox,
        state:Native_Light_State,
        shadow_layer:i32,
        color,position,direction:rl.Vector3,
        energy,specular,range,falloff,inner_cutoff,outer_cutoff,fog_energy:f32,
        near,far,softness,opacity,depth_bias,slope_bias:f32,
        caster_mask:r3d.Layer,
        kind:r3d.LightType,
        enabled:bool,
    }
    Native_Rect :: struct {x,y,width,height:i32}
    #assert(size_of(Native_Light_State)==16)
    #assert(offset_of(Native_Light,bounds)==6*size_of(r3d.Frustum)+6*size_of(rl.Matrix))
    @(default_calling_convention="c")
    foreign native_light_lib {
        @(link_name="r3d_light_get_screen_rect")
        native_light_rect :: proc(light:^Native_Light,projection:^rl.Matrix,camera:rl.Vector3,width,height:i32) -> Native_Rect ---
    }

    validate_bounds :: proc() {
        full:=Native_Rect{0,0,Width,Height}
        count:=0
        for fovy in ([2]f64{75,120}) {
            projection:=rl.MatrixPerspective(f32(fovy*math.PI/180),f32(Width)/Height,.1,100)
            light:=Native_Light{kind=.OMNI,bounds={{-1,-1,-1},{1,1,1}}}
            assert(native_light_rect(&light,&projection,{},Width,Height)==full,"A camera inside the influence bounds requires full coverage")
            count+=1
            for bounds in ([]rl.BoundingBox{
                {{.6,-6,-10.8},{12.6,6,1.2}},
                {{-12.6,-6,-10.8},{-.6,6,1.2}},
                {{-6,.6,-10.8},{6,12.6,1.2}},
                {{-6,-12.6,-10.8},{6,-.6,1.2}},
                {{1,-1,-.2},{2,1,-.05}}, // Entirely ahead of the eye, crossing near.
            }) {
                light.bounds=bounds
                assert(native_light_rect(&light,&projection,{},Width,Height)==full,"Eye/near-plane crossing bounds must conservatively retain every viewport edge")
                count+=1
            }
            light.bounds={{-1.137,-.539,-6.2},{.439,.871,-4.3}}
            rect:=native_light_rect(&light,&projection,{},Width,Height)
            assert(rect.x>0 && rect.y>0 && rect.width<Width && rect.height<Height,"Wholly front-facing lights should retain the tight scissor optimization")
            // Fractional projected edges must round outward, including the high
            // endpoint: truncating width can drop a visibly illuminated column.
            for corner in 0..<8 {
                point:=rl.Vector4{
                    light.bounds.max[0] if corner&1!=0 else light.bounds.min[0],
                    light.bounds.max[1] if corner&2!=0 else light.bounds.min[1],
                    light.bounds.max[2] if corner&4!=0 else light.bounds.min[2],1}
                clip:=projection*point
                x:=(f64(clip[0]/clip[3])*.5+.5)*Width
                y:=(f64(clip[1]/clip[3])*.5+.5)*Height
                assert(f64(rect.x)<=x+.001 && f64(rect.x+rect.width)>=x-.001 && f64(rect.y)<=y+.001 && f64(rect.y+rect.height)>=y-.001,"The scissor must cover fractional projected bounds without clipping lit pixels")
                count+=1
            }
            light.bounds={{100,-1,-10},{102,1,-9}}
            assert(native_light_rect(&light,&projection,{},Width,Height)==Native_Rect{},"A wholly front-facing light outside the viewport can still be skipped")
            count+=1
        }
        fmt.printf("Light-scissor native bounds validation passed: %d checks (no window)\n",count)
    }
} else {
    validate_bounds :: proc() {fmt.println("Light-scissor private native bounds checks require Windows/Linux AMD64")}
}

luminance :: proc(c:rl.Color) -> f64 {return .2126*f64(c.r)+.7152*f64(c.g)+.0722*f64(c.b)}

sample :: proc(image:rl.Image,pixel:[2]int) -> f64 {
    total:f64
    for y in pixel[1]-2..=pixel[1]+2 {for x in pixel[0]-2..=pixel[0]+2 {
        total+=luminance(rl.GetImageColor(image,i32(x),i32(y)))
    }}
    return total/25
}

capture :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:string) -> rl.Image {
    for _ in 0..<3 {
        rl.BeginDrawing()
        assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK}))
        rl.EndDrawing()
    }
    image:=rl.LoadImageFromScreen()
    assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
    return image
}

main :: proc() {
    output:="build/light-scissor-validation"
    observe:=false
    runtime:=false
    for arg in os.args[1:] {
        if arg=="--observe" {observe=true}
        else if arg=="--runtime" {runtime=true}
        else if arg=="--help" {fmt.println("Usage: light_scissor_validation [output-directory] --runtime [--observe]"); return}
        else {assert(!strings.has_prefix(arg,"--"),"Unknown argument"); output=arg}
    }
    if !observe {validate_bounds()}
    if !runtime {return}
    assert(os.make_directory(output)==nil || os.is_dir(output))
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_HIDDEN,.WINDOW_ALWAYS_RUN})
    rl.InitWindow(Width,Height,"Rune light scissor validation"); defer rl.CloseWindow()
    ctx,ready:=bridge.init(".",Width,Height); assert(ready); defer bridge.shutdown(&ctx)
    // Retain every light independently of Rune's optional occlusion optimization.
    ctx.occlusion_enabled=false
    manager:=assets.init("."); defer assets.shutdown(&manager)
    registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
    assert(ecs.register_builtin_components(&registry))
    w:=ecs.init(); defer ecs.destroy(&w)
    camera_entity:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,camera_entity,ecs.Transform{scale={1,1,1}}))
    assert(ecs.add(&w,&registry,camera_entity,ecs.Camera3D{target={0,0,-1},up={0,1,0},fovy=75,active=true}))
    post:=ecs.default_post_processing(); post.anti_aliasing=.disabled
    assert(ecs.add(&w,&registry,camera_entity,post))
    ambient:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=.02}))
    receiver:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,receiver,ecs.Transform{position={0,0,-6.1},scale={60,60,.2}}))
    assert(ecs.add(&w,&registry,receiver,ecs.MeshRenderer{primitive="cube",color={210,210,210,255},shadows=false}))
    light_entity:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,light_entity,ecs.Transform{position={6.6,0,-4.8},scale={1,1,1}}))
    light:=ecs.PointLight{color={255,255,255,255},intensity=8,range=6,specular=0,shadows=false}
    assert(ecs.add(&w,&registry,light_entity,light))
    report:=Report{complete=true,window_hidden=rl.IsWindowHidden(),scope="Hidden 800x450 opaque receiver, point light, no shadows/post effects or bridge occlusion; edge receiver points must gain light. Crossing cases previously underbounded the projected light AABB; front-only cases retain the bounded path."}
    edges:=[4]string{"right","left","top","bottom"}
    pixels:=[4][2]int{{Width-12,Height/2},{12,Height/2},{Width/2,12},{Width/2,Height-12}}
    for yaw in ([3]f32{0,-1,1}) {for crossing in ([2]bool{true,false}) {
        for edge,index in edges {
            result:=Case{name=fmt.aprintf("%s-%s-yaw%+.0f", "crossing" if crossing else "front",edge,yaw),pixel=pixels[index],camera_fovy=75 if index<2 else 120,camera_yaw=yaw,camera_plane_crossing=crossing,receiver_distance=6 if crossing else 10,light_range=6}
            radians:=yaw*f32(math.PI/180)
            camera:=rl.Camera3D{position={},target={math.sin(radians),0,-math.cos(radians)},up={0,1,0},fovy=result.camera_fovy}
            assert(ecs.set_camera_3d(&w,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=camera.fovy,active=true}))
            assert(ecs.set_transform(&w,receiver,ecs.Transform{position={0,0,-result.receiver_distance-.1},scale={60,60,.2}}))
            ray:=rl.GetScreenToWorldRayEx({f32(result.pixel[0]),f32(result.pixel[1])},camera,Width,Height)
            result.receiver_point=ray.position+ray.direction*((-result.receiver_distance-ray.position[2])/ray.direction[2])
            if crossing {
                result.light_position={6.6,0,-4.8}
                if index==1 {result.light_position[0] = -6.6}
                if index>=2 {result.light_position={0,6.6 if index==2 else -6.6,-4.8}}
            } else {
                result.light_position=result.receiver_point
                result.light_position[2]+=3
                if index<2 {result.light_position[0]-=2 if index==0 else -2}
                else {result.light_position[1]-=2 if index==2 else -2}
            }
            difference:=result.light_position-result.receiver_point
            result.light_distance=math.sqrt(difference[0]*difference[0]+difference[1]*difference[1]+difference[2]*difference[2])
            assert(result.light_distance<result.light_range-.5 && difference[2]>0,"Probe samples must lie within the light and face it")
            assert(ecs.set_transform(&w,light_entity,ecs.Transform{position=result.light_position,scale={1,1,1}}))
            light.intensity=8; assert(ecs.set_point_light(&w,light_entity,light))
            on:=capture(&ctx,&w,&manager,fmt.tprintf("%s/%s-on.png",output,result.name))
            result.on_luminance=sample(on,result.pixel); rl.UnloadImage(on)
            light.intensity=0; assert(ecs.set_point_light(&w,light_entity,light))
            off:=capture(&ctx,&w,&manager,fmt.tprintf("%s/%s-off.png",output,result.name))
            result.off_luminance=sample(off,result.pixel); rl.UnloadImage(off)
            result.light_gain=result.on_luminance-result.off_luminance
            result.passed=result.light_gain>10
            report.complete=report.complete && result.passed
            append(&report.cases,result)
            fmt.printf("%s %s: gain %.2f, distance %.2f / %.2f\n","PASS" if result.passed else "FAIL",result.name,result.light_gain,result.light_distance,result.light_range)
        }
    }}
    bytes,error:=json.marshal(report,{pretty=true}); assert(error==nil); defer delete(bytes)
    assert(os.write_entire_file(fmt.tprintf("%s/report.json",output),bytes)==nil)
    fmt.printf("Report: %s/report.json\n",output)
    assert(observe || report.complete,"Local lighting must reach known lit receiver samples at every screen edge")
}
