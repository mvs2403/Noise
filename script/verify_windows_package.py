#!/usr/bin/env python3
"""Reject wrong architectures and unbundled Visual C++ runtime dependencies."""
from pathlib import Path
import re
import struct
import sys


def imports(path):
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0": raise RuntimeError(f"Invalid PE file: {path}")
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    if machine != 0x8664: raise RuntimeError(f"Expected x64: {path}")
    optional_length = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    directory = optional + 112  # PE32+ data directories
    sections = optional + optional_length
    def offset(rva):
        for i in range(count):
            entry = sections + i * 40
            size, address, raw_size, raw = struct.unpack_from("<IIII", data, entry + 8)
            if address <= rva < address + max(size, raw_size): return raw + rva - address
        raise RuntimeError(f"Invalid import RVA in {path}")
    address, size = struct.unpack_from("<II", data, directory + 8)
    if not address: return []
    position = offset(address); names = []
    for _ in range(2048):
        descriptor = struct.unpack_from("<IIIII", data, position)
        if not any(descriptor): return names
        begin = offset(descriptor[3]); end = data.index(0, begin)
        names.append(data[begin:end].decode("ascii").lower()); position += 20
    raise RuntimeError(f"Invalid import table: {path}")


def main():
    stage = Path(sys.argv[1]); files = list(stage.rglob("*.dll")) + list(stage.glob("*.exe"))
    bundled = {p.name.lower() for p in files}
    for path in files:
        # Managed assemblies may use PE32 even in an x64 self-contained app.
        if path.parent != stage / "Runtime" and not path.name.startswith(("libSkia", "libHarf", "av_libgles", "Noise.exe")): continue
        for dependency in imports(path):
            if re.match(r"(?:vcruntime|msvcp|concrt)\d", dependency) and dependency not in bundled:
                raise RuntimeError(f"{path.name} requires unbundled {dependency}")
    required = ["noise_dsp.dll", "rnnoise.dll", "df.dll", "weya_nc.dll", "sherpa-onnx-c-api.dll"]
    for name in required:
        if not (stage / "Runtime" / name).is_file(): raise RuntimeError(f"Missing {name}")
    print("PASS Windows x64 native architecture and portable CRT dependencies")


if __name__ == "__main__": main()
