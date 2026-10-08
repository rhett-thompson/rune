#!/bin/sh
set -u

rune_root=${RUNE_ROOT:-}
run=0
release=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rune-root|-RuneRoot)
            [ "$#" -ge 2 ] || { echo "$1 needs an engine directory." >&2; exit 2; }
            rune_root=$2; shift 2 ;;
        --run|-Run) run=1; shift ;;
        --release|-Release) release=1; shift ;;
        --) shift; break ;;
        --help|-h)
            echo 'Usage: sh build.sh [--rune-root <directory>] [--release] [--run] [-- <game arguments>]'
            echo 'RUNE_ROOT can also point to your Rune checkout.'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$rune_root" ] || { echo 'Pass --rune-root <engine-directory>, or set RUNE_ROOT to your Rune checkout.' >&2; exit 1; }
engine_root=$(CDPATH= cd -- "$rune_root" && pwd) || exit 1
[ -f "$engine_root/rune/core/core.odin" ] || { echo "Rune engine was not found at $engine_root" >&2; exit 1; }
command -v odin >/dev/null 2>&1 || { echo 'Odin was not found on PATH.' >&2; exit 1; }
if [ -d "$engine_root/third_party/r3d-odin/r3d" ]; then
    sh "$engine_root/tools/prepare_r3d.sh" || exit $?
fi
game_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$game_root" || exit 1
mkdir -p build || exit 1
executable="$game_root/build/game"
if [ "$release" -eq 1 ]; then
    odin build . "-collection:rune=$engine_root/rune" -out:build/game -o:speed
else
    odin build . "-collection:rune=$engine_root/rune" -out:build/game
fi
result=$?
[ "$result" -eq 0 ] || { echo "Game build failed (exit $result)." >&2; exit "$result"; }
echo "Built $executable"
if [ "$run" -eq 1 ]; then
    "$executable" "$@"
    result=$?
    [ "$result" -eq 0 ] || echo "Game exited with code $result." >&2
    exit "$result"
fi
