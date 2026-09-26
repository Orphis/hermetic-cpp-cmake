#!/usr/bin/env python3
# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
"""Reference remote build execution (RBE) wrapper, for checking a build.

Run as CMake's compiler and linker launcher, it does to each compile and
link command what an RBE client has to do before sending it to a worker,
runs it locally the way a worker would, and checks that nothing
machine-specific is left:

    cmake ... -DHERMETIC_CACHE_DIR=<root>/.hermetic-cpp \\
      "-DCMAKE_<LANG>_COMPILER_LAUNCHER=python3;<repo>/scripts/rbe_wrapper.py;--root=<root>;--log=<file>;--strict;--" \\
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
    rbe_wrapper.py --root=<exec root> --archives-of=<build dir>

Without --strict, problems are reported and the command still runs. With
--dry-run, the relativized action is printed as JSON instead of run (and
the exit code tells whether it has problems). Static libraries have no
launcher: --archives-of does the same for every archiving command
(llvm-ar, llvm-ranlib, llvm-lib) of a Ninja build directory.
"""
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

WINDOWS = os.name == "nt"
# Options whose value is a made-up path, or holds one after an "=": only the
# part before is a path of this machine.
PREFIX_MAP_RE = re.compile(r"^(?:/clang:)?-f(?:file|debug|macro|profile|coverage)-prefix-map=")
FAKE_VALUE_PREFIXES = ("/pdbsourcepath:", "/pdbaltpath:", "-ffile-compilation-dir=", "-fdebug-compilation-dir=")
# cl.exe's prefix map: applied to the absolute paths it records, so <from>
# must be absolute when the command runs (see absolute_pathmap).
PATHMAP_RE = re.compile(r"^([/-]pathmap:)(.+?)=(.*)$", re.IGNORECASE)
# A path glued to an option: -I<dir>, /vctoolsdir<dir>, -isystem<dir>...
OPTION_PREFIX_RE = re.compile(r"[-/][A-Za-z][A-Za-z0-9_+-]*")
DRIVE_RE = re.compile(r"[A-Za-z]:[\\/]")
TRY_COMPILE_RE = re.compile(r"/CMakeFiles/(CMakeScratch/TryCompile-|CMakeTmp)")
ARCHIVERS = ("llvm-ar", "llvm-ranlib", "llvm-lib")


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
        if WINDOWS:
            p, r = p.lower(), r.lower()
        if p == r or p.startswith(r + "/"):
            return True
    return False


TOKEN_BOUNDARIES = " \t\r\n=,;\"'"


def relativize(text, roots, rel):
    """Rewrites every occurrence of ROOTS/ in TEXT as REL/, except inside a
    longer path: a spelling that a separator of the same token precedes (an
    option's own leading / or - aside), such as an output name CMake derived
    from an absolute source path, is left for the checks to report."""
    flags = re.IGNORECASE if WINDOWS else 0

    def replace(m):
        start = m.start()
        while start > 0 and m.string[start - 1] not in TOKEN_BOUNDARIES:
            start -= 1
        prefix = m.string[start:m.start()]
        if re.search(r"[/\\]", prefix[1:] if prefix[:1] in "/-" else prefix):
            return m.group(0)
        return rel

    for r in roots:
        for spelling in {r, r.replace("/", "\\")}:
            text = re.sub(re.escape(spelling) + r"(?=[/\\])", replace, text, flags=flags)
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
    if m and "=" in arg[m.end():]:
        arg = arg[: arg.find("=", m.end())]
    for i, ch in enumerate(arg):
        if ch != "/" and not DRIVE_RE.match(arg, i):
            continue
        if i > 0 and arg[i - 1] not in "=,:;" and not OPTION_PREFIX_RE.fullmatch(arg[:i]):
            continue
        candidate = re.split(r"[=,;]", arg[i:], maxsplit=1)[0]
        if is_host_path(candidate):
            return [candidate]
    return []


def embedded_roots_in(arg, roots):
    """The exec root left inside a longer path by relativize: a name made
    from the machine's absolute path (CMake names the objects of sources
    outside the source and build trees that way)."""
    flags = re.IGNORECASE if WINDOWS else 0
    for r in roots:
        for spelling in {r, r.replace("/", "\\")}:
            if re.search(re.escape(spelling) + r"(?=[/\\])", arg, flags):
                return [f"{arg} (names the exec root inside a longer path)"]
    return []


