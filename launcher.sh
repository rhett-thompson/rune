#!/bin/sh
set -eu

# Resolve assets and build outputs from the checkout, even when invoked elsewhere.
rune_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$rune_root"

if ! command -v odin >/dev/null 2>&1; then
    printf '%s\n' 'Odin was not found on PATH. See docs/linux.md for setup.' >&2
    exit 127
fi

mkdir -p build
exec odin run examples/launcher -collection:rune=rune -out:build/launcher
