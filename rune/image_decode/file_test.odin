package image_decode

import "core:testing"
import "core:os"
import "core:path/filepath"
import "rune:pathutil"

@(test)
decode_file_enforces_input_output_limits_and_missing_file_errors :: proc(t:^testing.T) {
	if !IS_SUPPORTED {return}
	directory,err:=os.make_directory_temp("build","image-decode-file-*",context.allocator)
	if !testing.expect(t,err==nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	path,_:=filepath.join({directory,"fixture.png"},context.temp_allocator)
	absolute,path_error:=pathutil.absolute(path,context.temp_allocator)
	if !testing.expect(t,path_error==nil) {return}
	if !testing.expect(t,os.write_entire_file(path,png_fixture)==nil) {return}
	error:[128]u8
	image,ok:=decode_file(absolute,u64(len(png_fixture)),24,error[:])
	testing.expect(t,ok && image.size_bytes==24 && image.width==2 && image.height==3 && error_text(error[:])=="",error_text(error[:]))
	destroy(&image)
	image,ok=decode_file(absolute,u64(len(png_fixture)-1),24,error[:])
	testing.expect(t,!ok && image==Image{} && error_text(error[:])=="image input exceeds its byte budget or is empty")
	image,ok=decode_file(absolute,u64(len(png_fixture)),23,error[:])
	testing.expect(t,!ok && image==Image{} && error_text(error[:])=="decoded image exceeds output limit")
	if !testing.expect(t,os.write_entire_file(path,[]u8{})==nil) {return}
	image,ok=decode_file(absolute,1024,1024,error[:])
	testing.expect(t,!ok && image==Image{} && error_text(error[:])=="image input exceeds its byte budget or is empty")
	testing.expect(t,os.remove(path)==nil)
	image,ok=decode_file(absolute,1024,1024,error[:])
	testing.expect(t,!ok && image==Image{} && error_text(error[:])=="could not open image input")
	image,ok=decode_file(absolute,1024,1024,nil)
	testing.expect(t,!ok && image==Image{},"optional error storage is never dereferenced when absent")
}
