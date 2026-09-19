# Hermetic LLVM toolchain for CMake

A CMake toolchain file that follows the model of
[hermeticbuild/hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm):
a small prebuilt Clang/LLD, and for every Linux target a **runtime set**
built from source with that compiler (libc, compiler-rt, libc++), so that
cross-compiling needs no distribution sysroot at all. Targets can pick the
glibc version to link against (2.28 to 2.44, via headers plus symbol stubs,
the same technique as Zig and hermetic-llvm) or musl (fully static
binaries).

```sh
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/hermetic-llvm-cmake/toolchain.cmake \
  -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_LLVM_TARGET=linux-aarch64 -DHERMETIC_LLVM_LIBC=musl
cmake --build build
```

Or with a preset:

```json
{
  "name": "linux-aarch64-musl",
  "generator": "Ninja",
  "toolchainFile": "${sourceDir}/third_party/hermetic-llvm-cmake/toolchain.cmake",
  "cacheVariables": {
    "HERMETIC_LLVM_VERSION": "23.1.0",
    "HERMETIC_LLVM_TARGET": "linux-aarch64",
    "HERMETIC_LLVM_LIBC": "musl"
  }
}
```

## What it does

1. **Compiler.** Detects the host and downloads the matching
   "llvm-toolchain-minimal" prebuilt published by hermetic-llvm (32 to 45 MB;
   Clang, LLD, the LLVM binutils and the builtin headers, no runtime
   libraries). The index in
   [`cmake/distributions/hermeticbuild.json`](cmake/distributions/hermeticbuild.json)
   is a verbatim copy of theirs. Linux hosts get the static musl build, which
   runs on any distribution.
2. **Runtime set** (Linux targets). For `<target>-<libc>`, e.g.
   `linux-x86_64-gnu.2.28` or `linux-aarch64-musl`, a directory with
   everything the link needs is downloaded if a prebuilt is listed in
   [`cmake/distributions/runtime_sets.json`](cmake/distributions/runtime_sets.json),
   and otherwise built locally in a few minutes:
   - **glibc**: the glibc headers for that version, crt objects and
     `libc_nonshared.a` compiled from the glibc sources, and stub shared
     libraries (`libc.so.6`, `libm.so.6`, ...) generated from Zig's abilists
     blob so that only symbols existing in that glibc version can be linked.
     Binaries run on any system with that glibc or newer.
   - **musl**: musl 1.2.6 compiled from source (`libc.a`, crt objects);
     binaries are linked `-static-pie` and have no runtime dependency. As in
     hermetic-llvm, musl targets are static only: no `libc.so`, and shared
     libraries cannot be built for them.
   - Linux UAPI headers matching the libc, compiler-rt builtins and
     `crtbegin`/`crtend` (in a merged clang resource directory), libc++,
     libc++abi and libunwind as static libraries, and optionally the
     sanitizer runtimes, all built from the LLVM sources of the same version
     as the compiler. Links use `-rtlib=compiler-rt --unwindlib=libunwind`.
3. **macOS targets** use the SDK from Xcode or the Command Line Tools (or
   the directory in `HERMETIC_LLVM_SYSROOT`) with the SDK's libc++.
4. **CMake configuration**: compilers, binutils, `CMAKE_SYSTEM_NAME`,
   `CMAKE_<LANG>_COMPILER_TARGET`, `CMAKE_SYSROOT` (the runtime set), LLD,
   `-resource-dir`, `-rtlib=compiler-rt`, static libc++ and the link mode.
   Whenever a runtime set is used, also for a native Linux build, the
   `CMAKE_FIND_ROOT_PATH_MODE_*` variables are set to `ONLY` (`NEVER` for
   programs) so `find_package` and friends cannot pick up host headers or
   libraries; set them yourself before the toolchain runs to override.

Everything lives in one cache directory (`~/.cache/hermetic-llvm` by
default). Downloads are SHA-256 checked, extraction and runtime set builds
are atomic and lock-protected, and reconfigures only check stamp files.

## Requirements

- CMake 3.19 or newer and Ninja (for building runtime sets).
- A Linux or macOS host (Windows hosts are only wired up for cross-compiling
  to Linux and are untested).
- Xcode or the Command Line Tools when building for macOS.
- Building a runtime set locally needs about 3 GB of disk for the extracted
  LLVM sources plus 100 MB per set, and two to three minutes of CPU.

## Options

All options are ordinary cache variables (`-D...`) and are forwarded to
`try_compile` projects. `cmake -P scripts/help.cmake` prints them with the
supported targets, libc versions, compiler prebuilts and runtime sets.

