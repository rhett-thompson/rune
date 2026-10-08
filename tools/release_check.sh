#!/bin/sh
# Run the release candidate from an isolated export, including a new game.
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
working_tree=false
runtime=false
for argument in "$@"; do
    case "$argument" in
        --working-tree|-WorkingTree) working_tree=true ;;
        --runtime|-Runtime) runtime=true ;;
        --help|-h) printf '%s\n' 'Usage: tools/release_check.sh [--working-tree] [--runtime]'; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 1 ;;
    esac
done
fail() { printf 'Release check failed: %s\n' "$*" >&2; exit 1; }
if $runtime && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    fail 'Runtime checks need a display. On headless Linux, run under xvfb-run -a.'
fi
compiler_version=$(odin version) || fail 'Could not run the Odin compiler.'
source_commit=$(git -C "$repository_root" rev-parse HEAD) || fail 'Run this check from a Rune Git checkout.'
mkdir -p -- "$repository_root/build"
workspace=$(mktemp -d "$repository_root/build/release check XXXXXXXX")
export_root="$workspace/Rune Engine"
game_root="$workspace/New Game"
mkdir -p -- "$export_root"

# awk is part of the normal Linux base tools. Keep JSON handling inside this
# script instead of requiring jq, Python, or a second installed runtime.
json_read() {
    LC_ALL=C awk -v mode="$1" -v wanted="${3:-}" '
    function die(message) { print "Release JSON check failed: " message > "/dev/stderr"; exit 1 }
    function space() { while (substr(document, position, 1) ~ /[ \t\r\n]/ && position <= length(document)) position++ }
    function utf8(code) {
        if (code < 128) return sprintf("%c", code)
        if (code < 2048) return sprintf("%c%c", 192+int(code/64), 128+code%64)
        if (code < 65536) return sprintf("%c%c%c", 224+int(code/4096), 128+int(code/64)%64, 128+code%64)
        return sprintf("%c%c%c%c", 240+int(code/262144), 128+int(code/4096)%64, 128+int(code/64)%64, 128+code%64)
    }
    function hex4(    digits, i, n, digit) {
        digits=substr(document, position, 4)
        if (length(digits) != 4 || digits ~ /[^0-9a-fA-F]/) die("invalid Unicode escape")
        n=0
        for (i=1;i<=4;i++) { digit=index("0123456789abcdef",tolower(substr(digits,i,1)))-1; n=n*16+digit }
        position+=4
        return n
    }
    function string(    start, result, c, code, low) {
        start=position++
        result=""
        while (position <= length(document)) {
            c=substr(document,position++,1)
            if (c == "\"") { token=substr(document,start,position-start); return result }
            if (c ~ /[\001-\037]/ || c == sprintf("%c",0)) die("control character in string")
            if (c == "\\") {
                c=substr(document,position++,1)
                if (c == "u") {
                    code=hex4()
                    if (code >= 55296 && code <= 56319) {
                        if (substr(document,position,2) != "\\u") die("missing Unicode low surrogate")
                        position+=2; low=hex4()
                        if (low < 56320 || low > 57343) die("invalid Unicode low surrogate")
                        code=65536+(code-55296)*1024+low-56320
                    } else if (code >= 56320 && code <= 57343) die("unexpected Unicode low surrogate")
                    c=utf8(code)
                } else if (c == "b") c=sprintf("%c",8)
                else if (c == "f") c=sprintf("%c",12)
                else if (c == "n") c="\n"
                else if (c == "r") c="\r"
                else if (c == "t") c="\t"
                else if (c != "\"" && c != "\\" && c != "/") die("invalid escape")
            }
            result=result c
        }
        die("unterminated string")
    }
    function value(path, depth,    c, key, i, number) {
        if (depth > 100) die("nesting is too deep")
        space(); c=substr(document,position,1)
        if (c == "{") {
            kind[path]="object"; position++; space()
            if (substr(document,position,1) == "}") { position++; return }
            while (1) {
                space(); if (substr(document,position,1) != "\"") die("expected object key")
                key=string(); space()
                if (substr(document,position++,1) != ":") die("expected colon")
                value(path "/" key,depth+1); space(); c=substr(document,position++,1)
                if (c == "}") return
                if (c != ",") die("expected comma")
            }
        }
        if (c == "[") {
            kind[path]="array"; count[path]=0; position++; space()
            if (substr(document,position,1) == "]") { position++; return }
            i=0
            while (1) {
                value(path "/" i++,depth+1); count[path]=i; space(); c=substr(document,position++,1)
                if (c == "]") return
                if (c != ",") die("expected comma")
            }
        }
        if (c == "\"") { decoded[path]=string(); raw[path]=token; kind[path]="string"; return }
        if (substr(document,position,4) == "true") { raw[path]="true"; kind[path]="boolean"; position+=4; return }
        if (substr(document,position,5) == "false") { raw[path]="false"; kind[path]="boolean"; position+=5; return }
        if (substr(document,position,4) == "null") { raw[path]="null"; kind[path]="null"; position+=4; return }
        if (match(substr(document,position),/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
            number=substr(document,position,RLENGTH); raw[path]=number; kind[path]="number"; position+=RLENGTH; return
        }
        die("expected value at byte " position)
    }
    function quote(s,    i,j,c,result) {
        result="\""
        for (i=1;i<=length(s);i++) {
            c=substr(s,i,1)
            if (c == "\\" || c == "\"") c="\\" c
            else if (c == "\n") c="\\n"
            else if (c == "\r") c="\\r"
            else if (c == "\t") c="\\t"
            else if (c == sprintf("%c",8)) c="\\b"
            else if (c == sprintf("%c",12)) c="\\f"
            else if (c ~ /[\001-\037]/) {
                for(j=1;j<32;j++) if(c==sprintf("%c",j)) break
                c=sprintf("\\u%04x",j)
            }
            result=result c
        }
        return result "\""
    }
    function glob_match(path, pattern,    i,c,expression) {
        expression="^"
        for (i=1;i<=length(pattern);i++) {
            c=substr(pattern,i,1)
            if (c == "*") c=".*"
            else if (c == "?") c="."
            else if (index("\\.^$+(){}|",c)) c="\\" c
            expression=expression c
        }
        return tolower(path) ~ tolower(expression "$")
    }
    { document=document $0 "\n" }
    END {
        position=1; value("",0); space()
        if (position <= length(document)) die("trailing content")
        if (mode == "string") {
            if (kind[wanted] != "string") die("missing string field " wanted)
            printf "%s",decoded[wanted]
        } else if (mode == "reply") {
            if (raw["/ok"] != "true") die("console command failed")
            if (wanted == "status" && (kind["/data/recent_errors"] != "array" || count["/data/recent_errors"] > 0)) die("runtime reported errors")
            if (wanted == "capture") {
                if (kind["/data/path"] != "string") die("capture has no saved path")
                printf "%s",decoded["/data/path"]
            }
        } else if (mode == "report") {
            if (kind["/groups"] != "array") die("credits have no groups array")
            pending=""; pending_count=0
            for (i=0;i<count["/groups"];i++) {
                base="/groups/" i
                if (kind[base "/name"] != "string" || kind[base "/paths"] != "array") die("malformed credit group")
                if (decoded[base "/status"] != "documented") {
                    pending=pending (pending_count++ ? ", " : "") raw[base "/name"]
                }
            }
            uncovered=""; uncovered_count=0; RS="\0"
            while ((getline path < ENVIRON["RUNE_RELEASE_MEDIA"]) > 0) {
                path=substr(path,length(ENVIRON["RUNE_RELEASE_EXPORT"])+2); covered=0
                for (i=0;i<count["/groups"];i++) {
                    base="/groups/" i "/paths"
                    for (j=0;j<count[base];j++) if (glob_match(path,decoded[base "/" j])) covered=1
                }
                if (!covered) uncovered=uncovered (uncovered_count++ ? ", " : "") quote(path)
            }
            print "{"
            print "  \"source_commit\": " quote(ENVIRON["RUNE_RELEASE_COMMIT"]) ","
            print "  \"source_mode\": " quote(ENVIRON["RUNE_RELEASE_MODE"]) ","
            print "  \"dependency_commit\": " quote(ENVIRON["RUNE_RELEASE_DEPENDENCY"]) ","
            print "  \"compiler\": " quote(ENVIRON["RUNE_RELEASE_COMPILER"]) ","
            print "  \"platform\": " quote(ENVIRON["RUNE_RELEASE_PLATFORM"]) ","
            print "  \"architecture\": " quote(ENVIRON["RUNE_RELEASE_ARCHITECTURE"]) ","
            print "  \"shell\": " quote(ENVIRON["RUNE_RELEASE_SHELL"]) ","
            print "  \"display\": {\"x11\": " quote(ENVIRON["DISPLAY"]) ", \"wayland\": " quote(ENVIRON["WAYLAND_DISPLAY"]) "},"
            print "  \"engineering_passed\": true,"
            print "  \"runtime_checked\": " ENVIRON["RUNE_RELEASE_RUNTIME"] ","
            print "  \"engine_license_present\": " ENVIRON["RUNE_RELEASE_LICENSE"] ","
            print "  \"asset_credit_groups_pending\": [" pending "],"
            print "  \"assets_without_credit_entry\": [" uncovered "],"
            print "  \"export_directory\": " quote(ENVIRON["RUNE_RELEASE_EXPORT"]) ","
            print "  \"project_directory\": " quote(ENVIRON["RUNE_RELEASE_GAME"])
            print "}"
            if (ENVIRON["RUNE_RELEASE_LICENSE"] != "true" || pending_count || uncovered_count)
                print "Warning: Publication prerequisites remain: engine licensing and/or asset credits. See docs/release.md." > "/dev/stderr"
        } else die("unknown query")
    }' "$2"
}

if $working_tree; then
    printf '%s\n' 'Warning: Testing the working copy, including uncommitted files. This is not proof of the published commit.' >&2
    git -C "$repository_root" ls-files --cached --others --exclude-standard -z > "$workspace/files.list"
    # Git emits NUL-separated names, preserving spaces and embedded newlines.
    # Filter deleted files and directory gitlinks before archiving the snapshot.
    export RUNE_RELEASE_SOURCE="$repository_root"
    LC_ALL=C awk '
        BEGIN { RS="\0"; ORS="\0" }
        function shell_quote(s, result, i, c) {
            result="\047"
            for(i=1;i<=length(s);i++) { c=substr(s,i,1); result=result (c=="\047" ? "\047\\\047\047" : c) }
            return result "\047"
        }
        !seen[$0]++ && system("test -f " shell_quote(ENVIRON["RUNE_RELEASE_SOURCE"] "/" $0))==0 { print }
    ' "$workspace/files.list" > "$workspace/present-files.list"
    tar -C "$repository_root" --dereference --null --verbatim-files-from -T "$workspace/present-files.list" -cf "$workspace/engine.tar"
    tar -xf "$workspace/engine.tar" -C "$export_root"
else
    git -C "$repository_root" archive --format=tar --output="$workspace/engine.tar" "$source_commit"
    tar -xf "$workspace/engine.tar" -C "$export_root"
fi

# Archive the exact submodule revision from local objects, never a fetched head.
submodule=third_party/r3d-odin
dependency_root="$repository_root/$submodule"
[ -f "$dependency_root/r3d/r3d_core.odin" ] || fail 'Initialize dependencies with git submodule update --init --recursive.'
if $working_tree; then
    sh "$repository_root/tools/prepare_r3d.sh" --check
    dependency_commit=$(git -C "$dependency_root" rev-parse HEAD)
else
    dependency_commit=$(git -C "$repository_root" rev-parse "$source_commit:$submodule")
fi
git -C "$dependency_root" -c core.autocrlf=false archive --format=tar --output="$workspace/r3d.tar" "$dependency_commit"
mkdir -p -- "$export_root/$submodule"
tar -xf "$workspace/r3d.tar" -C "$export_root/$submodule"
for relative_path in toolchain.json tools/new_project.sh tools/validate.sh tools/console.sh tools/prepare_r3d.sh third_party/r3d-compat/bindings.patch third_party/r3d-compat/files.blobs third_party/r3d-importer/sources.json templates/blank_project/build.sh docs/asset_credits.json; do
    [ -f "$export_root/$relative_path" ] || fail "The exported commit is missing $relative_path. Commit the release tooling, or use --working-tree to test it first."
done
sh "$export_root/tools/prepare_r3d.sh"
odin_release=$(json_read string "$export_root/toolchain.json" /odin_release)
tested_version=$(json_read string "$export_root/toolchain.json" /tested_odin_version)
case "$compiler_version" in *"$odin_release"*) ;; *) fail "Expected Odin $odin_release; found $compiler_version" ;; esac
case "$compiler_version" in *"$tested_version"*) ;; *) printf 'Warning: Compiler differs from the recorded tested revision: %s\n' "$tested_version" >&2 ;; esac
if $runtime; then
    sh "$export_root/tools/validate.sh" --all-examples --runtime
