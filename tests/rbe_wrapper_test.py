#!/usr/bin/env python3
# Copyright 2026 The hermetic-cpp-cmake Authors.
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
        os.makedirs(f"{root}/.hermetic-cpp/sysroot")
        tool = f"{root}/.hermetic-cpp/bin/clang"
        # A directory of this machine outside the exec root.
        host = os.path.dirname(os.path.realpath(sys.executable)).replace("\\", "/")

        rc, r = dry_run(root, build, [tool, f"-I{root}/src", f"--sysroot={root}/.hermetic-cpp/sysroot",
                                      f"-ffile-prefix-map={root}/.hermetic-cpp=/hermetic-cpp/cache",
                                      "-isystem", f"{root}/.hermetic-cpp/sysroot/include",
                                      f"/vctoolsdir{root}/.hermetic-cpp/msvc", "-c", f"{root}/src/a.c"])
        check("paths under the root are rewritten relative to the working directory",
              rc == 0 and r["argv"] == ["../../../.hermetic-cpp/bin/clang", "-I../../../src",
                                        "--sysroot=../../../.hermetic-cpp/sysroot",
                                        "-ffile-prefix-map=../../../.hermetic-cpp=/hermetic-cpp/cache",
                                        "-isystem", "../../../.hermetic-cpp/sysroot/include",
                                        "/vctoolsdir../../../.hermetic-cpp/msvc", "-c", "../../../src/a.c"]
              and r["cwd"] == "src/build/x", json.dumps(r))

        for arg in (f"-I{host}", host, f"/imsvc{host}", f"/LIBPATH:{host}", f"--sysroot={host}",
                    f"-ffile-prefix-map={host}=/src", f"-Wl,-rpath,{host}"):
            rc, r = dry_run(root, build, [tool, arg])
            check(f"reports {arg.replace(host, '<host dir>')}", rc == 1 and "problems" in r, json.dumps(r))

        for arg in ("-ffile-prefix-map=../x=/hermetic-cpp/cache", "/pdbsourcepath:/build", "/nologo", "-DX=1",
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

        with open(f"{root}/.hermetic-cpp/o.yaml", "w") as f:
            f.write(f"{{ 'roots': [ {{ 'name': '{host}', 'type': 'directory', 'contents': [] }} ] }}")
        rc, r = dry_run(root, build, [tool, "-Xclang", "-ivfsoverlay", "-Xclang", f"{root}/.hermetic-cpp/o.yaml"])
        check("VFS overlays with absolute paths are reported", rc == 1 and "problems" in r, json.dumps(r))

    # Archive commands as Ninja lists them, on Unix and Windows hosts.
    sys.path.insert(0, os.path.dirname(WRAPPER))
    import rbe_wrapper
    unix = ("/r/.hermetic-cpp/bin/clang -D__DATE__=\\\"redacted\\\" -c a.c -o a.o\n"
            ": && /usr/bin/cmake -E rm -f libx.a && /r/.hermetic-cpp/bin/llvm-ar qc libx.a  a.o b.o"
            " && /r/.hermetic-cpp/bin/llvm-ranlib libx.a && /usr/bin/cmake -E touch libx.a && :\n")
    got = list(rbe_wrapper.archive_commands(unix, windows=False))
    check("finds archive commands (Unix host)",
          got == [["/r/.hermetic-cpp/bin/llvm-ar", "qc", "libx.a", "a.o", "b.o"],
                  ["/r/.hermetic-cpp/bin/llvm-ranlib", "libx.a"]], repr(got))
    windows = ('C:/r/.hermetic-cpp/bin/clang-cl.exe -D__DATE__=\\"redacted\\" /FoCMakeFiles\\a.obj -c a.c\n'
               'cmd.exe /C "cd . && C:\\cmake\\bin\\cmake.exe -E rm -f libx.a && '
               'C:/r/.hermetic-cpp/bin/llvm-ar.exe qc libx.a CMakeFiles\\x.dir\\a.obj && '
               'C:/r/.hermetic-cpp/bin/llvm-ranlib.exe libx.a && cd ."\n'
               '"C:/r/.hermetic-cpp/bin/llvm-lib.exe" /nologo /out:x.lib "CMakeFiles/x dir/a.obj"\n'
               'C:/r/.hermetic-cpp/bin/llvm.exe lib /out:y.lib b.obj\n')
    got = list(rbe_wrapper.archive_commands(windows, windows=True))
    check("finds archive commands (Windows host)",
          got == [["C:/r/.hermetic-cpp/bin/llvm-ar.exe", "qc", "libx.a", "CMakeFiles\\x.dir\\a.obj"],
                  ["C:/r/.hermetic-cpp/bin/llvm-ranlib.exe", "libx.a"],
                  ["C:/r/.hermetic-cpp/bin/llvm-lib.exe", "/nologo", "/out:x.lib", "CMakeFiles/x dir/a.obj"],
                  ["C:/r/.hermetic-cpp/bin/llvm.exe", "lib", "/out:y.lib", "b.obj"]], repr(got))
    # The command line: a "b c" d\e \"f\" "g\\" h
    got = rbe_wrapper.split_windows('a "b c" d\\e \\"f\\" "g\\\\" h')
    check("splits like CommandLineToArgvW", got == ["a", "b c", "d\\e", '"f"', "g\\", "h"], repr(got))

    # /showIncludes notes: paths inside the exec root come back relative (as
    # cl.exe prints them absolute), paths outside are reported.
    if os.name != "nt":
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.realpath(os.path.join(tmp, "ws")).replace("\\", "/")
            build = f"{root}/src/build/x"
            os.makedirs(build)
            os.makedirs(f"{root}/.hermetic-cpp/bin")
            os.makedirs(f"{root}/.hermetic-cpp/inc")
            fake = f"{root}/.hermetic-cpp/bin/cl"
            with open(fake, "w") as f:
                f.write("#!/bin/sh\n"
                        f"echo 'Note: including file: {root}/.hermetic-cpp/inc/a.h'\n"
                        "for a in \"$@\"; do case \"$a\" in *host*) echo 'Note: including file: /usr/include/stdio.h';; esac; done\n")
            os.chmod(fake, 0o755)
            log = f"{root}/rbe.jsonl"
            proc = subprocess.run([sys.executable, WRAPPER, f"--root={root}", f"--log={log}", "--strict", "--",
                                   fake, "/showIncludes", "-c", f"{root}/src/a.c"], cwd=build, capture_output=True, text=True)
            check("showIncludes: exec-root paths rewritten relative",
                  proc.returncode == 0 and "Note: including file: ../../../.hermetic-cpp/inc/a.h" in proc.stdout,
                  f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
            proc = subprocess.run([sys.executable, WRAPPER, f"--root={root}", f"--log={log}", "--strict", "--",
                                   fake, "/showIncludes", "-Dhost", "-c", f"{root}/src/a.c"], cwd=build, capture_output=True, text=True)
            check("showIncludes: host paths outside the root reported",
                  proc.returncode == 1 and "/usr/include/stdio.h (/showIncludes)" in proc.stderr,
                  f"rc={proc.returncode} err={proc.stderr!r}")

    print("all passed" if failures == 0 else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