### Compiler

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMETIC_LLVM_VERSION` | `latest` | Exact version (`23.1.0`, `23.1.0-rc1`) or a requirement: `latest`, `first`, `latest:>=22,<23`. Prereleases are only selected by exact version. `latest` is relative to the bundled index, so it is reproducible for a given checkout. |
| `HERMETIC_LLVM_RELEASE` | | Pin a hermetic-llvm release id (`llvm-23.1.0-3`) instead of a version. |
| `HERMETIC_LLVM_HERMETICBUILD_INDEX` | | Another copy of the compiler index (same schema). |
| `HERMETIC_LLVM_DISTRIBUTION_URL` / `_SHA256` / `_STRIP_COMPONENTS` | | Bring your own compiler archive (`bin/clang` at the root, or set the strip count). |
| `HERMETIC_LLVM_MIRROR_URLS` | | URL templates tried after the primary URL; `{version}`, `{release}` and `{basename}` are substituted. |

### Target, libc and runtimes

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMETIC_LLVM_TARGET` | host | `linux-x86_64`, `linux-aarch64`, `linux-armv7`, `linux-riscv64`, `linux-s390x`, `darwin-x86_64`, `darwin-aarch64`. |
| `HERMETIC_LLVM_LIBC` | `gnu.2.28` | Linux libc: `gnu.<version>` (2.28 to 2.44) or `musl`. The runtime set id is `<target>-<libc>`. |
| `HERMETIC_LLVM_RUNTIMES` | `auto` | `auto`: use a prebuilt runtime set when the index lists one, else build it; `download`: fail if none is listed; `build`: always build locally. |
| `HERMETIC_LLVM_RUNTIME_SET_DIR` | | Use an existing runtime set directory (one produced by `runtimes/build_runtimes.cmake`). |
| `HERMETIC_LLVM_RUNTIME_SETS_FILES` | | Extra JSON indexes of prebuilt runtime sets (`{"<llvm>": {"<id>": {"url": ..., "sha256": ...}}}`). |
| `HERMETIC_LLVM_RUNTIME_SANITIZERS` | `OFF` | Also build the sanitizer, fuzzer and profile runtimes into the set (needed for `-fsanitize=...` and `-fprofile-instr-generate`); adds about a minute to the build and 200 MB to the set. |
| `HERMETIC_LLVM_PIE` | `ON` | musl: `-static-pie` (`OFF`: `-static`). glibc: Clang's default PIE (`OFF`: `-no-pie`). |
| `HERMETIC_LLVM_SYSROOT` | `sdk` | macOS: the SDK (`sdk` uses `xcrun`, or a directory). Linux: a bring-your-own sysroot directory or archive URL (with `HERMETIC_LLVM_SYSROOT_SHA256`, `_STRIP_COMPONENTS`); this disables runtime sets and the sysroot must provide crt, libc, C++ library and compiler runtime itself. |
| `HERMETIC_LLVM_EMULATOR` | | Sets `CMAKE_CROSSCOMPILING_EMULATOR` (a list), so `ctest` and `try_run` work when cross-compiling. |

### Flags and behaviour

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMETIC_LLVM_USE_LLD` | `ON` | Link with LLD. |
| `HERMETIC_LLVM_REPRODUCIBLE` | `ON` | Define `__DATE__`, `__TIME__` and `__TIMESTAMP__` as `"redacted"` (hermetic-llvm's deterministic flags). |
| `HERMETIC_LLVM_EXTRA_COMPILE_FLAGS` / `_EXTRA_CXX_FLAGS` / `_EXTRA_LINK_FLAGS` / `_EXTRA_LINK_LIBS` | | Lists appended to the generated `*_INIT` flags. |
| `HERMETIC_LLVM_CACHE_DIR` | `$HERMETIC_LLVM_CACHE_DIR`, `$XDG_CACHE_HOME/hermetic-llvm`, `~/.cache/hermetic-llvm`, `%LOCALAPPDATA%/hermetic-llvm` | Where archives, sources, compilers and runtime sets live. Archives placed in `<cache>/downloads/` are used instead of downloading. |
| `HERMETIC_LLVM_KEEP_ARCHIVES` / `_KEEP_BUILD_DIRS` | `OFF` | Keep downloaded archives / runtime set build trees. |
| `HERMETIC_LLVM_SHOW_PROGRESS`, `HERMETIC_LLVM_DOWNLOAD_ARGS`, `HERMETIC_LLVM_VERBOSE` | | Download progress, extra `file(DOWNLOAD)` arguments (e.g. `NETRC;REQUIRED`), diagnostics. |

After the toolchain file runs, projects can read `HERMETIC_LLVM_ROOT`,
`HERMETIC_LLVM_BIN_DIR` (for `clang-tidy`, `clang-format`, `llvm-cov`, ...),
`HERMETIC_LLVM_RUNTIME_SET`, `HERMETIC_LLVM_SYSROOT_PATH`,
`HERMETIC_LLVM_TARGET_TRIPLE`, `HERMETIC_LLVM_EFFECTIVE_LIBC` and
`HERMETIC_LLVM_CROSSCOMPILING`.

## Runtime sets

A runtime set is a plain directory:

```
<set>/usr/include            libc headers + Linux UAPI headers
<set>/usr/include/c++/v1     libc++ headers
<set>/usr/lib                crt1.o Scrt1.o rcrt1.o crti.o crtn.o
                             glibc: libc.so.6 libm.so.6 ... (stubs), libc.so ... (linker scripts),
                                    ld-linux-*.so, libc_nonshared.a
                             musl:  libc.a and empty libm.a libpthread.a ...
                             libc++.a (with libc++abi) libc++abi.a libunwind.a
