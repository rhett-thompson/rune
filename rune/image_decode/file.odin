package image_decode

import "base:runtime"
import "core:os"

// Worker-safe bounded file input. Paths must already be owned and absolute;
// callers validate their dependency stamps again before publishing results.
decode_file :: proc(path:string,maximum_input_bytes:u64,maximum_output_bytes:u64,error_buffer:[]u8) -> (Image,bool) {
	file,open_error:=os.open(path)
	if open_error!=nil {decode_file_error(error_buffer,"could not open image input");return {},false}
	defer os.close(file)
	size,size_error:=os.file_size(file)
	if size_error!=nil || size<=0 || u64(size)>maximum_input_bytes {
		decode_file_error(error_buffer,"image input exceeds its byte budget or is empty");return {},false
	}
	a:=runtime.default_context().allocator
	bytes,allocation_error:=make([]u8,int(size),a)
	if allocation_error!=nil {decode_file_error(error_buffer,"could not allocate image input");return {},false}
	defer delete(bytes,a)
	offset:=0
	for offset<len(bytes) {
		count,read_error:=os.read(file,bytes[offset:]);offset+=count
		if read_error!=nil || count==0 {decode_file_error(error_buffer,"could not read complete image input");return {},false}
	}
	return decode(bytes,error_buffer,maximum_output_bytes)
}

decode_file_error :: proc(buffer:[]u8,message:string) {
	if len(buffer)==0 {return}
	count:=min(len(message),len(buffer)-1)
	copy(buffer[:count],transmute([]u8)message[:count]);buffer[count]=0
}
