package console

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Max_Path_Length :: 1024

Capture_Request :: struct {
	path: [Max_Path_Length]u8,
	len:  int,
}

capture_command :: proc(console: ^Console, arguments: string) {
	if console.capture.len > 0 {
		error(console, "A frame capture is already pending.")
		return
	}
	path := arguments
	if len(path) == 0 {
		path = fmt.tprintf("build/captures/frame-%d.png", time.to_unix_nanoseconds(time.now()))
	}
	if len(path) >= Max_Path_Length || !strings.has_suffix(path, ".png") {
		error(console, "Capture requires a path ending in .png (under 1024 bytes).")
		return
	}
	copy(console.capture.path[:], path)
	console.capture.len = len(path)
}

// finish_frame runs after game/gizmo drawing and before the console overlay,
// inside BeginDrawing/EndDrawing. Flush raylib's batch before reading pixels.
finish_frame :: proc(console: ^Console) {
	if console.capture.len > 0 {
		path := string(console.capture.path[:console.capture.len])
		directory, _ := filepath.split(path)
		if len(directory) > 0 && os.make_directory_all(directory) != nil {
			error(console, "Could not create capture directory.")
		} else {
			rlgl.DrawRenderBatchActive()
			frame := rl.LoadImageFromScreen()
			if frame.data == nil {
				error(console, "Could not read the rendered frame.")
			} else {
				path_c, _ := strings.clone_to_cstring(path, context.temp_allocator)
				if rl.ExportImage(frame, path_c) {
					info(console, fmt.tprintf("Captured frame: %s", path))
					absolute_path, _ := filepath.abs(path, context.temp_allocator)
					set_result(console, struct {
						path: string,
						width, height: i32,
						metadata: Frame_Metadata,
					}{absolute_path, frame.width, frame.height, console.frame_metadata})
				} else {
					error(console, fmt.tprintf("Could not save capture: %s", path))
				}
				rl.UnloadImage(frame)
			}
		}
		console.capture.len = 0
	}
	finish_remote(console)
}
