#!/bin/sh
set -eu

command -v odin >/dev/null 2>&1 || { echo 'Odin was not found on PATH.' >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo 'Sequential Odin builds require flock (Linux util-linux).' >&2; exit 1; }

# Keep this file in place. The compiler inherits the descriptor, so the kernel
# releases the lock on exit even when the wrapper is interrupted or killed.
lock="${TMPDIR:-/tmp}/rune-odin-compile-$(id -u).lock"
exec 9>"$lock"
if ! flock -n 9; then
    echo 'Waiting for another Rune Odin command to finish...' >&2
    flock 9
fi
exec odin "$@"
