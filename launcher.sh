#!/bin/sh
set -eu

# Resolve assets and build outputs from the checkout, even when invoked elsewhere.
rune_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$rune_root"
if [ -d third_party/r3d-odin/r3d ]; then
    sh "$rune_root/tools/prepare_r3d.sh"
fi

if ! command -v odin >/dev/null 2>&1; then
    printf '%s\n' 'Odin was not found on PATH. See docs/linux.md for setup.' >&2
    exit 127
fi

mkdir -p build
exec odin run examples/launcher -o:none -collection:rune=rune -out:build/launcher
