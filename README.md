# Hermetic LLVM toolchain for CMake

A CMake toolchain file that follows the model of
[hermeticbuild/hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm):
a small prebuilt Clang/LLD, and a **runtime set** built from source with
that compiler (libc, compiler-rt, libc++) for every Linux target, so that
cross-compiling needs no distribution sysroot at all. Linux targets pick
the glibc version to link against (2.28 to 2.44, via headers plus symbol
stubs, the same technique as Zig and hermetic-llvm) or musl (fully static
binaries). macOS targets use an SDK, Windows targets (MSVC ABI) use the
MSVC toolset and Windows SDK downloaded from Microsoft, with the MSVC STL or
a libc++ built from source. Any host builds for any target.

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

## Hosts and targets

The compiler prebuilt exists for six hosts; every host can build for every
target. Runtime sets and Windows toolsets are downloaded or built the same
way everywhere, only macOS targets need an SDK, which comes from Xcode on a
macOS host and has to be supplied by hand elsewhere.

| Host ↓ \ Target → | Linux (`linux-x86_64`, `linux-aarch64`, `linux-armv7`, `linux-riscv64`, `linux-s390x`; glibc or musl) | macOS (`darwin-x86_64`, `darwin-aarch64`) | Windows (`windows-x86_64`, `windows-aarch64`; MSVC STL or libc++) |
| --- | :---: | :---: | :---: |
| Linux x86_64 | ✓ | ✓ with a supplied SDK | ✓ |
| Linux arm64 | ✓ | ✓ with a supplied SDK | ✓ |
| macOS x86_64 | ✓ | ✓ | ✓ |
| macOS arm64 | ✓ | ✓ | ✓ |
| Windows x86_64 | ✓ | ✓ with a supplied SDK | ✓ |
| Windows arm64 | ✓ | ✓ with a supplied SDK | ✓ |

