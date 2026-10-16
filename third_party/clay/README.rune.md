# Clay snapshot for Rune

Upstream: https://github.com/nicbarker/clay

Release: **v0.14**, commit `b25a31c1a152915cd7dd6796e6592273e5a10aac`.
`clay.h`, `LICENSE.md`, and the `clay-odin/clay.odin` binding are unmodified
files from that commit (`clay-odin/` originally lived at
`bindings/odin/clay-odin/`). Native libraries are the upstream prebuilt
artifacts, except `clay-odin/linux/clay.a`, which Rune rebuilt for Linux AMD64
from the committed header.

The upstream Linux archive contained duplicate `clay.o` members, including a
stale implementation that ignored floating `clipTo = None`. Linking that member
made dropdown popups inherit their enclosing scroll clip, hiding options and
rejecting clicks outside the enclosing viewport. The rebuilt archive contains
one object compiled from `clay.h`; neither the header nor binding was changed.
All 29 headless Rune UI tests pass on Windows AMD64 and Linux AMD64 with the
pinned Odin `dev-2026-10-nightly:84bc3fc` (2026-10-16). Other Clay targets have
not been validated here.

This dependency is linked only by programs importing `rune:ui`. It requires no
additional Odin collection flag and no network access during normal builds.
Retain `LICENSE.md` when redistributing Clay.

To rebuild and test the Linux AMD64 archive from the repository root, use a
fresh temporary directory under `build/`. Create a new archive rather than
updating the bundled archive in place, which can preserve duplicate members.
The bundled archive was built with Clang 18.1.3 and GNU ar 2.42. The staged
source tree below tests the candidate before publishing it:

```sh
set -eu
mkdir -p build
clay_build=$(mktemp -d "$PWD/build/clay-linux-amd64.XXXXXX")
clang --target=x86_64-unknown-linux-gnu -x c -c third_party/clay/clay.h \
    -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O3 -o "$clay_build/clay.o"
ar rcsD "$clay_build/clay.a" "$clay_build/clay.o"
ar t "$clay_build/clay.a" # Must list exactly one clay.o.
mkdir -p "$clay_build/stage/third_party"
cp -R rune "$clay_build/stage/rune"
cp -R third_party/clay "$clay_build/stage/third_party/clay"
cp "$clay_build/clay.a" "$clay_build/stage/third_party/clay/clay-odin/linux/clay.a"
sh tools/odin.sh test "$clay_build/stage/rune/ui" "-collection:rune=$clay_build/stage/rune" \
    -define:ODIN_TEST_THREADS=1 "-out:$clay_build/ui_test"
```

After all staged UI tests pass, publish the candidate and verify the bundled
copy. Keep the generated object, archive, and test output together for review:

```sh
cp "$clay_build/clay.a" third_party/clay/clay-odin/linux/clay.a
sh tools/odin.sh test rune/ui -collection:rune=rune -define:ODIN_TEST_THREADS=1 \
    "-out:$clay_build/ui_test_bundled"
```

To rebuild the Windows object with Clang from the repository root:

```powershell
clang -x c -c third_party/clay/clay.h -DCLAY_IMPLEMENTATION -ffreestanding -target x86_64-pc-windows-msvc -O3 -o build/clay.lib
```

The upstream Windows `.lib` is a COFF object accepted by Odin's linker. After
validating the rebuilt object, replace `clay-odin/windows/clay.lib` explicitly.
Do not update the binding separately from the native library and header.
