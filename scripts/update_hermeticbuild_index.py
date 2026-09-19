#!/usr/bin/env python3
"""Refresh cmake/distributions/hermeticbuild.json from hermeticbuild/hermetic-llvm.

The file is a verbatim copy of extensions/llvm_toolchain_minimal_index.json in
that repository (the index of its "llvm-toolchain-minimal" compiler prebuilts).
"""
import os
import sys
import urllib.request

SRC = "https://raw.githubusercontent.com/hermeticbuild/hermetic-llvm/main/extensions/llvm_toolchain_minimal_index.json"


def main():
    path = os.path.join(os.path.dirname(__file__), "..", "cmake", "distributions", "hermeticbuild.json")
    with urllib.request.urlopen(SRC) as resp:
        data = resp.read()
    with open(path, "wb") as f:
        f.write(data)
    print(f"{path}: {len(data)} bytes written from {SRC}")


if __name__ == "__main__":
    sys.exit(main())
