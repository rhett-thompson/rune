# Clay snapshot for Rune

Upstream: https://github.com/nicbarker/clay

Release: **v0.14**, commit `b25a31c1a152915cd7dd6796e6592273e5a10aac`.
`LICENSE.md` and the `clay-odin/clay.odin` binding are unmodified
files from that commit (`clay-odin/` originally lived at
`bindings/odin/clay-odin/`). Rune rebuilds the Windows AMD64 object and Linux
AMD64 archive from the committed header; other target artifacts remain the
upstream prebuilts and have not been validated with Rune's header patch.

Rune patches `Clay__InitializePersistentMemory` in `clay.h` to allocate clip/
scroll-container storage for `maxElementCount` rather than upstream's fixed ten
entries. Every clipped text input consumes an entry even when its value fits;
an inspector with ten inputs and its enclosing scroll panel exceeds the old
limit. `Clay_MinMemorySize` calls the same initializer, so this bounded storage
is included in the normal arena estimate. This changes no public API or ABI.
Rebuild each supported native artifact from the patched header when applying
the patch; editing the header alone does not change the linked implementation.
`rune/ui/scroll_nested_test.odin` exercises 24 inputs in an inspector across
resizing, field removal/reappearance, and wheel routing. Run it serially with
the complete UI suite after publishing a candidate native artifact.

The upstream Linux archive contained duplicate `clay.o` members, including a
stale implementation that ignored floating `clipTo = None`. Linking that member
made dropdown popups inherit their enclosing scroll clip, hiding options and
rejecting clicks outside the enclosing viewport. The rebuilt archive contains
one object compiled from `clay.h`; the binding is unchanged.

The patched Windows AMD64 object was rebuilt with MSVC 19.51 in a Visual Studio
18 x64 developer environment (`/TC /std:c11 /O2 /GS- /Zl`). All 30 serial
headless Rune UI tests passed against a staged candidate before it replaced
`clay-odin/windows/clay.lib` (2026-10-18). This covers native clip capacity,
layout, pointer routing, and the existing UI regressions; it does not establish
rendered pixels.

The patched Linux AMD64 archive was built with Zig 0.15.2's Clang 20.1.2,
targeting `x86_64-linux-gnu` with `-DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O3`,
then archived with GNU ar 2.42 using `rcsD`. It contains exactly one ELF64
`clay.o`, whose only undefined symbols are `memcpy` and `memset`. All 30 serial
headless Rune UI tests passed against both the staged candidate and published
`clay-odin/linux/clay.a` in Ubuntu WSL with pinned Odin
`dev-2026-10-nightly:84bc3fc` (2026-10-18). This does not establish rendered
pixels or non-WSL runtime behavior. Other Clay targets remain unvalidated.

This dependency is linked only by programs importing `rune:ui`. It requires no
additional Odin collection flag and no network access during normal builds.
Retain `LICENSE.md` when redistributing Clay.

To rebuild and test the Linux AMD64 archive from the repository root, use a
fresh temporary directory under `build/`. Create a new archive rather than
updating the bundled archive in place, which can preserve duplicate members.
The staged source tree below tests the candidate before publishing it. The
published archive used `zig cc -target x86_64-linux-gnu` in place of the Clang
driver below, with the same C compilation flags:

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

To reproduce the Windows object from an x64 Visual Studio developer shell:

```powershell
cl /nologo /TC /std:c11 /O2 /GS- /Zl /DCLAY_IMPLEMENTATION /c /Fobuild/clay.lib third_party/clay/clay.h
```

Clang is also supported from the repository root:

```powershell
clang -x c -c third_party/clay/clay.h -DCLAY_IMPLEMENTATION -ffreestanding -target x86_64-pc-windows-msvc -O3 -o build/clay.lib
```

The Windows `.lib` is a COFF object accepted by Odin's linker. After
validating the rebuilt object, replace `clay-odin/windows/clay.lib` explicitly.
Do not update the binding separately from the native library and header.