else
    sh "$export_root/tools/validate.sh" --all-examples
fi
sh "$export_root/tools/new_project.sh" --path "$game_root" --name 'Release Check Game'
sh "$game_root/build.sh" --rune-root "$export_root"
sh "$game_root/build.sh" --rune-root "$export_root" --release
"$export_root/build/project_validator" "$game_root/project.json"
for relative_path in project.json scenes/main.scene.json input/default.input.json; do
    file="$game_root/$relative_path"
    schema=$(json_read string "$file" '/$schema')
    [ -f "$(dirname -- "$file")/$schema" ] || fail "Generated schema reference does not resolve: $relative_path"
done

game_pid=
stop_game() {
    if [ -n "$game_pid" ]; then
        if kill -0 "$game_pid" 2>/dev/null; then
            kill "$game_pid" 2>/dev/null || true
            attempt=0
            while [ "$attempt" -lt 10 ]; do
                kill -0 "$game_pid" 2>/dev/null || break
                sleep 0.1
                attempt=$((attempt+1))
            done
            kill -KILL "$game_pid" 2>/dev/null || true
        fi
        wait "$game_pid" 2>/dev/null || true
        game_pid=
    fi
}
trap stop_game EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
runtime_passed=false
if $runtime; then
    inbox="$game_root/build/console"
    (cd -- "$game_root"; exec ./build/game --console-dir=build/console) > "$workspace/game.stdout.log" 2> "$workspace/game.stderr.log" &
    game_pid=$!
    attempt=0
    while [ ! -d "$inbox" ]; do
        kill -0 "$game_pid" 2>/dev/null && [ "$attempt" -lt 150 ] || fail 'New project failed to start. See game.stdout.log and game.stderr.log in the release workspace.'
        sleep 0.1
        attempt=$((attempt+1))
    done
    for command in status pause 'step 2' 'capture build/first-frame.png'; do
        sh "$export_root/tools/console.sh" --directory "$inbox" --command "$command" --json > "$workspace/console.reply.json"
        case "$command" in
            status) json_read reply "$workspace/console.reply.json" status ;;
            'capture '*) capture_path=$(json_read reply "$workspace/console.reply.json" capture); [ -f "$capture_path" ] || fail 'New project capture failed.' ;;
            *) json_read reply "$workspace/console.reply.json" ;;
        esac
    done
    runtime_passed=true
    stop_game
