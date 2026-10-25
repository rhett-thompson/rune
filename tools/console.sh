#!/bin/sh
# Publish requests by rename, then read one structured reply using native awk.
set -eu
directory=
command=
command_set=0
batch_file=
batch=0
format=text
timeout=
timeout_set=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --directory|-Directory) [ "$#" -ge 2 ] || { echo 'Missing directory.' >&2; exit 2; }; directory=$2; shift 2 ;;
        --command|-Command) [ "$#" -ge 2 ] || { echo 'Missing command.' >&2; exit 2; }; command=$2; command_set=1; shift 2 ;;
        --batch-file|-BatchFile) [ "$#" -ge 2 ] || { echo 'Missing batch file.' >&2; exit 2; }; batch_file=$2; batch=1; shift 2 ;;
        --json|-Json) format=json; shift ;;
        --timeout-seconds|-TimeoutSeconds) [ "$#" -ge 2 ] || { echo 'Missing timeout.' >&2; exit 2; }; timeout=$2; timeout_set=1; shift 2 ;;
        --help|-h) echo 'Usage: sh tools/console.sh --directory INBOX (--command "COMMAND" | --batch-file FILE) [--json] [--timeout-seconds 1..300]'; echo 'Default timeout: command 10 seconds; batch 300 seconds.'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$directory" ] && [ "$((command_set + batch))" -eq 1 ] || { echo 'Pass --directory INBOX and exactly one of --command COMMAND or --batch-file FILE.' >&2; exit 2; }
if [ "$timeout_set" -eq 0 ]; then
    if [ "$batch" -eq 1 ]; then timeout=300; else timeout=10; fi
fi
case "$timeout" in ''|*[!0-9]*) echo 'Timeout must be an integer from 1 to 300.' >&2; exit 2 ;; esac
[ "$timeout" -ge 1 ] && [ "$timeout" -le 300 ] || { echo 'Timeout must be an integer from 1 to 300.' >&2; exit 2; }
if [ "$batch" -eq 1 ]; then
    [ -f "$batch_file" ] || { echo "Batch file does not exist: $batch_file" >&2; exit 1; }
    [ "$(LC_ALL=C wc -c < "$batch_file")" -le 1048576 ] || { echo 'Batch exceeds 1048576 bytes.' >&2; exit 2; }
else
    case "$command" in *"
"*|*"$(printf '\r')"*) echo 'Send one command of at most 256 UTF-8 bytes.' >&2; exit 2 ;; esac
    bytes=$(printf '%s' "$command" | LC_ALL=C wc -c)
    [ "$bytes" -le 256 ] || { echo 'Send one command of at most 256 UTF-8 bytes.' >&2; exit 2; }
