package image_decode

import "core:testing"
import "core:strings"
import "core:sync"
import "core:fmt"
import "rune:jobs"
import rl "vendor:raylib"
import stbi "vendor:stb/image"

png_fixture := #load("fixtures/asymmetric.png")
jpeg_fixture := #load("fixtures/asymmetric.jpg")
gray_fixture := #load("fixtures/gray.png")
gray_alpha_fixture := #load("fixtures/gray_alpha.png")
decoder_raylib_test_mutex:sync.Mutex

fixture :: proc(extension:cstring) -> []u8 {
	if string(extension)==".png" {return png_fixture}
	return jpeg_fixture
}

@(test)
decoder_preserves_channels_hdr_and_owned_output_limits :: proc(t:^testing.T) {
	if !IS_SUPPORTED {return}
	png:=fixture(".png")
	jpeg:=fixture(".jpg")
	for bytes,index in ([2][]u8{png,jpeg}) {
		error:[256]u8
		image,ok:=decode(bytes,error[:])
		testing.expect(t,ok && error_text(error[:])=="" && image.pixels!=nil,error_text(error[:]))
		testing.expect(t,image.width==2 && image.height==3 && !image.floating_point)
		testing.expect(t,image.channels==(4 if index==0 else 3) && image.size_bytes==u64(6*image.channels))
		if index==0 {testing.expect(t,([^][4]u8)(image.pixels)[0]==[4]u8{255,0,0,255})}
		destroy(&image);testing.expect(t,image==Image{})
	}
	for bytes,index in ([2][]u8{gray_fixture,gray_alpha_fixture}) {
		image,ok:=decode(bytes)
		testing.expect(t,ok && image.channels==i32(index+1) && image.width==2 && image.height==1 && image.size_bytes==u64(2*(index+1)))
		if ok {
			pixels:=([^]u8)(image.pixels)
			testing.expect(t,pixels[0]==32 && pixels[index+1]==224,"grayscale channels retain source sample values")
			if index==1 {testing.expect(t,pixels[1]==255 && pixels[3]==128,"gray-alpha preserves both alpha samples")}
		}
		destroy(&image)
	}
	hdr:="#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n\x80\x40\x20\x81"
	image,ok:=decode(transmute([]u8)hdr)
	testing.expect(t,ok && image.floating_point && image.width==1 && image.height==1 && image.channels==3 && image.size_bytes==12)
	if ok {testing.expect(t,([^]f32)(image.pixels)[0]==1 && ([^]f32)(image.pixels)[1]==0.5 && ([^]f32)(image.pixels)[2]==0.25)}
	destroy(&image)
	error:[256]u8
	image,ok=decode(png,error[:],maximum_output_bytes=23)
	testing.expect(t,!ok && image==Image{} && error_text(error[:])=="decoded image exceeds output limit")
	image,ok=decode(png,error[:],maximum_output_bytes=24)
	testing.expect(t,ok && error_text(error[:])=="");destroy(&image)
	image,ok=decode(nil,error[:]);testing.expect(t,!ok && image==Image{} && error_text(error[:])!="")
	one:=[1]u8{123};image,ok=decode(nil,one[:]);testing.expect(t,!ok && one[0]==0)
	for extension in ([4]string{"image.PNG","image.JpEg","image.hdr","image.pgm"}) {testing.expect(t,supports_extension(extension))}
	for extension in ([4]string{"image.dds","image.ktx","image.qoi","image"}) {testing.expect(t,!supports_extension(extension))}
}

Decode_Work :: struct {png,jpeg:[]u8,writes:[]int,errors:[][128]u8,invalid:[5][]u8,expected:[5][128]u8}

decode_job :: proc(index:int,data:rawptr) {
	work:=(^Decode_Work)(data)
	bytes:=work.png if index%2==0 else work.jpeg
	for _ in 0..<12 {
		image,ok:=decode(bytes,work.errors[index][:])
		if !ok || image.width!=2 || image.height!=3 || image.pixels==nil {destroy(&image);work.writes[index]=-1;return}
		destroy(&image)
		kind:=index%len(work.invalid)
		image,ok=decode(work.invalid[kind],work.errors[index][:])
		if ok || image.pixels!=nil || error_text(work.errors[index][:])!=error_text(work.expected[kind][:]) {destroy(&image);work.writes[index]=-1;return}
	}
	work.writes[index]+=1
}

