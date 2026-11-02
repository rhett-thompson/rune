// Render a no-UV imported face through the production ModelRenderer pipeline.
// A rotated source face must match its equivalent baked geometry and retain a
// finite lighting normal, including when the importer's tangent needs repair.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

Width :: 320
Height :: 240
Lit_Material :: "lit.material.json"
Normal_Material :: "normal.material.json"
Normal_Shader :: "normal.glsl"

// Reconstruct the same shading normal as R3D's opaque geometry shader. The
// default normal map is used: no texture or authored tangent can hide the bug.
// Red diagnoses a nonfinite, nonunit, or incorrectly oriented shading normal.
NORMAL_SHADER :: `#pragma usage opaque
void fragment() {
    vec3 n = normalize(mat3(TANGENT, BITANGENT, NORMAL) * (NORMAL_MAP * 2.0 - 1.0));
    bool finiteNormal = !any(isnan(n)) && !any(isinf(n));
    bool unitNormal = abs(dot(n, n) - 1.0) < 0.001;
    bool alignedNormal = dot(n, normalize(NORMAL)) > 0.999;
    ALBEDO = vec3(0.0);
    SPECULAR = 0.0;
    EMISSION = finiteNormal && unitNormal && alignedNormal
        ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
}`

Sample :: struct {rgb:[3]f64, luminance:f64}
Model_Result :: struct {
    on, off, normal: Sample,
    light_gain: f64,
    passed: bool,
}
Case :: struct {
    name: string,
    yaw: f32,
    scale: [3]f32,
    imported, baked: Model_Result,
    lighting_difference: f64,
    passed: bool,
}
Report :: struct {
    complete, window_hidden: bool,
    scope: string,
    cases: [dynamic]Case,
}

rotate_y :: proc(point:[3]f32,yaw:f32) -> [3]f32 {
    angle:=yaw*f32(math.PI/180)
    s,c:=math.sin(angle),math.cos(angle)
    return {c*point[0]+s*point[2],point[1],-s*point[0]+c*point[2]}
}

write_quad :: proc(path:string,yaw:f32,scale:[3]f32) {
    // Counterclockwise from +X. Deliberately no vt records or UV indices.
    points:=[4][3]f32{{0,-1,-1},{0,1,-1},{0,1,1},{0,-1,1}}
    for &point in points {point=rotate_y(point*scale,yaw)}
    n:=rotate_y({1,0,0},yaw)
    text:=fmt.aprintf(`# No UVs; explicit +X source normal and baked rotation.
o no_uv_quad
v %.9f %.9f %.9f
v %.9f %.9f %.9f
v %.9f %.9f %.9f
v %.9f %.9f %.9f
vn %.9f %.9f %.9f
s off
f 1//1 2//1 3//1
f 1//1 3//1 4//1
`,points[0][0],points[0][1],points[0][2],points[1][0],points[1][1],points[1][2],
        points[2][0],points[2][1],points[2][2],points[3][0],points[3][1],points[3][2],n[0],n[1],n[2])
    defer delete(text)
    assert(os.write_entire_file(path,text)==nil)
}

sample :: proc(image:rl.Image) -> Sample {
    result:Sample
    for y in Height/2-2..=Height/2+2 {for x in Width/2-2..=Width/2+2 {
        color:=rl.GetImageColor(image,i32(x),i32(y))
        result.rgb+=[3]f64{f64(color.r),f64(color.g),f64(color.b)}
    }}
    result.rgb/=25
    result.luminance=.2126*result.rgb[0]+.7152*result.rgb[1]+.0722*result.rgb[2]
    return result
}

capture :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:string) -> Sample {
    for _ in 0..<3 {
        rl.BeginDrawing()
        assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK}))
        rl.EndDrawing()
    }
    image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
    assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
    return sample(image)
}

measure :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,entity,light_entity:ecs.Entity,
    model:string,pose:ecs.Transform,output,prefix:string) -> Model_Result {
    assert(ecs.set_transform(w,entity,pose))
    renderer:=ecs.ModelRenderer{model=model,tint={255,255,255,255},material=Lit_Material}
    assert(ecs.set(w,entity,renderer))
    light,found:=ecs.get_point_light(w,light_entity); assert(found)
    light.intensity=2; assert(ecs.set_point_light(w,light_entity,light))
    result:Model_Result
    result.on=capture(ctx,w,manager,fmt.tprintf("%s/%s-on.png",output,prefix))
    imported,loaded:=ctx.models[model]
    assert(loaded && imported.model.meshCount>0,"The production importer must load the no-UV OBJ")
    light.intensity=0; assert(ecs.set_point_light(w,light_entity,light))
    result.off=capture(ctx,w,manager,fmt.tprintf("%s/%s-off.png",output,prefix))
    renderer.material=Normal_Material; assert(ecs.set(w,entity,renderer))
    result.normal=capture(ctx,w,manager,fmt.tprintf("%s/%s-normal.png",output,prefix))
    assert(ctx.r3d_materials[Normal_Material].material.shader!=nil,"The normal diagnostic must compile instead of using a material fallback")
    result.light_gain=result.on.luminance-result.off.luminance
    result.passed=result.light_gain>20 && result.off.luminance<5 &&
        result.normal.rgb[1]>240 && result.normal.rgb[0]<5 && result.normal.rgb[2]<5
    return result
}

