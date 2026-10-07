#!/bin/sh
# Build from the immutable source revisions in third_party/r3d-importer/sources.json.
set -eu
usage() { printf '%s\n' 'Usage: tools/build_r3d_importer.sh --r3d-source <checkout> --assimp-source <checkout> --raylib-headers <directory> [--zig <executable>] [--target Linux]'; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
r3d_source= assimp_source= raylib_headers= zig=zig target=Linux
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --r3d-source|-R3DSource|--assimp-source|-AssimpSource|--raylib-headers|-RaylibHeaders|--zig|-Zig|--target|-Target)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --r3d-source|-R3DSource) r3d_source=$2 ;;
                --assimp-source|-AssimpSource) assimp_source=$2 ;;
                --raylib-headers|-RaylibHeaders) raylib_headers=$2 ;;
                --zig|-Zig) zig=$2 ;;
                --target|-Target) target=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ -n "$r3d_source" ] && [ -n "$assimp_source" ] && [ -n "$raylib_headers" ] || { usage >&2; exit 1; }
case "$target" in Linux|linux) target=Linux ;; Windows|windows|All|all) fail 'Windows builds require a Windows host with the MSVC headers and Windows SDK; use build_r3d_importer.bat.' ;; *) fail "Unknown target: $target" ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
native_root=$root/third_party/r3d-importer
pins=$native_root/sources.json
pin() { awk -F '"' -v key="$1" 'index($0, "\"" key "\"") && $0 ~ /:/ { print $4; exit }' "$pins"; }
for command in git tar sha256sum awk sed mktemp "$zig"; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
zig_version=$("$zig" version)
[ "$zig_version" = "$(pin zig)" ] || fail "Expected Zig $(pin zig); found '$zig_version'."
r3d_source=$(CDPATH= cd -- "$r3d_source" && pwd -P)
assimp_source=$(CDPATH= cd -- "$assimp_source" && pwd -P)
raylib_headers=$(CDPATH= cd -- "$raylib_headers" && pwd -P)
for header in raylib.h raymath.h; do
    expected=$(pin "$header" | tr 'A-F' 'a-f')
    [ -n "$expected" ] && [ "$(sha256sum "$raylib_headers/$header" | awk '{print $1}')" = "$expected" ] || fail "Header does not match the pinned raylib revision: $raylib_headers/$header"
done
mkdir -p "$root/build"
work=$(mktemp -d "$root/build/r3d-importer-XXXXXXXX")
mkdir "$work/r3d" "$work/assimp"
# git archive never changes the caller's checkout, including its uncommitted edits.
git -C "$r3d_source" archive --format=tar --output="$work/r3d.tar" "$(pin r3d)" include src external/uthash
tar -xf "$work/r3d.tar" -C "$work/r3d"
git -C "$assimp_source" archive --format=tar --output="$work/assimp.tar" "$(pin assimp)" include
tar -xf "$work/assimp.tar" -C "$work/assimp"
git -C "$work/r3d" init --quiet
git -C "$work/r3d" apply --check "$native_root/fbx-pivots.patch"
git -C "$work/r3d" apply "$native_root/fbx-pivots.patch"
git -C "$work/r3d" apply --reverse --check "$native_root/fbx-pivots.patch"
mkdir -p "$work/headers/assimp"
cp "$raylib_headers/raylib.h" "$raylib_headers/raymath.h" "$work/headers/"
printf '%s\n' '#define R3D_SUPPORT_ASSIMP' '#define R3D_TRACELOG(level, msg, ...) TraceLog(level, "R3D: " msg, ##__VA_ARGS__)' > "$work/headers/r3d_config.h"
sed 's/#cmakedefine ASSIMP_DOUBLE_PRECISION 1/\/\* float precision \*\//' "$work/assimp/include/assimp/config.h.in" > "$work/headers/assimp/config.h"
cp "$native_root/animation_clips.c" "$work/animation_clips.c"
printf '%s\n' '#include "r3d/src/r3d_importer.c"' '#include "animation_clips.c"' > "$work/importer.c"
export ZIG_GLOBAL_CACHE_DIR=$root/build/zig-cache
"$zig" cc -target x86_64-linux-gnu -c "$work/importer.c" -O2 -DNDEBUG -D_CRT_SECURE_NO_WARNINGS -std=c11 \
    -DR3D_LoadImporter=Rune_LoadImporter -DR3D_LoadImporterFromMemory=Rune_LoadImporterFromMemory -DR3D_UnloadImporter=Rune_UnloadImporter \
    "-I$work/headers" "-I$work/r3d/include" "-I$work/r3d/external/uthash" "-I$work/assimp/include" -o "$work/importer.o"
"$zig" ar rcs "$work/libimporter.a" "$work/importer.o"
# Publish only after every requested compilation succeeds.
mkdir -p "$native_root/linux"
cp "$work/libimporter.a" "$native_root/linux/libimporter.a"
sha256sum "$native_root/linux/libimporter.a"
