#!/usr/bin/env python3
# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
"""Reference remote build execution (RBE) wrapper, for checking a build.

Run as CMake's compiler and linker launcher, it does to each compile and
link command what an RBE client has to do before sending it to a worker,
runs it locally the way a worker would, and checks that nothing
machine-specific is left:

    cmake ... -DHERMETIC_LLVM_CACHE_DIR=<root>/.hermetic-llvm \
      "-DCMAKE_<LANG>_COMPILER_LAUNCHER=python3;<repo>/scripts/rbe_wrapper.py;--root=<root>;--log=<file>;--strict;--" \
      "-DCMAKE_<LANG>_LINKER_LAUNCHER=<the same>"

- Commands whose tool is not under the exec root (host tools) and compiler
  checks (try_compile, recognized by their working directory) run
  unchanged: they stay local.
- Every absolute path under the exec root (the workspace holding the
  sources, the build directories and the toolchain cache) is rewritten
  relative to the working directory, including inside joined options
  (-I<dir>, --sysroot=<dir>, /vctoolsdir<dir>, -ffile-prefix-map=<dir>=...)
  and response files.
- The rewritten command must not name any other absolute path of this
  machine, and neither must the VFS overlays it reads.
- It runs with a minimal environment, as on a worker.
- The dependency information it produces (depfiles, /showIncludes) must not
  name absolute paths either: a worker would report its own.
- Each action is logged as a JSON line (working directory relative to the
  exec root, command, key), so that two checkouts can be compared: the
  same key is the same remote cache entry.

    rbe_wrapper.py --root=<exec root> [--log=<file>] [--strict] [--dry-run] -- <command...>

Without --strict, problems are reported and the command still runs. With
--dry-run, the relativized action is printed as JSON instead of run (and
the exit code tells whether it has problems): for commands no launcher
reaches, such as static library archiving, taken from the build files.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

WINDOWS = os.name == "nt"
# Options whose value is a made-up path, or holds one after an "=": only the
# part before is a path of this machine.
PREFIX_MAP_RE = re.compile(r"^(?:/clang:)?-f(?:file|debug|macro|profile|coverage)-prefix-map=")
FAKE_VALUE_PREFIXES = ("/pdbsourcepath:", "/pdbaltpath:", "-ffile-compilation-dir=", "-fdebug-compilation-dir=")
# A path glued to an option: -I<dir>, /vctoolsdir<dir>, -isystem<dir>...
OPTION_PREFIX_RE = re.compile(r"[-/][A-Za-z][A-Za-z0-9_+-]*")
DRIVE_RE = re.compile(r"[A-Za-z]:[\\/]")


def fail(msg):
    sys.stderr.write(f"rbe_wrapper: {msg}\n")


def norm(path):
    return path.replace("\\", "/")


def roots_of(root):
    """The spellings of ROOT a command may use (as given, resolved)."""
    spellings = {norm(os.path.abspath(root)), norm(os.path.realpath(root))}
    return sorted(spellings, key=len, reverse=True)


def under(path, roots):
    p = norm(path)
    for r in roots:
        if p == r or p.startswith(r + "/") or (WINDOWS and p.lower().startswith(r.lower() + "/")):
            return True
    return False


def relativize(text, roots, rel):
    """Rewrites every occurrence of ROOTS/ in TEXT as REL/."""
    for r in roots:
        for spelling in {r, r.replace("/", "\\")}:
            flags = re.IGNORECASE if WINDOWS else 0
            text = re.sub(re.escape(spelling) + r"(?=[/\\])", lambda _: rel, text, flags=flags)
    return text


def is_host_path(candidate):
    """True when CANDIDATE is an absolute path into this machine's file
    system: its first component exists (/Users, /home, C:/...)."""
    c = norm(candidate)
    if DRIVE_RE.match(c):
        return os.path.isdir(c[:3])
    if not c.startswith("/") or c.startswith("//"):
        return False
    first = c[1:].split("/", 1)[0]
    return first not in ("", ".", "..") and os.path.exists("/" + first)


def absolute_paths_in(arg):
    """Absolute host paths in one argument, wherever glued."""
    if arg.startswith(FAKE_VALUE_PREFIXES):
        return []
    m = PREFIX_MAP_RE.match(arg)
    if m:
        arg = arg[: arg.find("=", m.end())] if "=" in arg[m.end():] else arg
    found = []
    for i, ch in enumerate(arg):
        starts = ch == "/" or DRIVE_RE.match(arg, i)
        if not starts:
            continue
        if i > 0 and arg[i - 1] not in "=,:;" and not OPTION_PREFIX_RE.fullmatch(arg[:i]):
            continue
        if DRIVE_RE.match(arg, i) and i > 0 and arg[i - 1] == ":":
            continue
        candidate = re.split(r"[=,;]", arg[i:], maxsplit=1)[0]
        if is_host_path(candidate):
            found.append(candidate)
            break
    return found


def overlay_files(argv):
    """VFS overlays the command reads (their contents are inputs too)."""
    files = []
    for i, a in enumerate(argv):
        if a in ("-ivfsoverlay", "--ivfsoverlay") and i + 1 < len(argv):
            # -Xclang -ivfsoverlay -Xclang <file>
            nxt = i + 2 if argv[i + 1] == "-Xclang" and i + 2 < len(argv) else i + 1
            files.append(argv[nxt])
        elif a.startswith("-ivfsoverlay"):
            files.append(a[len("-ivfsoverlay"):])
        elif a.lower().startswith("/vfsoverlay:"):
            files.append(a[len("/vfsoverlay:"):])
    return files


def depfiles(argv):
    files = []
    for i, a in enumerate(argv):
        if a == "-MF" and i + 1 < len(argv):
            files.append(argv[i + 1])
        elif a.startswith("--dependency-file="):
            files.append(a.split("=", 1)[1])
        elif a.startswith("-Wl,--dependency-file="):
            files.append(a.split("=", 1)[1])
    return files


def main():
    args = sys.argv[1:]
    if "--" not in args:
        fail("usage: rbe_wrapper.py --root=<dir> [--log=<file>] [--strict] -- <command...>")
        return 2
    sep = args.index("--")
    opts, argv = args[:sep], args[sep + 1:]
    root = log = None
    strict = dry_run = False
    for o in opts:
        if o.startswith("--root="):
            root = o.split("=", 1)[1]
        elif o.startswith("--log="):
            log = o.split("=", 1)[1]
        elif o == "--strict":
            strict = True
        elif o == "--dry-run":
            dry_run = True
    if not root or not argv:
        fail("--root and a command are required")
        return 2

    roots = roots_of(root)
    cwd = norm(os.getcwd())
    # Local actions: the tool is not part of the workspace, or this is a
    # compiler check, which is not worth a round trip to a worker.
    if not under(os.path.abspath(argv[0]), roots) or re.search(r"/CMakeFiles/(CMakeScratch/TryCompile-|CMakeTmp)", cwd + "/"):
        return 0 if dry_run else subprocess.call(argv)

    if not under(cwd, roots):
        fail(f"working directory {cwd} is outside the exec root {roots[0]}")
        return 2
    real_root, real_cwd = os.path.realpath(root), os.path.realpath(cwd)
    rel = norm(os.path.relpath(real_root, real_cwd))
    rel_cwd = norm(os.path.relpath(real_cwd, real_root))

    problems = []
    new_argv = []
    rsp_contents = {}
    for a in argv:
        if a.startswith("@") and os.path.isfile(a[1:]):
            # Response file: rewrite its contents into a sibling file.
            with open(a[1:], encoding="utf-8", errors="surrogateescape") as f:
                text = relativize(f.read(), roots, rel)
            for tok in text.split():
                problems += absolute_paths_in(tok.strip('"'))
            out = a[1:] + ".rbe"
            if not dry_run:
                with open(out, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(text)
            rsp_contents[out] = text
            new_argv.append("@" + out)
        else:
            new_argv.append(relativize(a, roots, rel))
    for a in new_argv:
        problems += absolute_paths_in(a)
    for overlay in overlay_files(new_argv):
        try:
            with open(overlay, encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            problems.append(f"{overlay} (unreadable: {e})")
            continue
        for m in re.finditer(r"'([^']*)'", text):
            if is_host_path(m.group(1)):
                problems.append(f"{m.group(1)} (in {overlay})")
                break

    record = {"cwd": rel_cwd, "argv": new_argv}
    if rsp_contents:
        record["rsp"] = rsp_contents
    record["key"] = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    if problems:
        record["problems"] = problems
    if dry_run:
        print(json.dumps(record, sort_keys=True))
        return 1 if problems else 0
    if log:
        line = json.dumps(record, sort_keys=True) + "\n"
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    if problems:
        fail(f"absolute paths left in {os.path.basename(argv[0])} command: " + ", ".join(problems))
        if strict:
            return 1

    # A worker's environment: nothing from this machine.
    env = {"PATH": os.defpath}
    if WINDOWS:
        for k in ("SYSTEMROOT", "TEMP", "TMP", "PATHEXT"):
            if k in os.environ:
                env[k] = os.environ[k]
    show_includes = any(a.lower() in ("/showincludes", "-showincludes") for a in new_argv)
    if show_includes:
        proc = subprocess.run(new_argv, env=env, stdout=subprocess.PIPE)
        sys.stdout.buffer.write(proc.stdout)
        sys.stdout.flush()
        rc = proc.returncode
        deps = [l.split(":", 2)[-1].strip() for l in proc.stdout.decode(errors="replace").splitlines()
                if l.startswith("Note: including file:")]
    else:
        rc = subprocess.call(new_argv, env=env)
        deps = []
    if rc != 0:
        return rc

    # Dependency information a worker would send back.
    after = []
    for dep in deps:
        after += [f"{p} (/showIncludes)" for p in absolute_paths_in(dep)]
    for d in depfiles(new_argv):
        try:
            with open(d, encoding="utf-8", errors="replace") as f:
                tokens = f.read().replace("\\\n", " ").split()
        except OSError:
            continue
        for tok in tokens:
            if is_host_path(tok.rstrip(":")):
                after.append(f"{tok.rstrip(':')} (in {d})")
                break
    if after:
        fail(f"absolute paths in the dependencies of {os.path.basename(argv[0])}: " + ", ".join(after))
        if log:
            fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            try:
                os.write(fd, (json.dumps({"key": record["key"], "dependency_problems": after}) + "\n").encode())
            finally:
                os.close(fd)
        if strict:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