fi

find "$export_root/examples" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.ttf' -o -iname '*.wav' -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.obj' -o -iname '*.mtl' -o -iname '*.glb' -o -iname '*.gltf' -o -iname '*.hdr' -o -iname '*.fnt' \) -print0 > "$workspace/media.list"
LC_ALL=C sort -z "$workspace/media.list" -o "$workspace/media.list"
license_present=false
[ ! -f "$export_root/LICENSE" ] || license_present=true
source_mode=committed
$working_tree && source_mode=working-tree
export RUNE_RELEASE_COMMIT="$source_commit" RUNE_RELEASE_MODE="$source_mode" RUNE_RELEASE_DEPENDENCY="$dependency_commit"
export RUNE_RELEASE_COMPILER="$compiler_version" RUNE_RELEASE_PLATFORM="$(uname -srm)" RUNE_RELEASE_ARCHITECTURE="$(uname -m)"
export RUNE_RELEASE_SHELL="/bin/sh ($(readlink -f /bin/sh))" RUNE_RELEASE_RUNTIME="$runtime_passed" RUNE_RELEASE_LICENSE="$license_present"
export RUNE_RELEASE_EXPORT="$export_root" RUNE_RELEASE_GAME="$game_root" RUNE_RELEASE_MEDIA="$workspace/media.list"
json_read report "$export_root/docs/asset_credits.json" > "$workspace/report.json"
printf 'Engineering checks passed. Report: %s\n' "$workspace/report.json"
