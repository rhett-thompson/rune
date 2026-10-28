// Isolated native memory-image decoding. No graphics context, raylib callbacks,
// or shared decoder symbols are used. Inputs are borrowed for the call only.
package image_decode

import "core:c"
import "core:path/filepath"
import "core:strings"

// Owns native pixels; do not copy ownership. destroy frees through the same
// private native allocator on any thread and zeros this value.
// LDR images preserve 1..4 channels as u8; HDR images preserve f32 channels.
Image :: struct {
	pixels: rawptr,
	width, height, channels: i32,
	floating_point: b32,
	size_bytes: u64,
}

Default_Output_Limit :: u64(256*1024*1024)
IS_SUPPORTED :: ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux)

when IS_SUPPORTED {#assert(size_of(Image)==32)}

when ODIN_ARCH == .amd64 && ODIN_OS == .Windows {
	foreign import native "../../third_party/rune-image/windows/image_decode.lib"
} else when ODIN_ARCH == .amd64 && ODIN_OS == .Linux {
	foreign import native {"../../third_party/rune-image/linux/libimage_decode.a", "system:m"}
}

when IS_SUPPORTED {
	@(default_calling_convention="c")
	foreign native {
		@(link_name="Rune_Image_Decode")
		native_decode :: proc(bytes: rawptr, size: c.size_t, limit: u64, image: ^Image, error: rawptr, error_capacity: c.size_t) -> c.int ---
		@(link_name="Rune_Image_Free")
		native_free :: proc(pixels: rawptr) ---
	}
}

// error_buffer receives a NUL-terminated copy on failure and is cleared on
// success. It can be omitted. The returned pixels are independently owned and
// never use Odin frame/worker scratch. Sixteen-bit LDR sources narrow to u8.
decode :: proc(bytes: []u8, error_buffer: []u8 = nil, maximum_output_bytes: u64 = Default_Output_Limit) -> (image: Image, ok: bool) {
	when IS_SUPPORTED {
		ok=native_decode(raw_data(bytes),c.size_t(len(bytes)),maximum_output_bytes,&image,raw_data(error_buffer),c.size_t(len(error_buffer)))!=0
	} else {
		if len(error_buffer)>0 {
			message:="image decoding is unsupported on this target"
			count:=min(len(message),len(error_buffer)-1)
			copy(error_buffer[:count],transmute([]u8)message[:count]);error_buffer[count]=0
		}
	}
	return
}

destroy :: proc(image: ^Image) {
	if image==nil {return}
	when IS_SUPPORTED {if image.pixels!=nil {native_free(image.pixels)}}
	image^={}
}

// Borrow the caller's error buffer as text. Copy it into owned storage if it
// must outlive that buffer; no process-global last-error pointer is exposed.
error_text :: proc(buffer: []u8) -> string {
	end:=0
	for end<len(buffer) && buffer[end]!=0 {end+=1}
	return string(buffer[:end])
}

// Unsupported container/compressed GPU formats keep their existing loader path.
// The native decoder identifies bytes itself; this helper gates legacy paths.
supports_extension :: proc(path: string) -> bool {
	ext:=filepath.ext(path)
	for supported in ([12]string{".png",".jpg",".jpeg",".bmp",".tga",".hdr",".pic",".psd",".gif",".pnm",".ppm",".pgm"}) {
		if strings.equal_fold(ext,supported) {return true}
	}
	return false
}