main :: proc() {
    output:="build/imported-tangent-validation"
    observe:=false
    for arg in os.args[1:] {
        if arg=="--observe" {observe=true}
        else if arg=="--runtime" {} // Accepted for consistency with other validators.
        else if arg=="--help" {fmt.println("Usage: imported_tangent_validation [output-directory] [--runtime] [--observe]"); return}
        else {assert(!strings.has_prefix(arg,"--"),"Unknown argument"); output=arg}
    }
    assert(os.make_directory_all(output)==nil || os.is_dir(output))
    write_quad(fmt.tprintf("%s/source.obj",output),0,{1,1,1})
    assert(os.write_entire_file(fmt.tprintf("%s/%s",output,Lit_Material),
        `{"lighting":true,"base_color":[100,130,150,255],"roughness":0.95,"metallic":0,"specular":0}`)==nil)
    assert(os.write_entire_file(fmt.tprintf("%s/%s",output,Normal_Material),
        `{"lighting":true,"surface_shader":"normal.glsl","base_color":[255,255,255,255]}`)==nil)
    assert(os.write_entire_file(fmt.tprintf("%s/%s",output,Normal_Shader),NORMAL_SHADER)==nil)

    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_HIDDEN,.WINDOW_ALWAYS_RUN})
    rl.InitWindow(Width,Height,"Rune imported tangent validation"); defer rl.CloseWindow()
    ctx,ready:=bridge.init(output,Width,Height); assert(ready); defer bridge.shutdown(&ctx)
    ctx.occlusion_enabled=false
    manager:=assets.init(output); defer assets.shutdown(&manager)
    registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
    assert(ecs.register_builtin_components(&registry))
    w:=ecs.init(); defer ecs.destroy(&w)
    camera:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
    assert(ecs.add(&w,&registry,camera,ecs.Camera3D{active=true,target={0,0,-3},up={0,1,0},fovy=45}))
    post:=ecs.default_post_processing(); post.anti_aliasing=.disabled
    assert(ecs.add(&w,&registry,camera,post))
    ambient:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0}))
    entity:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,entity,ecs.Transform{scale={1,1,1}}))
    assert(ecs.add(&w,&registry,entity,ecs.ModelRenderer{model="source.obj",tint={255,255,255,255},material=Lit_Material}))
    light:=ecs.create_entity(&w)
    assert(ecs.add(&w,&registry,light,ecs.Transform{scale={1,1,1}}))
    assert(ecs.add(&w,&registry,light,ecs.PointLight{color={255,255,255,255},intensity=2,range=10,specular=0,shadows=false}))
    report:=Report{complete=true,window_hidden=rl.IsWindowHidden(),scope="Production no-UV OBJ import, runtime yaw versus equivalent baked positions/normals; point-light gain and finite unit GPU lighting normal. No shadows, ambient, grading, screen effects, or bridge occlusion."}
    fixtures:=[4]Case{
        {name="yaw-zero",yaw=0,scale={1,1,1}},
        {name="yaw-negative-90",yaw=-90,scale={1,1,1}},
        {name="yaw-positive-90",yaw=90,scale={1,1,1}},
        {name="yaw-negative-90-nonuniform",yaw=-90,scale={0.5,1.3,0.8}},
    }
    center:=[3]f32{0,0,-3}
    for fixture in fixtures {
        baked_path:=fmt.aprintf("%s-baked.obj",fixture.name); defer delete(baked_path)
        write_quad(fmt.tprintf("%s/%s",output,baked_path),fixture.yaw,fixture.scale)
        normal:=rotate_y({1,0,0},fixture.yaw)
        assert(ecs.set_transform(&w,camera,ecs.Transform{position=center+normal*5,scale={1,1,1}}))
        assert(ecs.set_transform(&w,light,ecs.Transform{position=center+normal*2,scale={1,1,1}}))
        // Default submission/cache and uncached ordinary model submission must
        // agree. Custom normal diagnostic materials use ordinary submission.
        for direct in ([2]bool{false,true}) {
            ctx.instancing_enabled=!direct
            ctx.render_optimizations_disabled=direct
            result:=fixture
            result.name=fmt.aprintf("%s-%s",fixture.name,"direct" if direct else "default")
            result.imported=measure(&ctx,&w,&manager,entity,light,"source.obj",
                ecs.Transform{position=center,rotation={0,fixture.yaw,0},scale=fixture.scale},output,fmt.tprintf("%s-imported",result.name))
            result.baked=measure(&ctx,&w,&manager,entity,light,baked_path,
                ecs.Transform{position=center,scale={1,1,1}},output,fmt.tprintf("%s-baked",result.name))
            result.lighting_difference=abs(result.imported.on.luminance-result.baked.on.luminance)
            result.passed=result.imported.passed && result.baked.passed && result.lighting_difference<4
            report.complete=report.complete && result.passed
            append(&report.cases,result)
            fmt.printf("%s %s: imported gain %.2f, baked gain %.2f, difference %.2f\n",
                "PASS" if result.passed else "FAIL",result.name,result.imported.light_gain,result.baked.light_gain,result.lighting_difference)
        }
    }
    assert(len(manager.diagnostics.reported)==0,"Fixture assets and shaders must load without fallback diagnostics")
    bytes,error:=json.marshal(report,{pretty=true}); assert(error==nil); defer delete(bytes)
    assert(os.write_entire_file(fmt.tprintf("%s/report.json",output),bytes)==nil)
    fmt.printf("Report: %s/report.json\n",output)
    for result in report.cases {delete(result.name)}
    delete(report.cases)
    assert(observe || report.complete,"Every imported no-UV face must retain a finite unit lighting normal and match its lit baked equivalent")
}
