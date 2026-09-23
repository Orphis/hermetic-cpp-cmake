#!/usr/bin/env python3
# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
"""Checks scripts/rbe_wrapper.py without a toolchain: which paths it rewrites
and which it reports (--dry-run on made-up commands).

    python3 tests/rbe_wrapper_test.py
"""
import json
import os
import subprocess
import sys
import tempfile

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "rbe_wrapper.py")


def dry_run(root, cwd, argv):
    proc = subprocess.run([sys.executable, WRAPPER, f"--root={root}", "--dry-run", "--", *argv],
                          cwd=cwd, capture_output=True, text=True)
    record = json.loads(proc.stdout) if proc.stdout.strip() else None
    return proc.returncode, record


def main():
    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        print(("ok    " if ok else "FAIL  ") + name + (f": {detail}" if not ok and detail else ""))
        failures += not ok

    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.realpath(os.path.join(tmp, "ws")).replace("\\", "/")
        build = f"{root}/src/build/x"
        os.makedirs(build)
        os.makedirs(f"{root}/.hermetic-llvm/sysroot")
        tool = f"{root}/.hermetic-llvm/bin/clang"
        # A directory of this machine outside the exec root.
        host = os.path.dirname(os.path.realpath(sys.executable)).replace("\\", "/")

        rc, r = dry_run(root, build, [tool, f"-I{root}/src", f"--sysroot={root}/.hermetic-llvm/sysroot",
                                      f"-ffile-prefix-map={root}/.hermetic-llvm=/hermetic-llvm/cache",
                                      "-isystem", f"{root}/.hermetic-llvm/sysroot/include",
                                      f"/vctoolsdir{root}/.hermetic-llvm/msvc", "-c", f"{root}/src/a.c"])
        check("paths under the root are rewritten relative to the working directory",
              rc == 0 and r["argv"] == ["../../../.hermetic-llvm/bin/clang", "-I../../../src",
                                        "--sysroot=../../../.hermetic-llvm/sysroot",
                                        "-ffile-prefix-map=../../../.hermetic-llvm=/hermetic-llvm/cache",
                                        "-isystem", "../../../.hermetic-llvm/sysroot/include",
                                        "/vctoolsdir../../../.hermetic-llvm/msvc", "-c", "../../../src/a.c"]
              and r["cwd"] == "src/build/x", json.dumps(r))

        for arg in (f"-I{host}", host, f"/imsvc{host}", f"/LIBPATH:{host}", f"--sysroot={host}",
                    f"-ffile-prefix-map={host}=/src", f"-Wl,-rpath,{host}"):
            rc, r = dry_run(root, build, [tool, arg])
            check(f"reports {arg.replace(host, '<host dir>')}", rc == 1 and "problems" in r, json.dumps(r))

        for arg in ("-ffile-prefix-map=../x=/hermetic-llvm/cache", "/pdbsourcepath:/build", "/nologo", "-DX=1",
                    "-ffile-compilation-dir=.", "/Fofoo.obj", "-o", "out/a.o"):
            rc, r = dry_run(root, build, [tool, arg])
            check(f"accepts {arg}", rc == 0 and "problems" not in r, json.dumps(r))

        rc, r = dry_run(root, build, [os.path.realpath(sys.executable), f"-I{host}"])
        check("tools outside the root are local actions", rc == 0 and r is None)
        scratch = f"{build}/CMakeFiles/CMakeScratch/TryCompile-abc"
        os.makedirs(scratch)
        rc, r = dry_run(root, scratch, [tool, f"-I{host}"])
        check("try_compile commands are local actions", rc == 0 and r is None)

        with open(f"{build}/cmd.rsp", "w") as f:
            f.write(f"-I{root}/src {root}/src/a.o")
        rc, r = dry_run(root, build, [tool, "@cmd.rsp"])
        check("response files are rewritten", rc == 0 and "-I../../../src ../../../src/a.o" in r["rsp"].values(),
              json.dumps(r))

        with open(f"{root}/.hermetic-llvm/o.yaml", "w") as f:
            f.write(f"{{ 'roots': [ {{ 'name': '{host}', 'type': 'directory', 'contents': [] }} ] }}")
        rc, r = dry_run(root, build, [tool, "-Xclang", "-ivfsoverlay", "-Xclang", f"{root}/.hermetic-llvm/o.yaml"])
        check("VFS overlays with absolute paths are reported", rc == 1 and "problems" in r, json.dumps(r))

    print("all passed" if failures == 0 else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