def absolute_pathmap(arg):
    """The executed form of a relativized /pathmap:<from>=<to>: cl.exe matches
    <from> against the absolute paths it records, so the wrapper resolves it
    against the working directory, as a remote execution client has to on
    the worker (the action key keeps the relative spelling)."""
    m = PATHMAP_RE.match(arg)
    if not m or os.path.isabs(m.group(2)) or DRIVE_RE.match(m.group(2)):
        return arg
    return f"{m.group(1)}{os.path.normpath(os.path.join(os.getcwd(), m.group(2)))}={m.group(3)}"


def overlay_files(argv):
    """VFS overlays the command reads (their contents are inputs too)."""
    files = []
    for i, a in enumerate(argv):
        if a in ("-ivfsoverlay", "--ivfsoverlay") and i + 1 < len(argv):
            # -Xclang -ivfsoverlay -Xclang <file>
            nxt = i + 2 if argv[i + 1] == "-Xclang" and i + 2 < len(argv) else i + 1
            files.append(argv[nxt])
        elif a.startswith("-ivfsoverlay") and len(a) > len("-ivfsoverlay"):
            files.append(a[len("-ivfsoverlay"):])
        elif a.lower().startswith("/vfsoverlay:"):
            files.append(a[len("/vfsoverlay:"):])
    return files


def depfiles(argv):
    files = []
    for i, a in enumerate(argv):
        if a == "-MF" and i + 1 < len(argv):
            files.append(argv[i + 1])
        elif a.startswith(("--dependency-file=", "-Wl,--dependency-file=")):
            files.append(a.split("=", 1)[1])
    return files


