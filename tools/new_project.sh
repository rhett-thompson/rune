#!/bin/sh
# Create a game with the native shell; no extra scripting runtime is required.
set -eu
engine_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=
name=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --path|-Path) [ "$#" -ge 2 ] || { echo 'Missing project path.' >&2; exit 2; }; destination=$2; shift 2 ;;
        --name|-Name) [ "$#" -ge 2 ] || { echo 'Missing project name.' >&2; exit 2; }; name=$2; shift 2 ;;
        --help|-h) echo 'Usage: sh tools/new_project.sh --path DIRECTORY [--name NAME]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$destination" ] || { echo 'Pass --path DIRECTORY.' >&2; exit 2; }
case "$destination" in /*) ;; *) destination=$PWD/$destination ;; esac
[ ! -e "$destination" ] && [ ! -L "$destination" ] || { echo "Destination already exists: $destination" >&2; exit 1; }
[ -n "$name" ] || name=$(basename -- "$destination")
printf '%s' "$name" | LC_ALL=C awk 'BEGIN { valid=0 } /[^[:space:]]/ { valid=1 } END { exit !valid }' || { echo 'The project needs a non-empty name.' >&2; exit 2; }
mkdir -p -- "$(dirname -- "$destination")"
mkdir -- "$destination"
template=$engine_root/templates/blank_project
for source in "$template"/* "$template"/.[!.]* "$template"/..?*; do
    [ -e "$source" ] || [ -L "$source" ] || continue
    [ "$(basename -- "$source")" != build ] || continue
    cp -R -- "$source" "$destination/"
done
cp -R -- "$engine_root/schemas" "$destination/schemas"
export RUNE_PROJECT_NAME=$name
rewrite() {
    file=$destination/$1
    awk -v schema="$2" -v project="$3" '
        function quote(s, result, i, c, j) {
            result="\""
            for (i=1; i<=length(s); i++) {
                c=substr(s,i,1)
                if (c=="\\" || c=="\"") result=result "\\" c
                else if (c=="\n") result=result "\\n"
                else if (c=="\r") result=result "\\r"
                else if (c=="\t") result=result "\\t"
                else if (c=="\b") result=result "\\b"
                else if (c=="\f") result=result "\\f"
                else if (c ~ /[\001-\037]/) {
                    for (j=1;j<32;j++) if(c==sprintf("%c",j)) break
                    result=result sprintf("\\u%04x",j)
                } else result=result c
            }
            return result "\""
        }
        /^[ \t]*"\$schema"[ \t]*:/ { match($0,/^[ \t]*/); print substr($0,1,RLENGTH) "\"$schema\": " quote(schema) ","; next }
        project && /^[ \t]*"(name|title)"[ \t]*:/ {
            match($0,/^[ \t]*/); indent=substr($0,1,RLENGTH)
            key=($0 ~ /"name"/) ? "name" : "title"
            print indent "\"" key "\": " quote(ENVIRON["RUNE_PROJECT_NAME"]) ","; next
        }
        { print }
    ' "$file" > "$file.tmp"
    mv -- "$file.tmp" "$file"
}
rewrite project.json schemas/project.schema.json 1
rewrite scenes/main.scene.json ../schemas/scene.schema.json 0
rewrite input/default.input.json ../schemas/input.schema.json 0
printf 'Created %s\n' "$destination"
echo 'Run build.bat on Windows or sh build.sh on Linux with --rune-root pointing to the engine checkout.'