<set>/resource               clang resource directory: builtin headers,
                             lib/<triple>/libclang_rt.builtins.a, clang_rt.crtbegin.o, clang_rt.crtend.o,
                             and with HERMETIC_LLVM_RUNTIME_SANITIZERS the asan/ubsan/tsan/msan/hwasan/
                             lsan/cfi/fuzzer/profile runtimes
<set>/runtime-set.json       manifest (LLVM version, target, libc, kernel headers, components)
```

Build and package one explicitly, for example to publish it for CI:

```sh
cmake -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_LLVM_TARGET=linux-aarch64 \
      -DHERMETIC_LLVM_LIBC=gnu.2.34 -DHERMETIC_LLVM_PACKAGE=ON -P runtimes/build_runtimes.cmake
```

This writes `<cache>/packages/runtimes-23.1.0-linux-aarch64-gnu.2.34.tar.zst`
and prints the entry to add to `cmake/distributions/runtime_sets.json` (or a
file passed through `HERMETIC_LLVM_RUNTIME_SETS_FILES`) once uploaded. With
an entry present, `HERMETIC_LLVM_RUNTIMES=auto` downloads instead of
building.

The inputs and recipes come from hermetic-llvm:

- [`runtimes/glibc`](runtimes/glibc): a CMake port of its glibc rules
  (`3rd_party/libc/glibc`, `runtimes/glibc`), including its patched glibc
  files and `abilists`; the stubs are generated by the
  `glibc-stubs-generator` from its "extras" prebuilts.
- [`runtimes/musl`](runtimes/musl): a CMake port of its musl rules (and of
  musl's own Makefile).
- compiler-rt, libunwind, libc++abi and libc++ are built with LLVM's own
  `runtimes/` CMake build from the source archive hermetic-llvm mirrors
  (`llvm-redist`), against the freshly built libc.
- Header archives come from `cerisier/glibc-headers` and
  `cerisier/kernel-headers`, glibc sources from the `bminor/glibc` mirror or
  ftp.gnu.org, musl from musl.libc.org, all pinned by SHA-256 in
  [`cmake/distributions/runtime_sources.json`](cmake/distributions/runtime_sources.json).

## Tested

| Host | Target | Result |
| --- | --- | --- |
| darwin-aarch64 | darwin-aarch64 | builds and runs |
| darwin-aarch64 | linux-x86_64 gnu.2.28 | dynamic C and C++ binaries run on Debian bullseye (glibc 2.31) in Docker |
| darwin-aarch64 | linux-x86_64 musl | static-pie C and C++ binaries run in Docker |
| darwin-aarch64 | linux-aarch64 gnu.2.28 / musl | C and C++ run natively on arm64 in Docker |
| darwin-aarch64 | linux-aarch64 gnu.2.28, `-fsanitize=address` | detects a heap-buffer-overflow in Docker (amd64 ASan cannot run under the macOS Docker emulator, which kills it while mapping shadow memory) |
| any | linux-armv7, linux-riscv64, linux-s390x | recipes wired (hermetic-llvm supports them), not run |

`tests/run_tests.sh` drives the sample project through the presets in
[`tests/hello/CMakePresets.json`](tests/hello/CMakePresets.json).

## Maintenance

- `scripts/import_hermetic_llvm_data.py <hermetic-llvm checkout>` refreshes
  the compiler index, header indexes, source tables and abilists from
  upstream; `scripts/update_hermeticbuild_index.py` refreshes only the
  compiler index.
- `cmake -P tests/select_test.cmake` unit-tests version selection and libc
  parsing; `cmake -P scripts/help.cmake` lists what the tables contain;
  `scripts/prefetch.cmake` fetches and builds ahead of time.
- Bump `HERMETIC_LLVM_RUNTIME_RECIPE_VERSION` in
  `cmake/HermeticLLVMRuntimes.cmake` when the runtime recipes change, so
  cached sets are rebuilt.

## Differences from hermetic-llvm

- hermetic-llvm builds the runtimes as Bazel targets inside the consuming
  build; here they are built once per (LLVM version, target, libc) into a
  cache directory by a `cmake -P` driver, or downloaded prebuilt.
- Not ported yet: Windows targets (MinGW and MSVC), wasm and BPF targets,
  libstdc++ as an alternative C++ library, the hermetic macOS SDK download
  from Apple's CDN (its `pkgutil` is in the extras prebuilt, so it is
  feasible), and the compiler bootstrap stages.
- Sanitizer runtimes are optional (`HERMETIC_LLVM_RUNTIME_SANITIZERS`)
  rather than always built; hermetic-llvm's per-sanitizer flag groups
  (ignorelists, CFI, MSan libc++) are not reproduced, `-fsanitize=...` is
  passed by the project.
