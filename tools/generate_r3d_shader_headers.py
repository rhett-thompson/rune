#!/usr/bin/env python3
"""Generate embedded headers using the exported, pinned R3D shader tools."""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    shader_root = options.source / "shaders"
    entries = {}
    # Include snippets can share a basename with an entry point (scene.vert).
    # Keep them out of the entry-point index rather than silently replacing it.
    for path in shader_root.rglob("*"):
        parts = path.relative_to(shader_root).parts
        if not path.is_file() or "include" in parts or "external" in parts:
            continue
        if path.name in entries:
            raise RuntimeError(f"Duplicate shader entry point: {path.name}")
        entries[path.name] = path
    module = (options.source / "src/modules/r3d_shader.c").read_text(encoding="utf-8")
    names = re.findall(r"#include <shaders/([^>]+)\.h>", module)
    if not names:
        raise RuntimeError("No embedded shader headers found in the pinned module")
    output = options.output / "shaders"
    output.mkdir(parents=True, exist_ok=True)
    for name in names:
        source = entries[name]
        temporary = output / (name + ".tmp")
        subprocess.run([sys.executable, str(options.source / "scripts/glsl_processor.py"),
                        "-I", str(shader_root / "include"), str(source), str(temporary)], check=True)
        processed = temporary.read_text(encoding="utf-8")
        if not processed.startswith("#version "):
            raise RuntimeError(f"Embedded shader entry point has no version directive: {source}")
        subprocess.run([sys.executable, str(options.source / "scripts/bin2c.py"),
                        "--file", str(temporary), "--name", name, "--mode", "text",
                        str(output / (name + ".h"))], check=True)
        temporary.unlink()


if __name__ == "__main__":
    main()
