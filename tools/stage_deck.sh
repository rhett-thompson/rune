#!/bin/sh
# Build a portable resource tree with static Rune libraries and a glibc gate.
set -eu
usage() {
    printf '%s\n' 'Usage: sh tools/stage_deck.sh [--destination build/deck-stage] [--odin /path/to/odin] [--extra-linker-flags FLAGS] [--jobs 1] [--audit-only]'
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
destination=$root/build/deck-stage
compiler=${ODIN:-odin}
linker_flags=
audit_only=0
jobs=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --destination|--odin|--extra-linker-flags|--jobs)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --destination) destination=$2 ;;
                --odin) compiler=$2 ;;
                --extra-linker-flags) linker_flags=$2 ;;
                --jobs) jobs=$2 ;;
            esac
            shift 2 ;;
        --audit-only) audit_only=1; shift ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
case "$jobs" in ''|*[!0-9]*) fail '--jobs must be a positive integer.' ;; esac
[ "$jobs" -ge 1 ] 2>/dev/null || fail '--jobs must be a positive integer.'
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'Build in a Linux AMD64 environment (for example Ubuntu 24.04 or a compatible Steam Linux Runtime SDK).'
for command in python3 readelf; do command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"; done
if [ "$audit_only" = 0 ]; then
    command -v "$compiler" >/dev/null 2>&1 || fail "Odin not found: $compiler"
    case "$compiler" in */*) compiler=$(CDPATH= cd -- "$(dirname -- "$compiler")" && pwd -P)/$(basename -- "$compiler") ;; esac
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "Destination exists: $destination. Choose a new directory or use --audit-only."
    sh "$root/tools/prepare_r3d.sh"
fi
# Python is a build-machine dependency only. Parse the manifest as JSON and pass
# every argument directly to Odin, preserving spaces in paths without eval.
python3 - "$root" "$destination" "$compiler" "$linker_flags" "$audit_only" "$jobs" <<'PY'
from concurrent.futures import ThreadPoolExecutor, as_completed
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, destination = (Path(arg).resolve() for arg in sys.argv[1:3])
compiler, linker_flags, audit_only = sys.argv[3], sys.argv[4], sys.argv[5] == "1"
jobs = int(sys.argv[6])
manifest = json.loads((root / "examples/examples.json").read_text())
examples = manifest["examples"]
names = [example["path"] for example in examples]
if not names or len(set(names)) != len(names) or any(not re.fullmatch(r"[a-z0-9_]+", name) for name in names):
    raise SystemExit("Invalid or duplicate example paths in examples/examples.json")
if not audit_only:
    odin_root = Path(subprocess.check_output([compiler, "root"], text=True).strip()).resolve()
    # A destination inside a copied source would copy itself recursively.
    # Resolve symlinks first so an alternate spelling cannot bypass the check.
    protected_sources = (root / "examples", root / "docs", root / "third_party", root / "rune/console/fonts",
                         odin_root / "vendor/box3d/src")
    for source in protected_sources:
        if destination == source.resolve() or source.resolve() in destination.parents:
            raise SystemExit(f"Destination is inside a copied source tree: {source}")
    destination.mkdir(parents=True)
    (destination / "build").mkdir()
    def build_example(example):
        name = example["path"]
        command = [compiler, "build", f"examples/{name}", "-o:speed", "-define:RAYLIB_SHARED=false",
                   "-collection:rune=rune", f"-out:{destination / 'build' / name}"]
        command.extend(f"-collection:{item['name']}={item['path']}" for item in example.get("collections", []))
        if linker_flags:
            command.append(f"-extra-linker-flags:{linker_flags}")
        print(f"Building {name}...", flush=True)
        return subprocess.run(command, cwd=root).returncode

    failures = []
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = {executor.submit(build_example, example): example["path"]
                   for example in [*examples, {"path": "launcher"}]}
        for future in as_completed(futures):
            name = futures[future]
            try:
                result = future.result()
            except Exception as error:
                print(f"Build failed: {name}: {error}", file=sys.stderr)
                failures.append(name)
            else:
                if result:
                    print(f"Build failed: {name} (exit {result})", file=sys.stderr)
                    failures.append(name)
    # All build processes finish before packaging, including on failure.
    if failures:
        raise SystemExit(f"Failed builds: {', '.join(failures)}. Partial tree preserved at {destination}.")
    shutil.copytree(root / "examples", destination / "examples")
    (destination / "console").mkdir()
    (destination / "tools").mkdir()
    shutil.copy2(root / "tools/console.sh", destination / "tools/console.sh")
    for name in ("LICENSE", "THIRD_PARTY.md", "README.md", "toolchain.json"):
        shutil.copy2(root / name, destination / name)
    shutil.copytree(root / "docs", destination / "docs")
    licenses = destination / "licenses"
    licenses.mkdir()
    for source in (root / "third_party").rglob("*"):
        if source.is_file() and (source.name.upper().startswith(("LICENSE", "COPYING")) or source.name == "OFL.txt"):
            target = licenses / "third_party" / source.relative_to(root / "third_party")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    for relative in ("LICENSE", "vendor/raylib/LICENSE", "vendor/box2d/LICENSE", "vendor/stb/src/stb_image.h"):
        source = odin_root / relative
        if not source.is_file():
            raise SystemExit(f"Missing toolchain license input: {source}")
        target = licenses / "odin" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # Box3D embeds dependency notices in its bundled source headers.
    shutil.copytree(odin_root / "vendor/box3d/src", licenses / "odin/vendor/box3d/src")
    shutil.copytree(root / "rune/console/fonts", licenses / "console-font")
    (destination / "run.sh").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
cd "$root"
mkdir -p console
export RUNE_EXAMPLES_PREBUILT=1
export RUNE_EXAMPLE_ARGS="${RUNE_EXAMPLE_ARGS:+$RUNE_EXAMPLE_ARGS }--console-dir=console"
exec ./build/launcher
''')
    (destination / "console.sh").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
cd "$root"
exec sh ./tools/console.sh --directory ./console "$@"
''')
    for name in ("run.sh", "console.sh", "tools/console.sh"):
        (destination / name).chmod(0o755)

records = []
for name in [*names, "launcher"]:
    binary = destination / "build" / name
    header = subprocess.check_output(["readelf", "-h", str(binary)], text=True)
    if "Advanced Micro Devices X86-64" not in header or "ELF64" not in header:
        raise SystemExit(f"Not a Linux AMD64 executable: {binary}")
    version_info = subprocess.check_output(["readelf", "--version-info", str(binary)], text=True)
    versions = {tuple(map(int, value.split("."))) for value in re.findall(r"GLIBC_([0-9]+(?:\.[0-9]+)+)", version_info)}
    if "GLIBC_PRIVATE" in version_info or any(version > (2, 39) for version in versions):
        raise SystemExit(f"{name} requires glibc above 2.39. Rebuild in a compatible SDK or toolchain/sysroot; host glibc is not bundled.")
    dynamic = subprocess.check_output(["readelf", "-d", str(binary)], text=True)
    libraries = re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic)
    if any(re.search(r"(raylib|r3d|box2d|box3d|assimp|importer)", library, re.I) for library in libraries):
        raise SystemExit(f"{name} still needs a shared engine library: {libraries}")
    records.append({"binary": name, "glibc_max": ".".join(map(str, max(versions, default=(0, 0)))), "needed": libraries})
    print(f"Audited {name}: GLIBC_{records[-1]['glibc_max']}")
report = {"audited_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "ceiling": "2.39", "binaries": records}
(destination / "glibc-audit.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"{'Audited' if audit_only else 'Staged'} {len(names)} examples + launcher at {destination}. Hardware validation remains separate.")
PY
