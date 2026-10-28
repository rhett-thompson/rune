# Isolated Rune image decoder

This native wrapper decodes owned memory into CPU pixels without raylib, file
callbacks, path helpers, logging, or GPU calls. `STB_IMAGE_STATIC` gives every
`stbi_*` function internal linkage. Only `Rune_Image_Decode` and `Rune_Image_Free`
are public. Compilation requires STB's thread-local failure state; each call
copies its error into a caller-provided buffer on that same thread. Private
decoder settings are never exported or changed.

`stb_image.h` derives from the v2.30 header in pinned raylib revision
`c1ab645ca298a2801097931d1079b10ff7eb9df8`; [sources.json](sources.json) records upstream and
altered SHA-256 hashes and the Zig 0.15.2 build pin.
[thread-local-png-error.patch](thread-local-png-error.patch) makes the unknown
critical PNG chunk message buffer thread-local too. Upstream's failure pointer
was TLS, but that mutable string buffer was still shared. The checked-in altered
header retains its dual MIT/public-domain
license, also reproduced in [LICENSE.stb_image](LICENSE.stb_image). The wrapper
is Rune source under the repository's zlib license. Preserve both notices in
distributed native artifacts.

`rune:image_decode` owns native pixels independently of Odin allocators. Decode
borrows input bytes only for the call. Successful LDR results preserve 1–4 u8
channels; 16-bit LDR sources narrow to u8, matching Rune's ordinary image path.
HDR sources preserve f32 channels. GIF decoding returns the first image.
Dimensions and channels are checked before allocation against the caller's
decoded-output limit (default 256 MiB). This bounds the returned buffer, not all
decoder working memory or encoded input. Use `image_decode.destroy` to release
pixels through this wrapper; never pass private pixels to raylib `UnloadImage`
or an API that takes ownership and frees its input. Read-only texture upload can
borrow them, while ownership-taking uploads require a separately allocated copy.

Rebuild from Rune's root on Windows with the MSVC headers/Windows SDK installed:

```powershell
./tools/build_image_decode.ps1 -Zig path/to/zig.exe -Target All
```

Linux (GNU target):

```sh
sh tools/build_image_decode.sh --zig path/to/zig
```

Scripts verify the private header hash and Zig version, perform no downloads,
and keep objects/caches under ignored `build/`. The Windows script can build
both AMD64 archives; the Linux script rebuilds the Linux archive. Normal Odin
builds use the checked-in archives and require no native compiler.

Audit both archives with ordinary Python 3, without loading native code:

```sh
python tools/audit_image_decode.py third_party/rune-image/windows/image_decode.lib third_party/rune-image/linux/libimage_decode.a
```

The audit inspects public COFF/ELF symbols and both error buffers' TLS storage. It rejects any public
STB symbols, preventing raylib's copy from satisfying private decoder calls.
`rune/image_decode/image_decode_test.odin` concurrently decodes valid PNG/JPEG
and malformed input, checks error isolation from raylib, orientation, HDR float
pixels, output bounds, and cleanup. The four package tests also exercise the
bounded file-input helper. They passed with pinned October Odin on Windows AMD64
using MSVC and on Ubuntu 26.04 WSL2 (Linux
`6.18.33.2-microsoft-standard-WSL2`). The Linux run executes the checked-in ELF
archive through the Odin ABI, including concurrent decoding and destruction;
it is not only a cross-build check. These headless tests do not establish GPU
upload or whole-loader behavior. Both archives pass the symbol/TLS audit.

Sequential comparison with the selected raylib artifact also checks PNG RGBA,
grayscale, and gray-alpha pixels and formats. The installed raylib artifact
rejects the JPEG and HDR fixture formats; those parity branches report their
limits explicitly, while private JPEG/HDR decoding is checked independently.