@(test)
decoder_isolates_concurrent_failures_from_raylib_globals :: proc(t:^testing.T) {
	if !IS_SUPPORTED {return}
	sync.mutex_lock(&decoder_raylib_test_mutex);defer sync.mutex_unlock(&decoder_raylib_test_mutex)
	pool:=jobs.create(3,2)
	if !testing.expect(t,pool!=nil) {return}
	defer jobs.destroy(pool)
	png:=fixture(".png")
	jpeg:=fixture(".jpg")
	// This binding resolves to raylib's public stbi copy in the tested static
	// link. Private Rune symbols cannot resolve to or modify that implementation.
	invalid:=[]u8{1,2,3,4}
	invalid_image:=rl.LoadImageFromMemory(".png",raw_data(invalid),i32(len(invalid)))
	rl.UnloadImage(invalid_image)
	x,y,channels:i32
	_=stbi.info_from_memory(raw_data(invalid),i32(len(invalid)),&x,&y,&channels)
	before,_:=strings.clone(string(stbi.failure_reason()));defer delete(before)
	stbi.set_flip_vertically_on_load(1);defer stbi.set_flip_vertically_on_load(0)
	work:=Decode_Work{png=png,jpeg=jpeg,writes=make([]int,64),errors=make([][128]u8,64)}
	defer delete(work.writes);defer delete(work.errors)
	bad_png:=make([]u8,len(png));defer delete(bad_png);copy(bad_png,png)
	bad_chunk_a:=make([]u8,len(png));defer delete(bad_chunk_a);copy(bad_chunk_a,png)
	bad_chunk_b:=make([]u8,len(png));defer delete(bad_chunk_b);copy(bad_chunk_b,png)
	for i in 0..<len(bad_png)-4 {
		if string(bad_png[i:i+4])=="IDAT" {
			bad_png[i+4]=0
		}
		if string(bad_png[i:i+4])=="IEND" {
			copy(bad_chunk_a[i:i+4],[]u8{'A','B','C','D'})
			copy(bad_chunk_b[i:i+4],[]u8{'E','F','G','H'})
			break
		}
	}
	work.invalid={bad_png,invalid,jpeg[:2],bad_chunk_a,bad_chunk_b}
	for bytes,index in work.invalid {
		image,ok:=decode(bytes,work.expected[index][:])
		testing.expect(t,!ok && image.pixels==nil && error_text(work.expected[index][:])!="")
		destroy(&image)
	}
	testing.expect(t,error_text(work.expected[0][:])!=error_text(work.expected[1][:]),"concurrent failure fixtures exercise distinct TLS errors")
	testing.expect(t,error_text(work.expected[3][:])!=error_text(work.expected[4][:]),"unknown PNG chunks have distinct thread-local message buffers")
	jobs.parallel_for(pool,len(work.writes),decode_job,&work)
	for writes,index in work.writes {testing.expect(t,writes==1,error_text(work.errors[index][:]))}
	testing.expect(t,before!="" && string(stbi.failure_reason())==before,"private TLS errors do not modify raylib's global failure state")
	image,ok:=decode(png)
	testing.expect(t,ok && ([^][4]u8)(image.pixels)[0]==[4]u8{255,0,0,255},"raylib's global flip setting cannot change private decoder orientation")
	destroy(&image)
}

@(test)
decoder_matches_legacy_png_jpeg_hdr_pixel_and_format_semantics :: proc(t:^testing.T) {
	if !IS_SUPPORTED {return}
	sync.mutex_lock(&decoder_raylib_test_mutex);defer sync.mutex_unlock(&decoder_raylib_test_mutex)
	hdr:="#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n\x80\x40\x20\x81"
	sources:=[5][]u8{png_fixture,jpeg_fixture,gray_fixture,gray_alpha_fixture,transmute([]u8)hdr}
	types:=[5]cstring{".png",".jpg",".png",".png",".hdr"}
	for source,index in sources {
		legacy:=rl.LoadImageFromMemory(types[index],raw_data(source),i32(len(source)))
		image,ok:=decode(source)
		if !rl.IsImageValid(legacy) {
			fmt.printf("SKIP legacy pixel parity %s: installed raylib does not decode the fixture; private decoding remains independently tested.\n",string(types[index]))
			testing.expect(t,ok,"the isolated decoder supports the independently validated fixture")
			rl.UnloadImage(legacy);destroy(&image);continue
		}
		legacy_bytes:=rl.GetPixelDataSize(legacy.width,legacy.height,legacy.format)
		expected:=[5]rl.PixelFormat{.UNCOMPRESSED_R8G8B8A8,.UNCOMPRESSED_R8G8B8,.UNCOMPRESSED_GRAYSCALE,.UNCOMPRESSED_GRAY_ALPHA,.UNCOMPRESSED_R32G32B32}
		testing.expect(t,ok && rl.IsImageValid(legacy) && legacy.width==image.width && legacy.height==image.height && legacy.format==expected[index],
			"private decoding preserves the legacy pixel layout for this source")
		testing.expect(t,u64(legacy_bytes)==image.size_bytes)
		if ok && legacy.data!=nil && u64(legacy_bytes)==image.size_bytes {
			a,b:=([^]u8)(legacy.data)[:legacy_bytes],([^]u8)(image.pixels)[:int(image.size_bytes)]
			for byte,i in a {testing.expect(t,byte==b[i],"private and legacy decoded pixels match exactly")}
		}
		rl.UnloadImage(legacy);destroy(&image)
	}
}