def analyze(argv, roots, write_rsp):
    """Relativizes ARGV for the current directory. Returns the action record
    (with "problems" when absolute host paths remain)."""
    real_root = os.path.realpath(roots[0])
    real_cwd = os.path.realpath(os.getcwd())
    rel = norm(os.path.relpath(real_root, real_cwd))
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
                problems += embedded_roots_in(tok.strip('"'), roots)
            out = a[1:] + ".rbe"
            if write_rsp:
                with open(out, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(text)
            rsp_contents[norm(out)] = text
            new_argv.append("@" + out)
        else:
            new_argv.append(relativize(a, roots, rel))
    for a in new_argv:
        problems += absolute_paths_in(a)
        problems += embedded_roots_in(a, roots)
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
    record = {"cwd": norm(os.path.relpath(real_cwd, real_root)), "argv": new_argv}
    if rsp_contents:
        record["rsp"] = rsp_contents
    record["key"] = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    if problems:
        record["problems"] = problems
    return record


def append_log(log, record):
    """Appends RECORD to LOG as one line. Ninja runs actions in parallel and
    appends are not atomic everywhere (Windows), hence the lock."""
    if not log:
        return
    line = (json.dumps(record, sort_keys=True) + "\n").encode()
    with open(log + ".lock", "a+b") as lock:
        if WINDOWS:
            import msvcrt
            lock.seek(0)
            while True:
                try:
                    msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
                    break
                except OSError:
                    pass  # LK_LOCK gives up after ten seconds; keep waiting
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            with open(log, "ab") as f:
                f.write(line)
        finally:
            if WINDOWS:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def is_local(argv0, roots):
    """Commands that stay local: tools outside the exec root, try_compile."""
    return not under(os.path.abspath(argv0), roots) or bool(TRY_COMPILE_RE.search(norm(os.getcwd()) + "/"))


# An archiving tool as a command's first word, possibly quoted, with or
# without .exe (the multicall driver's "llvm lib" too).
ARCHIVER_RE = re.compile(r'^"?[^" ]*?[\\/]?(llvm-ar|llvm-ranlib|llvm-lib|llvm(?=(\.exe)?"? lib\s))(\.exe)?"?(\s|$)',
                         re.IGNORECASE)


def split_windows(command):
    """Splits COMMAND into arguments as Windows programs do
    (CommandLineToArgvW): double quotes group, backslashes are literal
    unless they precede a double quote."""
    args, cur, quoted, have, i = [], [], False, False, 0
    while i < len(command):
        c = command[i]
        if c == "\\":
            j = i
            while j < len(command) and command[j] == "\\":
                j += 1
            if j < len(command) and command[j] == '"':
                cur.append("\\" * ((j - i) // 2))
                if (j - i) % 2:
                    cur.append('"')
                    j += 1
            else:
                cur.append("\\" * (j - i))
            have, i = True, j
        elif c == '"':
            quoted, have, i = not quoted, True, i + 1
        elif c in " \t" and not quoted:
            if have:
                args.append("".join(cur))
                cur, have = [], False
            i += 1
        else:
            cur.append(c)
            have, i = True, i + 1
    if have:
        args.append("".join(cur))
    return args


def archive_commands(commands, windows=WINDOWS):
    """The archiving commands in COMMANDS (the output of ninja -t commands),
    as argument lists; a command that cannot be split is returned whole, as
    a string."""
    for line in commands.splitlines():
        # Windows hosts chain commands as: cmd.exe /C "cd . && a && b"
        m = re.match(r'^cmd(?:\.exe)? /C "(.*)"$', line, re.IGNORECASE)
        if m:
            line = m.group(1)
        for part in line.split(" && "):
            part = part.strip()
            if not ARCHIVER_RE.match(part):
                continue
            try:
                yield split_windows(part) if windows else shlex.split(part)
            except ValueError:
                yield part


def run(argv, root, log, strict):
    roots = roots_of(root)
    if is_local(argv[0], roots):
        return subprocess.call(argv)
    if not under(os.getcwd(), roots):
        fail(f"working directory {os.getcwd()} is outside the exec root {roots[0]}")
        return 2
    record = analyze(argv, roots, write_rsp=True)
    append_log(log, record)
    if "problems" in record:
        fail(f"absolute paths left in {os.path.basename(argv[0])} command: " + ", ".join(record["problems"]))
        if strict:
            return 1
    new_argv = [absolute_pathmap(a) for a in record["argv"]]

    # A worker's environment: nothing from this machine.
    env = {"PATH": os.defpath}
    if WINDOWS:
        for k in ("SYSTEMROOT", "TEMP", "TMP", "PATHEXT"):
            if k in os.environ:
                env[k] = os.environ[k]
    if any(a.lower() in ("/showincludes", "-showincludes") for a in new_argv):
        proc = subprocess.run(new_argv, env=env, stdout=subprocess.PIPE)
        rc = proc.returncode
        # cl.exe names every included file by its resolved absolute path,
        # relative /I directories or not; a remote execution client rewrites
        # the ones inside the exec root to relative before handing them to
        # the build system, and so does the wrapper (others stay and are
        # reported below). clang-cl prints them as it was given them.
        rel = norm(os.path.relpath(os.path.realpath(roots[0]), os.path.realpath(os.getcwd())))
        out = []
        deps = []
        for line in proc.stdout.decode(errors="replace").splitlines(keepends=True):
            if line.startswith("Note: including file:"):
                line = relativize(line, roots, rel)
                deps.append(line.split(":", 2)[-1].strip())
            out.append(line)
        sys.stdout.write("".join(out))
        sys.stdout.flush()
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
        append_log(log, {"key": record["key"], "dependency_problems": after})
        if strict:
            return 1
    return 0


def main():
    args = sys.argv[1:]
    sep = args.index("--") if "--" in args else len(args)
    opts, argv = args[:sep], args[sep + 1:]
    root = log = archives_of = None
    strict = dry_run = False
    for o in opts:
        if o.startswith("--root="):
            root = o.split("=", 1)[1]
        elif o.startswith("--log="):
            log = o.split("=", 1)[1]
        elif o.startswith("--archives-of="):
            archives_of = o.split("=", 1)[1]
        elif o == "--strict":
            strict = True
        elif o == "--dry-run":
            dry_run = True
        else:
            fail(f"unknown option {o}")
            return 2
    if not root or not (argv or archives_of):
        fail("usage: rbe_wrapper.py --root=<dir> [--log=<file>] [--strict] [--dry-run] -- <command...>\n"
             "       rbe_wrapper.py --root=<dir> --archives-of=<build dir>")
        return 2
    roots = roots_of(root)

    if archives_of:
        rc = 0
        os.chdir(archives_of)
        commands = subprocess.run(["ninja", "-t", "commands"], capture_output=True, text=True, check=True).stdout
        for cmd in archive_commands(commands):
            if isinstance(cmd, str):
                print(json.dumps({"argv": [cmd], "key": "", "problems": ["cannot split this command"]}))
                rc = 1
                continue
            if is_local(cmd[0], roots):
                continue
            record = analyze(cmd, roots, write_rsp=False)
            print(json.dumps(record, sort_keys=True))
            rc |= "problems" in record
        return rc
    if dry_run:
        if is_local(argv[0], roots):
            return 0
        record = analyze(argv, roots, write_rsp=False)
        print(json.dumps(record, sort_keys=True))
        return 1 if "problems" in record else 0
    return run(argv, root, log, strict)


if __name__ == "__main__":
    sys.exit(main())
