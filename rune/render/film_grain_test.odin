package render

import "core:math"
import "core:testing"
import "rune:ecs"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

@(test)
film_grain_parameters_bound_animation_and_match_reference_pixel_size :: proc(t: ^testing.T) {
	settings:=ecs.Post_Film_Grain{enabled=true,intensity=0.05,size=2,speed=5}
	params,valid:=film_grain_parameters(settings,3,0.5)
	testing.expect(t,valid && params==[3]f32{0.05,4,15})
	wrapped,wrap_valid:=film_grain_parameters(settings,65536+3)
	testing.expect(t,wrap_valid && wrapped==[3]f32{0.05,2,15})
	settings.speed=0
	frozen,frozen_valid:=film_grain_parameters(settings,1e12)
	testing.expect(t,frozen_valid && frozen==[3]f32{0.05,2,0})
}

@(test)
film_grain_disabled_and_invalid_settings_allocate_nothing :: proc(t: ^testing.T) {
	settings:=ecs.Post_Film_Grain{enabled=true,intensity=0.05,size=1,speed=5}
	bad:=[8]ecs.Post_Film_Grain{settings,settings,settings,settings,settings,settings,settings,settings}
	bad[0].enabled=false; bad[1].intensity=0; bad[2].intensity=math.nan_f32(); bad[3].intensity=1.1
	bad[4].size=0; bad[5].size=9; bad[6].speed=-1; bad[7].speed=math.inf_f32(1)
	effect:Film_Grain_Effect
	for value in bad {testing.expect(t,!begin_film_grain(&effect,value,0) && !effect.attempted && effect.shader.id==0)}
	for seconds in ([4]f64{-1,math.nan_f64(),math.inf_f64(1),math.inf_f64(-1)}) {
		_,valid:=film_grain_parameters(settings,seconds)
		testing.expect(t,!valid)
	}
	for scale in ([4]f32{0,-1,math.nan_f32(),math.inf_f32(1)}) {
		_,valid:=film_grain_parameters(settings,0,scale)
		testing.expect(t,!valid)
	}
	destroy_film_grain(&effect)
	testing.expect(t,effect==Film_Grain_Effect{})
}

when #config(FILM_GRAIN_RUNTIME_TEST,false) {
	film_grain_test_frame :: proc(effect:^Film_Grain_Effect,settings:ecs.Post_Film_Grain,seconds:f64) -> rl.Image {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		active:=begin_film_grain(effect,settings,seconds)
		rl.DrawRectangle(0,0,96,96,{128,128,128,255})
		// Transparent texture/tint coverage must not deposit grain on the image.
		rl.DrawRectangle(0,0,96,96,{255,0,0,0})
		if active {end_film_grain(effect)}
		rlgl.DrawRenderBatchActive()
		image:=rl.LoadImageFromScreen()
		rl.EndDrawing()
		return image
	}

	@(test)
	film_grain_2d_runtime_compiles_animates_freezes_and_preserves_neutral_alpha :: proc(t: ^testing.T) {
		rl.SetConfigFlags({.WINDOW_HIDDEN})
		rl.InitWindow(96,96,"Film grain 2D validation"); defer rl.CloseWindow()
		effect:Film_Grain_Effect; defer destroy_film_grain(&effect)
		settings:=ecs.Post_Film_Grain{enabled=true,intensity=0.2,size=2,speed=0}
		grain:=film_grain_test_frame(&effect,settings,0); defer rl.UnloadImage(grain)
		testing.expect(t,effect.shader.id!=0 && !effect.active && active_film_grain==nil,"The shared R3D grain kernel compiles as a 2D shader and leaves the shader mode balanced")
		frozen:=film_grain_test_frame(&effect,settings,1000); defer rl.UnloadImage(frozen)
		settings.speed=5
		animated:=film_grain_test_frame(&effect,settings,1); defer rl.UnloadImage(animated)
		settings.enabled=false
		off:=film_grain_test_frame(&effect,settings,1); defer rl.UnloadImage(off)
		changed,tinted,unfrozen,not_plain:=0,0,0,0; low,high:=255,0
		for y:i32=8; y<88; y+=1 {for x:i32=8; x<88; x+=1 {
			pixel:=rl.GetImageColor(grain,x,y)
			low=min(low,int(pixel.r)); high=max(high,int(pixel.r))
			if pixel.r!=pixel.g || pixel.g!=pixel.b || pixel.a!=255 {tinted+=1}
			if pixel!=rl.GetImageColor(frozen,x,y) {unfrozen+=1}
			if pixel!=rl.GetImageColor(animated,x,y) {changed+=1}
			plain:=rl.GetImageColor(off,x,y)
			if plain.r!=128 || plain.g!=128 || plain.b!=128 {not_plain+=1}
		}}
		testing.expect(t,tinted==0,"Noise remains monochrome and transparent draws leave no red tint")
		testing.expect(t,unfrozen==0,"Zero speed freezes the pattern")
		testing.expect(t,not_plain==0,"Disabling grain restores exact source colors")
		testing.expect(t,high-low>15 && changed>1000,"Grain is visible and changes with the animation clock")
	}
}
