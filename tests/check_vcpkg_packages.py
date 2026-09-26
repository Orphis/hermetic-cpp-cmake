#!/usr/bin/env python3
# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
"""Checks the static libraries vcpkg installed for a triplet.

  check_vcpkg_packages.py <installed>/<triplet> <crt> <machine path>...

- No library names a machine path (vcpkg's directories, the checkout, the
  toolchain cache): the toolchain maps them in port builds. Archive member
  names are only reported: CMake names the object of a source outside a
  port's source directory after its absolute path, and lib.exe-style
  archives (MSVC ABI) keep member paths.
- <crt> "static" or "dynamic": on the MSVC ABI, every object asks for that
  C runtime (/DEFAULTLIB), the debug one under debug/; "-" skips the check.
"""

import pathlib
import re
import sys

DEFAULTLIB = re.compile(rb'/DEFAULTLIB:"?(libcmtd?|msvcrtd?)\b', re.IGNORECASE)


def member_name_ranges(data):
    """Byte ranges of an ar archive that hold member names."""
    ranges = []
    if not data.startswith(b"!<arch>\n"):
        return ranges
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        ranges.append((offset, offset + 16))
        try:
            size = int(header[48:58].decode().strip())
        except ValueError:
            break
        name = header[:16].rstrip()
        start = offset + 60
        if name == b"//":  # long member names
            ranges.append((start, start + size))
        elif name.startswith(b"#1/"):  # BSD: the name precedes the contents
            ranges.append((start, start + int(name[3:])))
        offset = start + size + (size & 1)
    return ranges


def spellings(path):
    forward = path.replace("\\", "/").rstrip("/")
    variants = {forward, forward.replace("/", "\\"), forward.replace("/", "\\\\")}
    if forward.startswith("/private/"):  # macOS: /tmp is /private/tmp
        variants.add(forward[len("/private"):])
    return {v.encode() for v in variants if len(v) > 3}


def main():
    root = pathlib.Path(sys.argv[1])
    crt = sys.argv[2]
    needles = set()
    for path in sys.argv[3:]:
        needles |= spellings(path)
    libraries = sorted(p for p in root.rglob("*") if p.suffix in (".a", ".lib") and p.is_file())
    if not libraries:
        print(f"no libraries under {root}")
        return 1
    failures = 0
    for library in libraries:
        data = library.read_bytes()
        lowered = data.lower()
        names = member_name_ranges(data)
        in_contents = in_names = 0
        for needle in needles:
            for match in re.finditer(re.escape(needle.lower()), lowered):
                if any(start <= match.start() < end for start, end in names):
                    in_names += 1
                else:
                    in_contents += 1
        relative = library.relative_to(root)
        if in_contents:
            print(f"FAIL {relative}: {in_contents} machine path(s) in its contents")
            failures += 1
        elif in_names:
            print(f"note {relative}: machine paths in {in_names} member name(s)")
        if crt != "-":
            debug = relative.parts[0] == "debug"
            expected = {"static": "libcmt", "dynamic": "msvcrt"}[crt] + ("d" if debug else "")
            found = {m.group(1).decode().lower() for m in DEFAULTLIB.finditer(data)}
            if found != {expected}:
                print(f"FAIL {relative}: C runtime {sorted(found)}, expected {expected}")
                failures += 1
    print(f"{len(libraries)} libraries checked, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