fi
[ -d "$directory" ] || { echo "Console directory does not exist: $directory" >&2; exit 1; }
directory=$(CDPATH= cd -- "$directory" && pwd)
staging=$(mktemp "$directory/rune-XXXXXXXXXX.tmp")
request=${staging%.tmp}.cmd
if [ "$batch" -eq 1 ]; then request=${staging%.tmp}.batch; fi
reply=${staging%.tmp}.result.json
reply_consumed=0
cleanup() {
    rm -f -- "$staging" "$request"
    # Preserve replies racing a timeout or interruption for later inspection.
    if [ "$reply_consumed" -eq 1 ]; then rm -f -- "$reply"; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [ "$batch" -eq 1 ]; then
    cat < "$batch_file" > "$staging"
    [ "$(LC_ALL=C wc -c < "$staging")" -le 1048576 ] || { echo 'Batch exceeds 1048576 bytes.' >&2; exit 2; }
else printf '%s' "$command" > "$staging"; fi
publish_deadline=$(($(date +%s) + 2))
while ! mv -- "$staging" "$request"; do
    [ -f "$staging" ] && [ ! -e "$request" ] && [ "$(date +%s)" -lt "$publish_deadline" ] || exit 1
    sleep 0.025
done
attempt=0
maximum_attempts=$(awk -v timeout="$timeout" 'BEGIN { print timeout * 10 }')
while [ ! -f "$reply" ]; do
    if [ "$attempt" -ge "$maximum_attempts" ]; then
        echo "Console timed out. A claimed request may still finish; timeout does not cancel it. Check the result before retrying: $reply" >&2
        exit 1
    fi
    sleep 0.1
    attempt=$((attempt + 1))
done
if LC_ALL=C awk -v format="$format" -v batch="$batch" '
function error(message) { print "Invalid console reply: " message > "/dev/stderr"; exit 2 }
function ws() { while (substr(text,at,1) ~ /[ \t\r\n]/ && at<=length(text)) at++ }
function hex(s, result,i,c) {
    result=0
    for(i=1;i<=length(s);i++) { c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; if(c<0) error("invalid unicode escape"); result=result*16+c }
    return result
}
function utf8(n) {
    if(n<128) return sprintf("%c",n)
    if(n<2048) return sprintf("%c%c",192+int(n/64),128+n%64)
    if(n<65536) return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
    return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
}
function string_value(result,c,n,lo) {
    result=""; at++
    while(at<=length(text)) {
        c=substr(text,at++,1)
        if(c=="\"") { decoded=result; return }
        if(c ~ /[\001-\037]/) error("control byte in string")
        if(c=="\\") {
            c=substr(text,at++,1)
            if(c=="\"" || c=="\\" || c=="/") result=result c
            else if(c=="n") result=result "\n"
            else if(c=="r") result=result "\r"
            else if(c=="t") result=result "\t"
            else if(c=="b") result=result "\b"
            else if(c=="f") result=result "\f"
            else if(c=="u") {
                if(length(substr(text,at,4))!=4) error("short unicode escape")
                n=hex(substr(text,at,4)); at+=4
                if(n>=55296 && n<=56319) {
                    if(substr(text,at,2)!="\\u") error("missing low surrogate")
                    at+=2; lo=hex(substr(text,at,4)); at+=4
                    if(lo<56320 || lo>57343) error("invalid low surrogate")
                    n=65536+(n-55296)*1024+lo-56320
                } else if(n>=56320 && n<=57343) error("unexpected low surrogate")
                result=result utf8(n)
            } else error("unknown escape")
        } else result=result c
    }
    error("unterminated string")
}
function pointer_key(key) { gsub(/~/,"~0",key); gsub(/\//,"~1",key); return key }
function protocol_field(path) {
    return path=="" || path ~ /^\/(ok|complete|error|requested|completed|results|data|lines)$/ || path ~ /^\/lines\/[0-9]+$/ || path ~ /^\/results\/[0-9]+$/ || path ~ /^\/results\/[0-9]+\/(ok|command|lines|data)$/ || path ~ /^\/results\/[0-9]+\/lines\/[0-9]+$/
}
function value(path,depth, start,c,end,array,key,index_,kind,keep) {
    if(depth>128) error("nesting exceeds 128 levels")
    ws(); start=at; c=substr(text,at,1); keep=protocol_field(path)
    if(c=="\"") {
        string_value(); kind="string"; if(keep) values[path]=decoded
    } else if(c=="{" || c=="[") {
        array=(c=="["); end=array?"]":"}"; at++; ws(); index_=0
        kind=array?"array":"object"
        if(substr(text,at,1)!=end) {
            while(1) {
                if(array) key=index_++
                else {
                    if(substr(text,at,1)!="\"") error("expected property")
                    string_value(); key=decoded; ws()
                    if(substr(text,at++,1)!=":") error("expected colon")
                }
                value(path "/" pointer_key(key),depth+1); ws()
                if(substr(text,at,1)==end) break
                if(substr(text,at++,1)!=",") error("expected comma")
                ws()
            }
        }
        at++; if(array && keep) sizes[path]=index_
    } else if(substr(text,at,4)=="true") { at+=4; kind="boolean"; if(keep) values[path]=1 }
    else if(substr(text,at,5)=="false") { at+=5; kind="boolean"; if(keep) values[path]=0 }
    else if(substr(text,at,4)=="null") { at+=4; kind="null" }
    else {
        if(!match(substr(text,at),/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) error("invalid value")
        kind="number"; if(keep) values[path]=substr(text,at,RLENGTH)+0; at+=RLENGTH
    }
    if(keep) types[path]=kind
    if(path=="/data" || path ~ /^\/results\/[0-9]+\/data$/) payloads[path]=substr(text,start,at-start)
}
function validate_entry(path, i) {
    if(types[path]!="object" || types[path "/ok"]!="boolean" || types[path "/lines"]!="array") error("expected entry object with ok and lines")
    for(i=0;i<sizes[path "/lines"];i++) if(types[path "/lines/" i]!="string") error("lines must contain strings")
    if(batch && (types[path "/command"]!="string" || !(path "/data" in types))) error("expected batch entry command and data")
}
function count(path) { return types[path]=="number" && values[path]>=0 && values[path]<=4096 && int(values[path])==values[path] }
function print_entry(path, i,data) {
    for(i=0;i<sizes[path "/lines"];i++) print values[path "/lines/" i]
    data=payloads[path "/data"]; if(length(data) && data!="null") print data
}
{ text=text $0 "\n" }
END {
    if(!length(text)) error("empty reply")
    at=1; ws(); if(substr(text,at,1)!="{") error("expected object")
    value("",0); ws(); if(at<=length(text)) error("trailing data")
    if(batch) {
        if(types["/ok"]!="boolean" || types["/complete"]!="boolean" || types["/error"]!="string" || types["/results"]!="array" || !count("/requested") || !count("/completed")) error("expected ok, complete, requested, completed, error, and results")
        requested=values["/requested"]; completed=values["/completed"]
        if(completed!=sizes["/results"] || completed>requested || (values["/complete"] && completed!=requested)) error("inconsistent batch counts")
        all_ok=1
        for(i=0;i<completed;i++) { validate_entry("/results/" i); if(!values["/results/" i "/ok"]) all_ok=0 }
        if(values["/ok"]!=(values["/complete"] && all_ok && values["/error"]=="")) error("inconsistent batch success state")
    } else validate_entry("")
    if(format=="json") printf "%s",text
    else if(batch) {
        for(i=0;i<completed;i++) { print "[" (i+1) "/" requested "] " values["/results/" i "/command"]; print_entry("/results/" i) }
    } else print_entry("")
    if(!values["/ok"]) {
        if(batch) print "Console batch failed or incomplete (" completed "/" requested " completed). " values["/error"] > "/dev/stderr"
        else { print "Console command failed." > "/dev/stderr"; for(i=0;i<sizes["/lines"];i++) print values["/lines/" i] > "/dev/stderr" }
        exit 1
    }
}
' "$reply"; then result_code=0; else result_code=$?; fi
reply_consumed=1
exit "$result_code"
