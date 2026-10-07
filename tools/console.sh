#!/bin/sh
# Publish requests by rename, then read one structured reply using native awk.
set -eu
directory=
command=
command_set=0
format=text
timeout=10
while [ "$#" -gt 0 ]; do
    case "$1" in
        --directory|-Directory) [ "$#" -ge 2 ] || { echo 'Missing directory.' >&2; exit 2; }; directory=$2; shift 2 ;;
        --command|-Command) [ "$#" -ge 2 ] || { echo 'Missing command.' >&2; exit 2; }; command=$2; command_set=1; shift 2 ;;
        --json|-Json) format=json; shift ;;
        --timeout-seconds|-TimeoutSeconds) [ "$#" -ge 2 ] || { echo 'Missing timeout.' >&2; exit 2; }; timeout=$2; shift 2 ;;
        --help|-h) echo 'Usage: sh tools/console.sh --directory INBOX --command "COMMAND" [--json] [--timeout-seconds 10]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$directory" ] && [ "$command_set" -eq 1 ] || { echo 'Pass --directory INBOX and --command COMMAND.' >&2; exit 2; }
case "$timeout" in ''|*[!0-9]*) echo 'Timeout must be an integer from 1 to 300.' >&2; exit 2 ;; esac
[ "$timeout" -ge 1 ] && [ "$timeout" -le 300 ] || { echo 'Timeout must be an integer from 1 to 300.' >&2; exit 2; }
case "$command" in *"
"*|*"$(printf '\r')"*) echo 'Send one command of at most 256 UTF-8 bytes.' >&2; exit 2 ;; esac
bytes=$(printf '%s' "$command" | LC_ALL=C wc -c)
[ "$bytes" -le 256 ] || { echo 'Send one command of at most 256 UTF-8 bytes.' >&2; exit 2; }
[ -d "$directory" ] || { echo "Console directory does not exist: $directory" >&2; exit 1; }
directory=$(CDPATH= cd -- "$directory" && pwd)
staging=$(mktemp "$directory/rune-XXXXXXXXXX.tmp")
request=${staging%.tmp}.cmd
reply=${staging%.tmp}.result.json
cleanup() { rm -f -- "$staging" "$request" "$reply"; }
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf '%s' "$command" > "$staging"
publish_deadline=$(($(date +%s) + 2))
while ! mv -- "$staging" "$request"; do
    [ -f "$staging" ] && [ ! -e "$request" ] && [ "$(date +%s)" -lt "$publish_deadline" ] || exit 1
    sleep 0.025
done
attempt=0
maximum_attempts=$(awk -v timeout="$timeout" 'BEGIN { print timeout * 10 }')
while [ ! -f "$reply" ]; do
    if [ "$attempt" -ge "$maximum_attempts" ]; then
        echo 'Console timed out. A claimed command may still finish; check the result before retrying.' >&2
        exit 1
    fi
    sleep 0.1
    attempt=$((attempt + 1))
done
LC_ALL=C awk -v format="$format" '
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
function value(path,depth, start,c,end,array,key,index_,number) {
    if(depth>128) error("nesting exceeds 128 levels")
    ws(); start=at; c=substr(text,at,1)
    if(path ~ /^\/lines\/[0-9]+$/ && c!="\"") error("lines must contain strings")
    if(c=="\"") {
        string_value()
        if(path ~ /^\/lines\/[0-9]+$/) { lines[++line_count]=decoded }
    } else if(c=="{" || c=="[") {
        array=(c=="["); end=array?"]":"}"; at++; ws(); index_=0
        if(path=="/lines") { if(!array) error("lines is not an array"); has_lines=1 }
        if(substr(text,at,1)!=end) {
            while(1) {
                if(array) key=index_++
                else {
                    if(substr(text,at,1)!="\"") error("expected property")
                    string_value(); key=decoded; ws()
                    if(substr(text,at++,1)!=":") error("expected colon")
                }
                value(path "/" key,depth+1); ws()
                if(substr(text,at,1)==end) break
                if(substr(text,at++,1)!=",") error("expected comma")
                ws()
            }
        }
        at++
    } else if(substr(text,at,4)=="true") { at+=4; if(path=="/ok") { ok=1; has_ok=1 } }
    else if(substr(text,at,5)=="false") { at+=5; if(path=="/ok") { ok=0; has_ok=1 } }
    else if(substr(text,at,4)=="null") at+=4
    else {
        if(!match(substr(text,at),/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) error("invalid value")
        at+=RLENGTH
    }
    if(path=="/data") data=substr(text,start,at-start)
}
{ text=text $0 "\n" }
END {
    if(!length(text)) error("empty reply")
    at=1; ws(); if(substr(text,at,1)!="{") error("expected object")
    value("",0); ws(); if(at<=length(text)) error("trailing data")
    if(!has_ok || !has_lines) error("expected ok and lines")
    if(format=="json") printf "%s",text
    else { for(i=1;i<=line_count;i++) print lines[i]; if(length(data) && data!="null") print data }
    if(!ok) { print "Console command failed." > "/dev/stderr"; for(i=1;i<=line_count;i++) print lines[i] > "/dev/stderr"; exit 1 }
}
' "$reply"
