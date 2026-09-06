package render

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Begin camera drawing from screen space (outside another camera mode).
// raylib 6 BeginMode2D replaces the modelview, losing BeginDrawing's DPI scale.
// Compose the camera with the current screen transform instead. A render
// texture supplies identity here, so its pixels are not scaled by monitor DPI.
// Pair with raylib EndMode2D as usual.
begin_camera_2d :: proc(camera: rl.Camera2D) {
	screen := rlgl.GetMatrixModelview()
	rl.BeginMode2D(camera)
	rlgl.SetMatrixModelview(screen * rl.GetCameraMatrix2D(camera))
}
