#!/bin/sh
# Install Rune's checksummed Odin release without an additional scripting runtime.
set -eu
usage() { printf '%s\n' 'Usage: tools/install_odin.sh --destination <new-directory>'; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --destination|-Destination) [ "$#" -ge 2 ] || fail "Missing destination."; destination=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ -n "$destination" ] || { usage >&2; exit 1; }
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'The pinned toolchain installer currently supports Linux AMD64; use install_odin.bat for Windows AMD64.'
for command in curl tar sha256sum awk find; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
release=$(awk -F '"' '/"odin_release"[[:space:]]*:/ { print $4; exit }' "$root/toolchain.json")
asset=$(awk -F '"' '/"linux-amd64"[[:space:]]*:/ { selected=1 } selected && /"name"[[:space:]]*:/ { print $4; exit }' "$root/toolchain.json")
checksum=$(awk -F '"' '/"linux-amd64"[[:space:]]*:/ { selected=1 } selected && /"sha256"[[:space:]]*:/ { print $4; exit }' "$root/toolchain.json")
printf '%s\n' "$checksum" | LC_ALL=C awk 'length($0)==64 && $0 !~ /[^0-9a-f]/ { valid=1 } END { exit !valid }' || fail 'No checksummed Odin archive is configured for linux-amd64.'
case "$asset" in ''|*/*|*\\*|.|..) fail 'Invalid Odin archive name.' ;; esac
[ -n "$release" ] || fail 'No Odin release is configured.'
[ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "Destination already exists: $destination. Choose a new directory."
mkdir -p -- "$(dirname -- "$destination")"
parent=$(CDPATH= cd -- "$(dirname -- "$destination")" && pwd -P)
destination=$parent/$(basename -- "$destination")
mkdir -- "$destination" || fail "Could not create a new destination: $destination"
archive=$destination/$asset
curl --fail --location --output "$archive" "https://github.com/odin-lang/Odin/releases/download/$release/$asset"
[ "$(sha256sum "$archive" | awk '{print $1}')" = "$checksum" ] || fail 'Odin archive checksum mismatch; nothing was extracted.'
tar -xzf "$archive" -C "$destination"
compiler=$(find "$destination" -type f -name odin -exec sh -c '[ -d "$(dirname -- "$1")/core" ] && printf "%s\n" "$1"' sh {} \;)
[ -n "$compiler" ] && [ "$(printf '%s\n' "$compiler" | wc -l | tr -d ' ')" = 1 ] || fail 'Expected exactly one compiler with its core library in the archive.'
"$compiler" version || fail 'The downloaded compiler could not start; check the OS dependencies.'
compiler_directory=$(dirname -- "$compiler")
stb_root=$compiler_directory/vendor/stb
if [ ! -f "$stb_root/lib/stb_image.a" ]; then
    for command in bash cc ar; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
    printf '%s\n' 'Building native stb libraries with the pinned Odin vendor script...'
    bash "$stb_root/src/build_stb.sh" unix
    [ -f "$stb_root/lib/stb_image.a" ] || fail 'The native stb_image dependency build failed.'
fi
box2d_root=$compiler_directory/vendor/box2d
if [ ! -f "$box2d_root/lib/box2d_other_amd64_sse2.a" ] || [ ! -f "$box2d_root/lib/box2d_other_amd64_avx2.a" ]; then
    for command in bash curl cmake make cc; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
    printf '%s\n' 'Building native Box2D libraries with the pinned Odin vendor script...'
    bash "$box2d_root/build_box2d.sh"
    for library in box2d_other_amd64_sse2.a box2d_other_amd64_avx2.a; do
        [ -f "$box2d_root/lib/$library" ] || fail "Box2D build did not produce $library"
    done
fi
printf 'Installed Odin. Add this directory to PATH: %s\n' "$compiler_directory"