"With a supplied SDK" means `HERMETIC_LLVM_SYSROOT` must point at a macOS SDK
directory; nothing else differs. `HERMETIC_LLVM_TARGET` defaults to the
host's own platform. Which combinations CI exercises is listed under
[Testing and CI](#testing-and-ci).

Host notes:

- **Linux**: the compiler prebuilt is statically linked against musl and
  runs on any distribution; no distribution packages are needed beyond
  CMake and Ninja. Docker with QEMU registered is only used by the test
  suite to run cross-compiled binaries.
- **macOS**: Xcode or the Command Line Tools provide the SDK for macOS
  targets (`xcrun --show-sdk-path`); nothing from them is used for other
  targets.
- **Windows**: no Visual Studio, MSYS or WSL. The compiler prebuilt is
  hermetic-llvm's MinGW-built one, the MSVC toolset and Windows SDK are
  downloaded like on the other hosts, and the test scripts run under Git
  Bash. Keep the cache directory short (`HERMETIC_LLVM_CACHE_DIR=C:/hl`) to
  stay clear of path length limits; a Windows libc++ runtime set builds
  libc++ four times, one per C runtime flavour, so it takes a few minutes
  longer than a Linux set.

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
4. **Windows targets** (MSVC ABI) use `clang-cl` and `lld-link` with a MSVC
   toolset and a Windows SDK downloaded from Microsoft, the MSVC STL by
   default or a libc++ runtime set, and optionally the sanitizer runtimes.
   See [Windows targets](#windows-targets).
5. **CMake configuration**: compilers, binutils, `CMAKE_SYSTEM_NAME`,
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

- CMake 3.19 or newer, and Ninja to build runtime sets.
- A Linux, macOS or Windows host, x86_64 or arm64; see the host notes above
  for what each one needs.
- Disk: about 3 GB for the extracted LLVM sources plus 100 to 300 MB per
  runtime set built locally.

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
| `HERMETIC_LLVM_TARGET` | host | `linux-x86_64`, `linux-aarch64`, `linux-armv7`, `linux-riscv64`, `linux-s390x`, `darwin-x86_64`, `darwin-aarch64`, `windows-x86_64`, `windows-aarch64`; see [Hosts and targets](#hosts-and-targets). |
| `HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA` | | Must be `1` for Windows targets: confirms you may use the MSVC runtime and Windows SDK (see https://visualstudio.microsoft.com/license-terms/). Also read from the environment. |
| `HERMETIC_LLVM_MSVC_VERSION` | `14.50.35717` | MSVC toolset for Windows targets: an exact version from the table (14.29 through 14.51, i.e. Visual Studio 2019 to 2026), or `latest`. |
| `HERMETIC_LLVM_WINDOWS_SDK_VERSION` | `10.0.26100.7705` | Windows SDK for Windows targets: an exact NuGet version, a build prefix (`10.0.22621` selects its newest listed version), or `latest`. `cmake -DTOPIC=windows -P scripts/help.cmake` lists both tables. |
| `HERMETIC_LLVM_LIBC` | `gnu.2.28` | Linux libc: `gnu.<version>` (2.28 to 2.44) or `musl`. The runtime set id is `<target>-<libc>`. |
| `HERMETIC_LLVM_CXX_STDLIB` | `libc++` (Windows: `msvc`) | C++ standard library. Linux targets always use the runtime set's libc++, macOS the SDK's. Windows targets: `msvc` for the toolset's STL, or `libc++` for a static libc++ on the Microsoft ABI built into the runtime set `<target>-msvc.<toolset version>`. |
| `HERMETIC_LLVM_RUNTIMES` | `auto` | `auto`: use a prebuilt runtime set when the index lists one, else build it; `download`: fail if none is listed; `build`: always build locally. |
| `HERMETIC_LLVM_RUNTIME_SET_DIR` | | Use an existing runtime set directory (one produced by `runtimes/build_runtimes.cmake`). |
| `HERMETIC_LLVM_RUNTIME_SETS_FILES` | | Extra JSON indexes of prebuilt runtime sets (`{"<llvm>": {"<id>": {"url": ..., "sha256": ...}}}`). |
| `HERMETIC_LLVM_RUNTIME_SANITIZERS` | `OFF` | Also build the sanitizer, fuzzer and profile runtimes into the set (needed for `-fsanitize=...` and `-fprofile-instr-generate`); adds about a minute to the build and 200 MB to the set. Windows: ASan, UBSan, libFuzzer and profile, see [Sanitizers](#sanitizers). |
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
`HERMETIC_LLVM_TARGET_TRIPLE`, `HERMETIC_LLVM_EFFECTIVE_LIBC`,
`HERMETIC_LLVM_EFFECTIVE_CXX_STDLIB`, `HERMETIC_LLVM_CROSSCOMPILING` and, on
Windows hosts building Windows targets, `HERMETIC_LLVM_WINDOWS_SDK_TOOLS_DIR`.

## Windows targets

Windows targets follow hermetic-llvm's `windows_msvc` route: the MSVC ABI
with `clang-cl` and `lld-link`, no MinGW.

**Toolset and SDK.** The MSVC toolset (C runtime and STL headers and
libraries) comes from the Visual Studio installer manifest and the Windows
SDK from its public NuGet packages, both pinned by URL and hash in
[`cmake/distributions/windows.json`](cmake/distributions/windows.json).
Every toolset of the pinned manifest (14.29 through 14.51, Visual Studio
2019 to 2026) and the newest NuGet package of each SDK build are listed;
`HERMETIC_LLVM_MSVC_VERSION` and `HERMETIC_LLVM_WINDOWS_SDK_VERSION` select
them, and `cmake -DTOPIC=windows -P scripts/help.cmake` prints the tables.
These packages carry Microsoft licenses, so `HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA=1`
(variable or environment) must confirm entitlement before anything is
downloaded. The toolset and SDK are handed to the driver as `/vctoolsdir`,
`/winsdkdir` and `/winsdkversion`, so it never looks for a Visual Studio
installation or at `INCLUDE`/`LIB` on Windows hosts, and a case-insensitive
Clang VFS overlay lets the SDK's mixed-case file names resolve on
case-sensitive filesystems.

**SDK tools.** The SDK package also carries Microsoft's tools (`midl`, `mc`,
`rc`, `mt`, `signtool`, `makecat`, `makeappx`, `makepri`, `dxc`, `fxc`, the
WPP/ETW tracing tools, ...), Windows executables with no LLVM counterpart
apart from `rc` and `mt`. On a Windows host the ones for the host
architecture are extracted and their directory exported as
`HERMETIC_LLVM_WINDOWS_SDK_TOOLS_DIR` for custom commands; the toolchain
itself keeps using `llvm-rc`, and `llvm-mt` once a prebuilt with libxml2 is
available, so that outputs stay identical to those of Linux and macOS
hosts. On those hosts the variable is empty; mingw-w64's `widl` and `wmc`
cover classic COM IDL and message tables there, `dxc` has native builds,
and signing or packaging belong outside the hermetic build.

**Linking.** Executables and DLLs are linked through the `clang-cl` driver,
which runs `lld-link`, rather than through `lld-link` directly, so that
sanitized links get everything the driver adds from the compile flags. The
consequences for a project: `-fsanitize=...` belongs in the compile flags
(`HERMETIC_LLVM_EXTRA_COMPILE_FLAGS` or `CMAKE_<LANG>_FLAGS`), which the
link step receives as well, while `CMAKE_EXE_LINKER_FLAGS`, `LINK_OPTIONS`
and friends keep CMake's usual MSVC-style linker spelling. Static libraries
are created with `llvm-ar` (the prebuilt has no `llvm-lib`) and executables
get no manifest (`/MANIFEST:NO`, since `llvm-mt` is built without libxml2).

**C++ library.** By default the MSVC STL from the toolset. With
`HERMETIC_LLVM_CXX_STDLIB=libc++` a runtime set `<target>-msvc.<toolset>` is
built instead: libc++ as a static library on the Microsoft ABI (vcruntime
is the C++ ABI library, no libc++abi or libunwind, win32 threads) plus
compiler-rt builtins, compiled with `clang-cl` against the selected toolset
and SDK. Its headers are searched before the toolset's, and consumers get
`_CRT_STDIO_ISO_WIDE_SPECIFIERS` defined because libc++ is built with it and
the UCRT rejects objects that disagree. The libc++ sources get
hermetic-llvm's `libcxx-vcruntime-nothrow.patch`, since `std::nothrow`
belongs to the C runtime on this ABI.

**C runtime flavours.** CMake's `CMAKE_MSVC_RUNTIME_LIBRARY` and the
per-target `MSVC_RUNTIME_LIBRARY` property work unchanged, per
configuration. libc++ is built once per flavour (`/MD`, `/MDd`, `/MT`,
`/MTd`, as `lib/libc++-{md,mdd,mt,mtd}.lib`) and a force-included header
names the matching archive for each translation unit through a
default-library directive, the way the MSVC STL selects msvcprt or libcpmt.

**Sanitizers.** `HERMETIC_LLVM_RUNTIME_SANITIZERS=ON` adds what compiler-rt
supports on Windows to the runtime set (which is then built even with the
MSVC STL): AddressSanitizer, UndefinedBehaviorSanitizer, libFuzzer and the
profile runtime; no TSan, MSan or LSan. Things to know:

- Windows ASan is a DLL runtime, `clang_rt.asan_dynamic-<arch>.dll` in the
  set's resource directory; it must sit next to the executable or on `PATH`.
- clang-cl refuses ASan together with the debug CRT, so Debug configurations
  need `CMAKE_MSVC_RUNTIME_LIBRARY` set to a release flavour (try_compile
  checks already use Release for this reason).
- With the MSVC STL its ASan container annotations are disabled
  (`_DISABLE_STL_ANNOTATION`), because the `stl_asan.lib` they need only
  ships in Visual Studio's own ASan package; overflow checks inside
  `std::string` and `std::vector` are lost there, libc++ keeps its own.
- Per-target sanitizer flags do not reach the link step (only the global
  compile flags do), so a fuzz target is built with
  `target_compile_options(t PRIVATE -fsanitize=fuzzer)` plus
  `target_link_options(t PRIVATE /wholearchive:clang_rt.fuzzer-<arch>.lib)`.
- Sanitizer objects are compiled CRT-neutral (`/Zl`), so the consumer's
  runtime flavour decides which CRT is linked.

**Reproducibility.** Windows binaries built on Linux, macOS and Windows
hosts are byte-identical, including the ASan DLL, which is linked without
a PDB, and so are the runtime sets. Sanitized program binaries are not,
because ASan records each module's source path and UBSan its check
locations (including SDK header paths in the cache) and clang's prefix-map
options cover neither; the CI identity check reports those. The sanitizer
runtimes in a set are built without debug info (compiler-rt insists on
`/Z7` for them): on a Windows host clang joins the mapped include paths in
the CodeView records with backslashes, which made the archives depend on
the build host. The CodeView object-name record, which would otherwise
hold each object's absolute path on every host, is left blank everywhere.

PDBs are deterministic too. lld-link records its own path, the path of
every library it resolved and its whole command line in the PDB, and no
option remaps them, so with `HERMETIC_LLVM_REPRODUCIBLE` the toolchain
links through relative paths instead: every build directory (try-compile
directories included) gets a link named `hermetic-llvm` to the cache
directory (a symbolic link, or a directory junction on Windows hosts),
the cache gets a host-neutral `llvm/<version>` link to the compiler, and
the link command names the toolset, SDK, runtime set and `lld-link` itself
through them. With a project-chosen `/pdbsourcepath:` (the sample uses
`/build`) the PDB then records `/build/hermetic-llvm/...` everywhere, and
the executable, which embeds the PDB's GUID, matches too. Compilation keeps
absolute paths; the prefix map covers those. The link is only created
for Windows targets and only supports the Ninja generators, whose commands
run from the build directory.

Not ported from hermetic-llvm: MinGW targets and the static-CRT variants
of its Windows sanitizer route beyond what is described above.

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

A Windows (libc++) runtime set, `<target>-msvc.<toolset version>`, holds:

```
<set>/include/c++/v1         libc++ headers (Microsoft ABI configuration)
<set>/include/__hermetic_llvm_libcxx_link.h   force-included: selects the archive for the TU's CRT flavour
<set>/lib/libc++-{md,mdd,mt,mtd}.lib          static libc++ per C runtime flavour (vcruntime is the ABI library)
<set>/resource               builtin headers and lib/windows/clang_rt.builtins-<arch>.lib, and with
                             HERMETIC_LLVM_RUNTIME_SANITIZERS the asan (DLL + thunks), ubsan, fuzzer
                             and profile runtimes
<set>/runtime-set.json       manifest (LLVM version, target, toolset and SDK versions, components)
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
  (`llvm-redist`), against the freshly built libc. hermetic-llvm's source
  patches that matter here are applied as text replacements after
  extraction (`hermetic_llvm_patch_llvm_source`): currently only
  `libcxx-vcruntime-nothrow.patch`, which stops libc++ from defining
  `std::nothrow` on the Microsoft ABI where the C runtime owns it.
- Header archives come from `cerisier/glibc-headers` and
  `cerisier/kernel-headers`, glibc sources from the `bminor/glibc` mirror or
  ftp.gnu.org, musl from musl.libc.org, all pinned by SHA-256 in
  [`cmake/distributions/runtime_sources.json`](cmake/distributions/runtime_sources.json).

## Testing and CI

[![Tests](https://github.com/Orphis/hermetic-llvm-cmake/actions/workflows/tests.yml/badge.svg)](https://github.com/Orphis/hermetic-llvm-cmake/actions/workflows/tests.yml)
[![Nightly](https://github.com/Orphis/hermetic-llvm-cmake/actions/workflows/nightly.yml/badge.svg)](https://github.com/Orphis/hermetic-llvm-cmake/actions/workflows/nightly.yml)

`tests/run_tests.sh` drives the sample project in [`tests/hello`](tests/hello)
through the presets in
[`tests/hello/CMakePresets.json`](tests/hello/CMakePresets.json): it
configures and builds each preset, checks the architecture of the
result, and when Docker is available runs the binaries in a Debian container
for the target platform (foreign architectures need QEMU registered with
Docker; `HERMETIC_TESTS_REQUIRE_DOCKER=1` fails instead of skipping,
`HERMETIC_TESTS_SKIP_DOCKER=1` never executes). glibc presets run on the
Debian release matching their version, and `gnu.2.4x` binaries are
additionally checked to be refused by an older release, proving the version
pinning. `cmake -P tests/select_test.cmake` unit-tests version selection and
libc parsing.

Two GitHub Actions workflows run this, each in two stages: every host
builds its presets and uploads the binaries, then one job per execution
environment (Linux x86_64 and arm64 runners, QEMU for the other Linux
architectures, macOS x86_64 and arm64, Windows x86_64 and arm64 runners)
downloads every binary for its platform, whatever host built it, and runs
them:

- [`tests.yml`](.github/workflows/tests.yml), on every push and pull request
  (about 15 minutes end to end): tables and selection checks, then native
  and cross builds on Ubuntu x86_64, Ubuntu arm64, macOS arm64 and Windows
  x86_64, covering glibc, musl and the MSVC STL and libc++ Windows targets
  with ASan. Each job builds at most a few runtime sets from source.
- [`nightly.yml`](.github/workflows/nightly.yml), daily and on demand
  (`gh workflow run nightly.yml`, optionally with `-f presets="..."` to run
  chosen presets on every job): the glibc version sweep (2.28, 2.34, 2.44)
  on x86_64 and aarch64 with the negative check, ASan and UBSan on Linux
  and Windows, armv7, riscv64 and s390x (glibc and musl) under QEMU,
  compiler version selection (`latest`, `21.1.8`, `first:>=22`), macOS
  x86_64 native and `darwin-x86_64` cross, every Windows preset from the
  Windows x86_64 host (one job per runtime set), from a Windows arm64 host
  and from Linux, and a cold-start job provisioning a target with
  sanitizers from an empty cache in one invocation.

Coverage of the hosts-and-targets table: every push builds all Linux
targets from every host, Windows targets from every host, and macOS targets
on macOS hosts (arm64 native; x86_64 native and the `darwin-x86_64` cross
build nightly). Only a Windows arm64 host runs nightly rather than per push,
and two combinations have no runner at all: macOS targets from non-macOS
hosts (which need a supplied SDK) and `darwin-aarch64` cross-built from a
macOS x86_64 host. Everything a job builds is executed on a runner, or under
Docker/QEMU, of the target platform.

Both workflows cache only `~/.cache/hermetic-llvm/downloads` (about 250 MB,
mostly the LLVM source archive) and rebuild runtime sets every time, which
keeps them honest about the from-source path; a set takes one to three
minutes on GitHub's runners. Build logs are uploaded as artifacts on failure.

The run stage also hashes every binary and fails when the same preset built
on different hosts differs (`HERMETIC_TESTS_ENFORCE_REPRODUCIBLE=1`). It
hashes the program binaries, the runtime set's archives (libc++, libunwind,
the builtins, libc pieces and, for sanitized presets, the sanitizer
runtimes) and the PDBs of the Windows debug presets. Runtime sets are built to be
host-independent: every stage compiles with `-ffile-prefix-map` for the
cache, source, build and repository directories, defines `__FILE__` as
`__FILE_NAME__` (Clang on a Windows host joins include paths with
backslashes, which `-ffile-reproducible` does not undo), blanks CodeView's
object-name record and builds libunwind and libc++abi without assertions
(glibc 2.44's `assert` reads the file name through `__builtin_FILE()`,
which no prefix map covers). The `-dbg` presets build the sample with debug
information, mapping its source and build directories to fixed names (the
toolchain maps the cache directory for every build when
`HERMETIC_LLVM_REPRODUCIBLE` is on), so debug info is measured too.

Result: release and debug binaries built on Linux x86_64, Linux arm64,
macOS and Windows hosts are byte-identical, PDBs included (see
Reproducibility under Windows targets). Three kinds of difference are
reported but not enforced: sanitized program binaries (ASan and UBSan
embed source paths that no prefix map covers); macOS binaries built
against different SDK versions (the SDK is the host's Xcode, not a
hermetic input, and the sample records the version so the check can
tell); and debug info or PDBs built on a Windows host (the
backslash-joined include paths), where only the Windows builds may deviate
and every other host must still agree. The sample pins
`CMAKE_OSX_DEPLOYMENT_TARGET`, since an unset one follows the SDK version
into the binary. Publishing prebuilt runtime sets is still to come.

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
- Not ported yet: MinGW targets, wasm and BPF targets, libstdc++ as an
  alternative C++ library, the hermetic macOS SDK download from Apple's CDN
  (its `pkgutil` is in the extras prebuilt, so it is feasible), and the
  compiler bootstrap stages.
- Sanitizer runtimes are optional (`HERMETIC_LLVM_RUNTIME_SANITIZERS`)
  rather than always built; hermetic-llvm's per-sanitizer flag groups
  (ignorelists, CFI, MSan libc++) are not reproduced, `-fsanitize=...` is
  passed by the project.
