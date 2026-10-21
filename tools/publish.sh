#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
mkdir -p "$root/build"
tool_dir=$(mktemp -d "$root/build/.rune-publish-tool-XXXXXXXX")
trap 'rm -f -- "$tool_dir/rune-publish"; rmdir -- "$tool_dir" 2>/dev/null || true' 0
sh "$root/tools/odin.sh" build "$root/tools/publisher" "-collection:rune=$root/rune" "-out:$tool_dir/rune-publish"
"$tool_dir/rune-publish" --rune-root "$root" "$@"
