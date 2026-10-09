#!/bin/sh
# Apply only Rune's recorded corrections to the exact official binding revision.
set -eu
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
check_only=false
case "$#:$*" in
    0:) ;;
    1:--check) check_only=true ;;
    1:--help|1:-h) echo 'Usage: sh tools/prepare_r3d.sh [--check]'; exit 0 ;;
    *) fail 'Usage: sh tools/prepare_r3d.sh [--check]' ;;
esac
for tool in git awk cmp mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"; done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dependency="$root/third_party/r3d-odin"
patch="$root/third_party/r3d-compat/bindings.patch"
manifest="$root/third_party/r3d-compat/files.blobs"
revision=$(awk -F '"' '/"r3d_odin"[[:space:]]*:/ {print $4; exit}' "$root/third_party/r3d-importer/sources.json")
[ -n "$revision" ] && [ -f "$patch" ] || fail 'Missing R3D revision or owned binding patch.'
[ -f "$dependency/r3d/r3d_core.odin" ] || fail 'Initialize R3D with git submodule update --init --recursive.'
temporary=$(mktemp -d) || fail 'Could not create preparation scratch directory.'
trap 'rm -f -- "$temporary/diff" "$temporary/order" "$temporary/expected-paths" "$temporary/actual-paths" "$temporary/hashes" "$temporary/expected-hashes" "$temporary/pristine-hashes"; rmdir -- "$temporary"' EXIT HUP INT TERM

if [ -e "$dependency/.git" ]; then
    actual_revision=$(git -C "$dependency" rev-parse HEAD)
    [ "$actual_revision" = "$revision" ] || fail "Expected official r3d-odin $revision; found $actual_revision."
    [ -z "$(git -C "$dependency" ls-files --others --exclude-standard)" ] || fail 'R3D contains unrelated untracked files.'
    : > "$temporary/order"
    git -C "$dependency" -c core.autocrlf=true -c core.safecrlf=false -c diff.suppressBlankEmpty=false diff --binary --full-index --no-ext-diff --no-textconv --no-color --no-renames --no-relative --src-prefix=a/ --dst-prefix=b/ --unified=3 --inter-hunk-context=0 --diff-algorithm=myers --indent-heuristic -O"$temporary/order" HEAD > "$temporary/diff"
    if [ -s "$temporary/diff" ]; then
        cmp -s "$patch" "$temporary/diff" || fail "R3D tracked changes differ from Rune's owned binding patch. Preserve your changes before preparing it."
        git -C "$dependency" -c core.autocrlf=true -c core.safecrlf=false apply --reverse --check "$patch" || fail 'The owned R3D binding patch is not fully applied.'
    else
        # Match diff normalization even when Linux Git reads a Windows checkout.
        git -C "$dependency" -c core.autocrlf=true -c core.safecrlf=false apply --check "$patch" || fail 'The owned R3D patch does not apply to the pinned bindings.'
        if ! $check_only; then
            git -C "$dependency" -c core.autocrlf=true -c core.safecrlf=false apply "$patch"
            printf '%s\n' "Applied Rune's pinned R3D binding corrections."
        fi
    fi
    exit 0
fi

# An isolated release export has no Git metadata. Check every archived file
# against the owned blob manifest, with the patch's old hashes for pristine input.
[ -f "$manifest" ] || fail 'Missing R3D archive blob manifest.'
[ "$(awk 'NR == 1 {print; exit}' "$manifest")" = "# r3d-odin $revision" ] || fail 'R3D archive blob manifest does not match the pinned revision.'
GIT_CEILING_DIRECTORIES="$root/third_party"
export GIT_CEILING_DIRECTORIES
awk 'NR > 1 {print $2}' "$manifest" > "$temporary/expected-paths"
(cd "$dependency" && find . -type f | sed 's|^./||' | LC_ALL=C sort) > "$temporary/actual-paths"
cmp -s "$temporary/expected-paths" "$temporary/actual-paths" || fail 'R3D archive contains missing or unexpected files.'
git -C "$dependency" hash-object --no-filters --stdin-paths < "$temporary/expected-paths" > "$temporary/hashes"
awk 'NR > 1 {print $1}' "$manifest" > "$temporary/expected-hashes"
if cmp -s "$temporary/expected-hashes" "$temporary/hashes"; then
    git -C "$dependency" -c core.autocrlf=false apply --reverse --check "$patch" || fail 'The R3D archive does not contain the complete owned patch.'
    exit 0
fi
awk 'FNR == NR {if ($1 == "diff") path=substr($4,3); if ($1 == "index") {split($2,hashes,/\.\./); old[path]=hashes[1]} next} FNR > 1 {print ($2 in old) ? old[$2] : $1}' "$patch" "$manifest" > "$temporary/pristine-hashes"
cmp -s "$temporary/pristine-hashes" "$temporary/hashes" || fail 'R3D archive differs from the pinned official files and owned patch.'
git -C "$dependency" -c core.autocrlf=false apply --check "$patch" || fail 'The owned R3D patch does not apply to the archive.'
if ! $check_only; then
    git -C "$dependency" -c core.autocrlf=false apply "$patch"
    git -C "$dependency" hash-object --no-filters --stdin-paths < "$temporary/expected-paths" > "$temporary/hashes"
    cmp -s "$temporary/expected-hashes" "$temporary/hashes" || fail 'Prepared R3D archive differs from the owned blob manifest.'
    printf '%s\n' "Applied Rune's pinned R3D binding corrections to the export."
fi
