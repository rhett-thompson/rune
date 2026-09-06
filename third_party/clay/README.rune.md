# Clay snapshot for Rune

Upstream: https://github.com/nicbarker/clay

Release: **v0.14**, commit `b25a31c1a152915cd7dd6796e6592273e5a10aac`.
`clay.h`, `LICENSE.md`, and `clay-odin/` are unmodified files from that commit
(`clay-odin/` originally lived at `bindings/odin/clay-odin/`). Native libraries
are the upstream prebuilt artifacts from the same commit. Rune validates the
Windows AMD64 library and ABI; other targets have not been tested here.

This dependency is linked only by programs importing `rune:ui`. It requires no
additional Odin collection flag and no network access during normal builds.
Retain `LICENSE.md` when redistributing Clay.

To rebuild the Windows object with Clang from the repository root:

```powershell
clang -x c -c third_party/clay/clay.h -DCLAY_IMPLEMENTATION -ffreestanding -target x86_64-pc-windows-msvc -O3 -o build/clay.lib
```

The upstream Windows `.lib` is a COFF object accepted by Odin's linker. After
validating the rebuilt object, replace `clay-odin/windows/clay.lib` explicitly.
Do not update the binding separately from the native library and header.
