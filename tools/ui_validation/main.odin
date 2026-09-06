package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "rune:console"
import rune "rune:core"
import "rune:input"
import "rune:ui"
import rl "vendor:raylib"

measure :: proc(text: string, size, spacing: f32) -> [2]f32 {return {f32(len(text))*size*0.5,size}}

scroll_layout :: proc(ctx: ^ui.Context, wheel: f32) {
	assert(ui.begin(ctx,{400,300},{pointer={10,10},scroll={0,wheel}},1.0/60))
	ui.scroll_panel(ctx,"scroll",{layout={sizing={width=ui.fixed(200),height=ui.fixed(100)},layoutDirection=.TopToBottom}})
	for i in 0..<8 {ui.button(ctx,fmt.tprintf("scroll_%d",i),"Scroll item")}
	ui.end_panel(ctx)
	assert(ui.finish(ctx),ui.last_error(ctx))
}

layout :: proc(ctx: ^ui.Context, controls: ui.Inputs, value: ^f32,
	width: f32 = 400, disable_first: bool = false) -> bool {
	assert(ui.begin(ctx,{width,300},controls,1.0/60))
	ui.panel(ctx,"root",{layout={sizing={width=ui.grow({}),height=ui.grow({})},
		layoutDirection=.TopToBottom,padding=ui.padding(20),childGap=12}})
	clicked := ui.button(ctx,"first","First",!disable_first)
	ui.slider(ctx,"slider",value,0,1,0.1)
	ui.button(ctx,"last","Last")
	ui.end_panel(ctx)
	assert(ui.finish(ctx),ui.last_error(ctx))
	return clicked
}

validate_widgets :: proc(tracker: ^mem.Tracking_Allocator) {
	ctx: ui.Context
	assert(ui.init(&ctx,measure=measure))
	assert(!ui.init(&ctx,measure=measure),"double init rejected")
	defer ui.destroy(&ctx)
	value: f32 = 0.5
	assert(!layout(&ctx,{},&value))
	assert(ui.focused(&ctx,"first"))
	assert(layout(&ctx,{activate=true},&value),"keyboard/gamepad accept")
	layout(&ctx,{next=true},&value)
	assert(ui.focused(&ctx,"slider"))
	layout(&ctx,{right=true},&value)
	assert(math.abs(value-0.6)<0.001)
	for _ in 0..<20 {layout(&ctx,{left=true},&value)}
	assert(value==0,"slider clamps to lower bound")
	layout(&ctx,{previous=true},&value)
	assert(ui.focused(&ctx,"first"))
	layout(&ctx,{previous=true},&value)
	assert(ui.focused(&ctx,"last"),"focus wraps")
	layout(&ctx,{next=true},&value)
	assert(ui.focused(&ctx,"first"))
	assert(!layout(&ctx,{activate=true},&value,disable_first=true),"disabled buttons never activate")
	assert(ui.focused(&ctx,"slider"),"disabled focus is repaired")
	layout(&ctx,{},&value)
	box,found:=ui.bounds(&ctx,"first")
	assert(found && box.x==20 && box.width==360 && box.height==46,"native Clay ABI and layout")
	point := [2]f32{box.x+box.width/2,box.y+box.height/2}
	assert(!layout(&ctx,{pointer=point,pointer_down=true},&value))
	assert(layout(&ctx,{pointer=point},&value),"mouse release activates captured button")
	layout(&ctx,{pointer=point,pointer_down=true},&value)
	assert(!layout(&ctx,{pointer={399,299}},&value),"release outside cancels")
	layout(&ctx,{pointer=point,pointer_down=true},&value)
	assert(!layout(&ctx,{pointer=point,blocked=true,activate=true},&value),"console/modal blocker cancels capture")
	assert(!layout(&ctx,{pointer=point},&value))
	bar,_:=ui.bounds(&ctx,"slider")
	layout(&ctx,{pointer={bar.x+bar.width*0.75,bar.y+5},pointer_down=true},&value)
	assert(math.abs(value-0.75)<0.001,"slider pointer mapping")
	layout(&ctx,{pointer={1000,bar.y},pointer_down=true},&value)
	assert(value==1,"drag stays captured beyond slider bounds")
	layout(&ctx,{},&value,width=800)
	box,found=ui.bounds(&ctx,"first")
	assert(found && box.width==760,"layout responds to window size")
	for _ in 0..<10 {layout(&ctx,{},&value)}
	before:=tracker.current_memory_allocated
	for _ in 0..<500 {layout(&ctx,{},&value)}
	assert(tracker.current_memory_allocated==before,"UI storage stays bounded after warmup")
	// Context switches must preserve each native arena; nested builds are rejected.
	other:ui.Context
	assert(ui.init(&other,measure=measure))
	assert(ui.begin(&ctx,{400,300},{},0))
	assert(!ui.begin(&other,{400,300},{},0))
	assert(ui.finish(&ctx))
	layout(&other,{},&value)
	ui.destroy(&other)
	ui.destroy(&other)
	layout(&ctx,{},&value)
	assert(ui.begin(&ctx,{400,300},{},0))
	ui.panel(&ctx,"unbalanced",{})
	assert(!ui.finish(&ctx) && ui.last_error(&ctx)!="")
	layout(&ctx,{},&value)
	scroll_layout(&ctx,0)
	before_scroll,_:=ui.bounds(&ctx,"scroll_0")
	scroll_layout(&ctx,-3)
	after_scroll,_:=ui.bounds(&ctx,"scroll_0")
	assert(after_scroll.y<before_scroll.y,"scroll panel applies Clay's wheel position")
}

