#!/bin/sh
set -eu
zig=zig
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = '--zig' ] || { echo 'Usage: sh tools/build_image_decode.sh [--zig executable]' >&2; exit 1; }
    zig=$2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
native_root=$root/third_party/rune-image
pin() { awk -F '"' -v key="$1" 'index($0, "\"" key "\"") && $0 ~ /:/ { print $4; exit }' "$native_root/sources.json"; }
[ "$("$zig" version)" = "$(pin zig)" ] || { echo 'Unexpected Zig version.' >&2; exit 1; }
[ "$(sha256sum "$native_root/stb_image.h" | awk '{print toupper($1)}')" = "$(pin stb_image_sha256)" ] || { echo 'Private stb_image.h hash mismatch.' >&2; exit 1; }
work=$root/build/image-decode-native
mkdir -p "$work" "$native_root/linux"
export ZIG_GLOBAL_CACHE_DIR=$root/build/zig-cache
"$zig" cc -target x86_64-linux-gnu -c "$native_root/image_decode.c" -std=c11 -O2 -DNDEBUG -o "$work/image_decode.o"
"$zig" ar rcs "$work/libimage_decode.a" "$work/image_decode.o"
cp "$work/libimage_decode.a" "$native_root/linux/libimage_decode.a"
echo 'Built isolated image decoder for Linux.'
