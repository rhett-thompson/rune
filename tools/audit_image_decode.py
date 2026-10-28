"""Audit private decoder COFF/ELF archives without executing native code."""
import struct
import sys
from pathlib import Path

EXPECTED = {"Rune_Image_Decode", "Rune_Image_Free"}
EXPECTED_TLS = {"stbi__g_failure_reason", "invalid_chunk"}


def cstring(data, offset):
    return data[offset:data.index(b"\0", offset)].decode("ascii")


def members(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("invalid archive member")
        size = int(header[48:58])
        yield data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2


def coff_symbols(data):
    machine, count, _, table, symbols, optional, _ = struct.unpack_from("<HHIIIHH", data)
    if machine != 0x8664 or optional:
        raise ValueError("expected AMD64 COFF object")
    names = data[table + symbols * 18:]
    sections = [data[20 + i * 40:28 + i * 40].rstrip(b"\0").decode("ascii") for i in range(count)]
    public, tls = set(), set()
    index = 0
    while index < symbols:
        raw_name, _, section, _, storage, extra = struct.unpack_from("<8sIhHBB", data, table + index * 18)
        name = cstring(names, struct.unpack_from("<I", raw_name, 4)[0]) if raw_name[:4] == b"\0" * 4 else raw_name.rstrip(b"\0").decode("ascii")
        # Clang emits externally coalesced literal COMDATs in COFF. They are
        # compiler data, not exported C API names or decoder implementation.
        compiler_literal = name.startswith(("??_C@", "__real@", "__xmm@", "__ymm@", "__zmm@"))
        if storage == 2 and section > 0 and not compiler_literal:
            public.add(name)
        if section > 0 and sections[section - 1].startswith(".tls"):
            if name == "stbi__g_failure_reason":
                tls.add(name)
            if name.endswith(".invalid_chunk"):
                tls.add("invalid_chunk")
        index += 1 + extra
    return public, tls


def elf_symbols(data):
    if data[4:6] != b"\x02\x01":
        raise ValueError("expected little-endian ELF64")
    offset = struct.unpack_from("<Q", data, 40)[0]
    count = struct.unpack_from("<H", data, 60)[0]
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, offset + i * 64) for i in range(count)]
    public, tls = set(), set()
    for section in sections:
        if section[1] != 2:
            continue
        strings = sections[section[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        for position in range(section[4], section[4] + section[5], section[9]):
            name_offset, info, _, owner, _, _ = struct.unpack_from("<IBBHQQ", data, position)
            name = cstring(names, name_offset)
            if info >> 4 in (1, 2) and owner != 0:
                public.add(name)
            if info & 15 == 6 and 0 < owner < len(sections) and sections[owner][2] & 0x400:
                if name == "stbi__g_failure_reason":
                    tls.add(name)
                if name.endswith(".invalid_chunk"):
                    tls.add("invalid_chunk")
    return public, tls


def audit(path):
    public, tls, objects = set(), set(), 0
    for member in members(path.read_bytes()):
        if member.startswith(b"\x7fELF"):
            symbols, thread_local = elf_symbols(member)
        elif member.startswith(b"\x64\x86"):
            symbols, thread_local = coff_symbols(member)
        else:
            continue
        public |= symbols
        tls |= thread_local
        objects += 1
    if objects != 1 or public != EXPECTED or tls != EXPECTED_TLS:
        raise ValueError(f"{path}: expected one object, only {sorted(EXPECTED)}, and both TLS error buffers; found {objects}, {sorted(public)}, TLS={sorted(tls)}")
    print(f"PASS {path}: only Rune_Image_Decode/Free are public; both stb error buffers are TLS")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Usage: python tools/audit_image_decode.py archive [archive ...]")
    for filename in sys.argv[1:]:
        audit(Path(filename))