validate_input_and_pause :: proc() {
	controls,ok:=input.load("examples/clay_ui/input/default.input.json")
	assert(ok)
	defer input.destroy(&controls)
	assert(input.inject_action(&controls,"ui_accept",true))
	assert(input.inject_action(&controls,"move_right",true))
	input.capture(&controls)
	assert(input.frame_action(&controls,"ui_accept").pressed,"UI injections work without a simulation tick")
	assert(!input.frame_action(&controls,"ui_accept").pressed,"UI edge consumed once")
	input.apply_injected_actions(&controls)
	assert(!input.pressed(&controls,"move_right") && input.axis(&controls,"move")==0,"capture gates gameplay")
	controls.captured=false
	assert(input.pressed(&controls,"move_right") && input.axis(&controls,"move")==1,"unread gameplay edge retained for simulation")
	game:=rune.Engine{console=console.init(),fixed_delta_time=1.0/60}
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game,nil)
	rune.set_paused(&game,true)
	assert(rune.is_paused(&game) && !rune.debug_simulation_tick(&game))
	assert(console.execute(&game.console,"step 2"))
	for _ in 0..<2 {
		assert(rune.debug_simulation_tick(&game) && game.delta_time==game.fixed_delta_time)
		rune.debug_simulation_finished(&game)
	}
	assert(!game.console.defer_reply && !rune.debug_simulation_tick(&game))
	assert(console.execute(&game.console,"pause"))
	rune.set_paused(&game,false)
	assert(rune.is_paused(&game),"closing menu preserves console pause")
	assert(console.execute(&game.console,"resume"))
	assert(!rune.is_paused(&game))
}

validate_rendering :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(400,300,"Clay validation")
	defer rl.CloseWindow()
	ctx:ui.Context
	assert(ui.init(&ctx))
	defer ui.destroy(&ctx)
	value:f32=0.5
	layout(&ctx,{},&value)
	focus:=ctx.focus_id
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		assert(ui.draw(&ctx))
		rl.EndDrawing()
	}
	assert(ctx.focus_id==focus && value==0.5,"draw does not evaluate interactions")
	image:=rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	pixel:=rl.GetImageColor(image,25,25)
	assert(pixel.r>0 || pixel.g>0 || pixel.b>0,"native commands render visible pixels")
	// Nested clipping restores the outer clip after an inner container ends.
	assert(ui.begin(&ctx,{400,300},{},0))
	ui.panel(&ctx,"outer",{layout={sizing={width=ui.fixed(100),height=ui.fixed(100)}},clip={horizontal=true,vertical=true}})
	ui.panel(&ctx,"inner",{layout={sizing={width=ui.fixed(60),height=ui.fixed(60)}},clip={horizontal=true,vertical=true}})
	ui.panel(&ctx,"green",{layout={sizing={width=ui.fixed(300),height=ui.fixed(300)}},backgroundColor={0,255,0,255}})
	ui.end_panel(&ctx)
	ui.end_panel(&ctx)
	ui.panel(&ctx,"red",{layout={sizing={width=ui.fixed(100),height=ui.fixed(100)}},backgroundColor={255,0,0,255}})
	ui.end_panel(&ctx)
	ui.end_panel(&ctx)
	assert(ui.finish(&ctx),ui.last_error(&ctx))
	// Readback after presentation may expose the previous back buffer on Windows.
	// Present the same immutable command list on both buffers before sampling.
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		assert(ui.draw(&ctx))
		rl.EndDrawing()
	}
	clipped:=rl.LoadImageFromScreen()
	defer rl.UnloadImage(clipped)
	assert(rl.GetImageColor(clipped,150,50)==rl.BLACK,"outer clip remains active")
	assert(rl.GetImageColor(clipped,80,50)==rl.Color{255,0,0,255},"outer clip is restored after inner ends")
	assert(rl.GetImageColor(clipped,30,30)==rl.Color{0,255,0,255},"inner content draws inside clip")
}

main :: proc() {
	tracker:mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	scratch:mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator=mem.dynamic_arena_allocator(&scratch)
	context.allocator=mem.tracking_allocator(&tracker)
	validate_widgets(&tracker)
	validate_input_and_pause()
	for arg in os.args[1:] {if arg=="--runtime" {validate_rendering()}}
	assert(tracker.current_memory_allocated==0 && len(tracker.bad_free_array)==0,"all UI storage released")
	fmt.println("Clay UI: layout, resize, focus, activation, capture, slider, bounded memory, pause/step and cleanup passed")
}
