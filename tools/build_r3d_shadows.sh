#!/bin/sh
# Export and build the pinned native light, shader, and draw modules; never edit a checkout.
set -eu
usage() { printf '%s\n' 'Usage: tools/build_r3d_shadows.sh --r3d-source <checkout> --raylib-headers <directory> [--zig <executable>] [--python <Python 3 executable>] [--target Linux]'; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
r3d_source= raylib_headers= zig=zig python=python3 target=Linux
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --r3d-source|--raylib-headers|--zig|--python|--target)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --r3d-source) r3d_source=$2 ;;
                --raylib-headers) raylib_headers=$2 ;;
                --zig) zig=$2 ;;
                --python) python=$2 ;;
                --target) target=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ -n "$r3d_source" ] && [ -n "$raylib_headers" ] || { usage >&2; exit 1; }
case "$target" in Linux|linux) ;; Windows|windows|All|all) fail 'Windows builds require MSVC headers and the Windows SDK; use build_r3d_shadows.bat.' ;; *) fail "Unknown target: $target" ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
native_root=$root/third_party/r3d-shadows
pins=$root/third_party/r3d-importer/sources.json
pin() { awk -F '"' -v key="$1" 'index($0, "\"" key "\"") && $0 ~ /:/ {print $4; exit}' "$pins"; }
for command in git tar sha256sum awk mktemp "$zig" "$python"; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
zig_version=$("$zig" version)
[ "$zig_version" = "$(pin zig)" ] || fail "Expected Zig $(pin zig); found '$zig_version'."
case "$("$python" --version)" in 'Python 3.'*) ;; *) fail 'Python 3 is required to embed the pinned shader sources.' ;; esac
r3d_source=$(CDPATH= cd -- "$r3d_source" && pwd -P)
raylib_headers=$(CDPATH= cd -- "$raylib_headers" && pwd -P)
for header in raylib.h raymath.h rlgl.h; do
    expected=$(pin "$header" | tr 'A-F' 'a-f')
    [ -n "$expected" ] && [ "$(sha256sum "$raylib_headers/$header" | awk '{print $1}')" = "$expected" ] || fail "Header does not match the pinned raylib revision: $raylib_headers/$header"
done
mkdir -p "$root/build"
work=$(mktemp -d "$root/build/r3d-shadows-XXXXXXXX")
mkdir "$work/r3d" "$work/headers"
git -C "$r3d_source" archive --format=tar --output="$work/r3d.tar" "$(pin r3d)" include src external/glad shaders scripts
tar -xf "$work/r3d.tar" -C "$work/r3d"
# The export must own its Git root so apply cannot find Rune's parent checkout.
git -C "$work/r3d" init --quiet
git -C "$work/r3d" apply --check "$native_root/stable-projection.patch"
git -C "$work/r3d" apply "$native_root/stable-projection.patch"
git -C "$work/r3d" apply --reverse --check "$native_root/stable-projection.patch"
git -C "$work/r3d" apply --check "$native_root/receiver-plane.patch"
git -C "$work/r3d" apply "$native_root/receiver-plane.patch"
git -C "$work/r3d" apply --reverse --check "$native_root/receiver-plane.patch"
git -C "$work/r3d" apply --check "$native_root/ssao-reconstruction.patch"
git -C "$work/r3d" apply "$native_root/ssao-reconstruction.patch"
git -C "$work/r3d" apply --reverse --check "$native_root/ssao-reconstruction.patch"
git -C "$work/r3d" apply --check "$native_root/pre-transparency.patch"
git -C "$work/r3d" apply "$native_root/pre-transparency.patch"
git -C "$work/r3d" apply --reverse --check "$native_root/pre-transparency.patch"
cp "$raylib_headers/raylib.h" "$raylib_headers/raymath.h" "$raylib_headers/rlgl.h" "$work/headers/"
cp "$native_root/r3d_config.h" "$work/headers/r3d_config.h"
"$python" "$root/tools/generate_r3d_shader_headers.py" --source "$work/r3d" --output "$work/generated"
export ZIG_GLOBAL_CACHE_DIR=$root/build/zig-cache
"$zig" cc -target x86_64-linux-gnu -c "$work/r3d/src/modules/r3d_light.c" -O2 -g0 -fPIC -DNDEBUG -D_CRT_SECURE_NO_WARNINGS -std=c11 \
    "-I$work/headers" "-I$work/r3d/include" "-I$work/r3d/external/glad" -o "$work/shadows.o"
"$zig" cc -target x86_64-linux-gnu -c "$work/r3d/src/modules/r3d_shader.c" -O2 -g0 -fPIC -DNDEBUG -D_CRT_SECURE_NO_WARNINGS -std=c11 \
    "-I$work/headers" "-I$work/r3d/include" "-I$work/r3d/external/glad" "-I$work/generated" -o "$work/receiver_shader.o"
"$zig" cc -target x86_64-linux-gnu -c "$work/r3d/src/r3d_draw.c" -O2 -g0 -fPIC -DNDEBUG -D_CRT_SECURE_NO_WARNINGS -std=c11 \
    "-I$work/headers" "-I$work/r3d/include" "-I$work/r3d/external/glad" "-I$work/generated" -o "$work/pre_transparency.o"
mkdir -p "$native_root/linux"
cp "$work/shadows.o" "$native_root/linux/shadows.o"
cp "$work/receiver_shader.o" "$native_root/linux/receiver_shader.o"
cp "$work/pre_transparency.o" "$native_root/linux/pre_transparency.o"
sha256sum "$native_root/linux/shadows.o" "$native_root/linux/receiver_shader.o" "$native_root/linux/pre_transparency.o"
