package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:validation"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"
import gl "vendor:OpenGL"

PATH :: "build/material-wrap-validation.material.json"

main :: proc() {
    defer os.remove(PATH)
    assert(os.write_entire_file(PATH, `{}`)==nil)
    defaults,ok:=assets.load_material_data(PATH); assert(ok && defaults.wrap=="")
    defer assets.destroy_material_data(&defaults)
    inputs:=[]string{`{"wrap":"clamp"}`,`{"wrap":"repeat"}`,`{"wrap":"mirror_repeat"}`}
    for name,i in ([]string{"clamp","repeat","mirror_repeat"}) {
        assert(os.write_entire_file(PATH,inputs[i])==nil)
        data,accepted:=assets.load_material_data(PATH)
        assert(accepted && data.wrap==name)
        assert(assets.material_data_signature(data)!=assets.material_data_signature(defaults))
        assert(assets.generated_orm_key(nil,data)!=assets.generated_orm_key(nil,defaults))
        owned:=assets.clone_material_data(data)
        bytes:=transmute([]u8)owned.wrap; bytes[0]='X'
        assert(data.wrap==name && owned.wrap!=data.wrap,"wrap strings must be independently owned")
        assets.destroy_material_data(&owned); assets.destroy_material_data(&data)
        report:=validation.init_report()
        validation.validate_material(&report,PATH,"build")
        assert(validation.is_valid(&report))
        validation.destroy_report(&report)
    }
    for invalid in ([]string{`{"wrap":""}`,`{"wrap":"invalid"}`,`{"wrap":true}`,`{"wrap":1}`}) {
        assert(os.write_entire_file(PATH,invalid)==nil)
        _,accepted:=assets.load_material_data(PATH); assert(!accepted)
        report:=validation.init_report()
        validation.validate_material(&report,PATH,"build")
        assert(!validation.is_valid(&report))
        validation.destroy_report(&report)
    }
    fmt.println("Material wrap parsing, ownership, signatures and authoring validation passed")
    for arg in os.args[1:] {if arg=="--runtime" {validate_runtime(defaults)}}
}

expect_wrap :: proc(texture: rl.Texture2D, expected: i32) {
    assert(texture.id!=0)
    gl.BindTexture(gl.TEXTURE_2D,texture.id)
    s,t:i32
    gl.GetTexParameteriv(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,&s)
    gl.GetTexParameteriv(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,&t)
    assert(s==expected && t==expected,"both GPU texture axes must honor authored wrap")
    gl.BindTexture(gl.TEXTURE_2D,0)
}

validate_runtime :: proc(base: assets.Material_Data) {
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_HIDDEN})
    rl.InitWindow(320,240,"Material wrap GPU validation"); defer rl.CloseWindow()
    gl.load_up_to(3,3,proc(p:rawptr,name:cstring) {(^rawptr)(p)^=rlgl.GetProcAddress(name)})
    manager:=assets.init("build"); defer assets.shutdown(&manager)
    ctx,ok:=bridge.init("build",320,240); assert(ok); defer bridge.shutdown(&ctx)
    image:=rl.GenImageColor(8,8,{40,140,220,255}); defer rl.UnloadImage(image)
    assert(rl.ExportImage(image,"build/material-wrap-validation.png"))
    defer os.remove("build/material-wrap-validation.png")
    data:=base
    data.texture="material-wrap-validation.png"; data.normal=data.texture
    data.emission=data.texture; data.orm_texture=data.texture
    data.filter="point"; data.mipmaps=false
    modes:=[]string{"","clamp","repeat","mirror_repeat"}
    expected:=[]i32{gl.CLAMP_TO_EDGE,gl.CLAMP_TO_EDGE,gl.REPEAT,gl.MIRRORED_REPEAT}
    for name,i in modes {
        data.wrap=name
        mat:=bridge.material_from_data(&ctx,&manager,fmt.tprintf("file-wrap-%d",i),data)
        for texture in ([4]rl.Texture2D{mat.albedo.texture,mat.normal.texture,mat.emission.texture,mat.orm.texture}) {
            expect_wrap(texture,expected[i])
        }
    }
    data.orm_texture=""; data.roughness_texture=data.texture
    data.wrap="repeat"
    repeated,repeat_ok:=assets.material_orm_texture(&manager,data); assert(repeat_ok)
    expect_wrap(repeated,gl.REPEAT)
    data.wrap="clamp"
    clamped,clamp_ok:=assets.material_orm_texture(&manager,data); assert(clamp_ok)
    assert(repeated.id!=clamped.id,"packed ORM materials with differing wrap need separate cached textures")
    expect_wrap(clamped,gl.CLAMP_TO_EDGE); expect_wrap(repeated,gl.REPEAT)
    data.wrap="repeat"
    cached,cached_ok:=assets.material_orm_texture(&manager,data)
    assert(cached_ok && cached.id==repeated.id)
    procedural:=base
    procedural.procedural=assets.default_procedural_material(); procedural.procedural.resolution=16
    procedural.filter="point"; procedural.mipmaps=false
    for name,i in modes {
        procedural.wrap=name
        mat:=bridge.material_from_data(&ctx,&manager,fmt.tprintf("procedural-wrap-%d",i),procedural)
        actual:=expected[i]; if name=="" {actual=gl.REPEAT}
        for texture in ([3]rl.Texture2D{mat.albedo.texture,mat.normal.texture,mat.orm.texture}) {expect_wrap(texture,actual)}
    }
    assert(len(manager.diagnostics.reported)==0)
    fmt.println("File-map GPU wrap, procedural defaults/overrides and packed ORM cache isolation passed")
}
