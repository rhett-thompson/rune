#!/bin/sh
set -eu

# Resolve assets and build outputs from the checkout, even when invoked elsewhere.
rune_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$rune_root"
if [ "${RUNE_EXAMPLES_PREBUILT:-0}" = 1 ] || ! command -v odin >/dev/null 2>&1; then
    [ -x build/launcher ] || { printf '%s\n' 'Missing build/launcher. Build the examples first, or install Odin (docs/linux.md).' >&2; exit 127; }
    export RUNE_EXAMPLES_PREBUILT=1
    exec ./build/launcher
fi
if [ -d third_party/r3d-odin/r3d ]; then
    sh "$rune_root/tools/prepare_r3d.sh"
fi

mkdir -p build
exec odin run examples/launcher -o:none -collection:rune=rune -out:build/launcher
