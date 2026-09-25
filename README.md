# Hermetic C/C++ toolchain for CMake

A CMake toolchain file that follows the model of
[hermeticbuild/hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm):
a small prebuilt Clang/LLD, and a **runtime set** built from source with
that compiler (libc, compiler-rt, libc++) for every Linux target, so that
cross-compiling needs no distribution sysroot at all. Linux targets pick
the glibc version to link against (2.28 to 2.44, via headers plus symbol
stubs, the same technique as Zig and hermetic-llvm) or musl (fully static
binaries). macOS targets use the macOS SDK downloaded from Apple, Windows
targets (MSVC ABI) use the MSVC toolset and Windows SDK downloaded from
Microsoft, with the MSVC STL or a libc++ built from source, and freestanding
WebAssembly targets get the compiler-rt builtins. Any host builds for any
target.

```sh
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/hermetic-cpp-cmake/toolchain.cmake \
  -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_TARGET=linux-aarch64 -DHERMETIC_LIBC=musl
cmake --build build
```

Or with a preset:

```json
{
  "name": "linux-aarch64-musl",
  "generator": "Ninja",
  "toolchainFile": "${sourceDir}/third_party/hermetic-cpp-cmake/toolchain.cmake",
  "cacheVariables": {
    "HERMETIC_LLVM_VERSION": "23.1.0",
    "HERMETIC_TARGET": "linux-aarch64",
    "HERMETIC_LIBC": "musl"
  }
}
```

## Hosts and targets

The compiler prebuilt exists for six hosts; every host can build for every
target. Runtime sets, Windows toolsets and the macOS SDK are downloaded or
built the same way everywhere.

| Host ↓ \ Target → | Linux (`linux-x86_64`, `linux-aarch64`, `linux-armv7`, `linux-riscv64`, `linux-s390x`; glibc or musl) | macOS (`darwin-x86_64`, `darwin-aarch64`) | Windows (`windows-x86_64`, `windows-aarch64`; MSVC ABI with the MSVC STL or libc++, or GNU ABI with MinGW-w64) | WebAssembly (`wasm32`, `wasm64`; freestanding) |
| --- | :---: | :---: | :---: | :---: |
| Linux x86_64 | ✓ | ✓ | ✓ | ✓ |
| Linux arm64 | ✓ | ✓ | ✓ | ✓ |
| macOS x86_64 | ✓ | ✓ | ✓ | ✓ |
| macOS arm64 | ✓ | ✓ | ✓ | ✓ |
| Windows x86_64 | ✓ | ✓ ¹ | ✓ | ✓ |
| Windows arm64 | ✓ | ✓ ¹ | ✓ | ✓ |

¹ Expanding the macOS SDK creates symbolic links, which Windows only lets
administrators or users with Developer Mode create; see
[macOS targets](#macos-targets). `HERMETIC_TARGET` defaults to the
host's own platform. Which combinations CI exercises is listed under
[Testing and CI](#testing-and-ci).

Host notes:

- **Linux**: the compiler prebuilt is statically linked against musl and
  runs on any distribution; no distribution packages are needed beyond
  CMake and Ninja. Docker with QEMU registered is only used by the test
  suite to run cross-compiled binaries.
- **macOS**: nothing from Xcode is needed. `HERMETIC_SYSROOT=host`
  uses the SDK of the installed Xcode or Command Line Tools
  (`xcrun --show-sdk-path`) instead of the downloaded one.
- **Windows**: no Visual Studio, MSYS or WSL. The compiler prebuilt is
  hermetic-llvm's MinGW-built one, the MSVC toolset and Windows SDK are
  downloaded like on the other hosts, and the test scripts run under Git
  Bash. Keep the cache directory short (`HERMETIC_CACHE_DIR=C:/hl`) to
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
3. **macOS targets** use the macOS SDK downloaded from Apple's Command
   Line Tools package (or the host's Xcode SDK, or any SDK directory, via
   `HERMETIC_SYSROOT`) with the SDK's libc++. See
   [macOS targets](#macos-targets).
4. **Windows targets** on the MSVC ABI use `clang-cl` and `lld-link` with a MSVC
   toolset and a Windows SDK downloaded from Microsoft, the MSVC STL by
   default or a libc++ runtime set, and optionally the sanitizer runtimes.
   On the GNU ABI (`HERMETIC_WINDOWS_ABI=gnu`) they use the plain
   `clang` driver with MinGW-w64 built from source into a runtime set, like
   hermetic-llvm's default Windows platforms, and nothing from Microsoft.
   See [Windows targets](#windows-targets).
5. **WebAssembly targets** are freestanding, like hermetic-llvm's: no libc
   and no operating system, a module that exports functions to a host
   runtime. The runtime set `<target>-none` holds the compiler-rt builtins.
   See [WebAssembly targets](#webassembly-targets).
6. **CMake configuration**: compilers, binutils, `CMAKE_SYSTEM_NAME`,
   `CMAKE_<LANG>_COMPILER_TARGET`, `CMAKE_SYSROOT` (the runtime set), LLD,
   `-resource-dir`, `-rtlib=compiler-rt`, static libc++ and the link mode.
   Whenever a runtime set is used, also for a native Linux build, the
   `CMAKE_FIND_ROOT_PATH_MODE_*` variables are set to `ONLY` (`NEVER` for
   programs) so `find_package` and friends cannot pick up host headers or
   libraries; set them yourself before the toolchain runs to override.

Everything lives in one cache directory (`~/.cache/hermetic-cpp` by
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
| `HERMETIC_LLVM_RELEASE` | | Pin a hermetic-llvm release id (`llvm-23.1.0-4`) instead of a version. |
| `HERMETIC_LLVM_HERMETICBUILD_INDEX` | | Another copy of the compiler index (same schema). |
| `HERMETIC_LLVM_DISTRIBUTION_URL` / `_SHA256` / `_STRIP_COMPONENTS` | | Bring your own compiler archive (`bin/clang` at the root, or set the strip count). |
| `HERMETIC_MIRROR_URLS` | | URL templates tried after the primary URL; `{version}`, `{release}` and `{basename}` are substituted. |
| `HERMETIC_COMPILER` | `llvm` | `llvm` (clang from the prebuilt, every host and target) or `msvc` (Microsoft's `cl.exe` from the toolset packages, Windows hosts building Windows targets on the MSVC ABI with the MSVC STL; lld-link and the LLVM tools still link, archive and handle resources). See [Windows targets](#windows-targets). |

### Target, libc and runtimes

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMETIC_TARGET` | host | `linux-x86_64`, `linux-aarch64`, `linux-armv7`, `linux-riscv64`, `linux-s390x`, `darwin-x86_64`, `darwin-aarch64`, `windows-x86_64`, `windows-aarch64`, `wasm32`, `wasm64`; see [Hosts and targets](#hosts-and-targets). |
| `HERMETIC_WINDOWS_ABI` | `msvc` | Windows targets: `msvc` (clang-cl, the Microsoft runtime and SDK) or `gnu` (MinGW-w64 with UCRT, built from source into the runtime set `<target>-mingw`; no Microsoft download, libc++ only, no sanitizers). |
| `HERMETIC_ACCEPT_MICROSOFT_EULA` | | Must be `1` for Windows targets on the MSVC ABI: confirms you may use the MSVC runtime and Windows SDK (see https://visualstudio.microsoft.com/license-terms/). Also read from the environment. |
| `HERMETIC_MSVC_TOOLSET_VERSION` | `14.50.35717` | MSVC toolset for Windows targets: an exact version from the table (14.29 through 14.51, i.e. Visual Studio 2019 to 2026), or `latest`. |
| `HERMETIC_WINDOWS_SDK_VERSION` | `10.0.26100.7705` | Windows SDK for Windows targets: an exact NuGet version, a build prefix (`10.0.22621` selects its newest listed version), or `latest`. `cmake -DTOPIC=windows -P scripts/help.cmake` lists both tables. |
| `HERMETIC_LIBC` | `gnu.2.28` | Linux libc: `gnu.<version>` (2.28 to 2.44) or `musl`. The runtime set id is `<target>-<libc>`. |
| `HERMETIC_CXX_STDLIB` | `libc++` (Windows: `msvc`) | C++ standard library. Linux targets always use the runtime set's libc++, macOS the SDK's. Windows targets: `msvc` for the toolset's STL, or `libc++` for a static libc++ on the Microsoft ABI built into the runtime set `<target>-msvc.<toolset version>`. |
| `HERMETIC_LLVM_RUNTIMES` | `auto` | `auto`: use a prebuilt runtime set when the index lists one, else build it; `download`: fail if none is listed; `build`: always build locally. |
| `HERMETIC_LLVM_RUNTIME_SET_DIR` | | Use an existing runtime set directory (one produced by `runtimes/build_runtimes.cmake`). |
| `HERMETIC_LLVM_RUNTIME_SETS_FILES` | | Extra JSON indexes of prebuilt runtime sets (`{"<llvm>": {"<id>": {"url": ..., "sha256": ...}}}`). |
| `HERMETIC_LLVM_RUNTIME_SANITIZERS` | `OFF` | Also build the sanitizer, fuzzer and profile runtimes into the set (needed for `-fsanitize=...` and `-fprofile-instr-generate`); adds about a minute to the build and 200 MB to the set. Windows: ASan, UBSan, libFuzzer and profile, see [Sanitizers](#sanitizers). |
| `HERMETIC_PIE` | `ON` | musl: `-static-pie` (`OFF`: `-static`). glibc: Clang's default PIE (`OFF`: `-no-pie`). |
| `HERMETIC_SYSROOT` | `sdk` | macOS: `sdk` downloads the SDK (see the next two rows), `host` uses the SDK of the host's Xcode or Command Line Tools (macOS hosts only), or a directory names any SDK. Linux: a bring-your-own sysroot directory or archive URL (with `HERMETIC_SYSROOT_SHA256`, `_STRIP_COMPONENTS`); this disables runtime sets and the sysroot must provide crt, libc, C++ library and compiler runtime itself. |
| `HERMETIC_ACCEPT_APPLE_SDK_LICENSE` | | Must be `1` for macOS targets unless `HERMETIC_SYSROOT` names an SDK: confirms you may use the macOS SDK (the Xcode and Apple SDKs Agreement, https://www.apple.com/legal/sla/docs/xcode.pdf). Also read from the environment. |
| `HERMETIC_MACOS_SDK_VERSION` | `27.0` | macOS SDK for macOS targets: an exact version from the table (10.15 to 27.0), a major (`15` selects its newest listed version), or `latest`. The default and `latest` skip SDKs the compiler cannot link against (26.5 with prebuilts older than `llvm-23.1.0-4`). `cmake -DTOPIC=macos -P scripts/help.cmake` lists the table. |
| `HERMETIC_EMULATOR` | | Sets `CMAKE_CROSSCOMPILING_EMULATOR` (a list), so `ctest` and `try_run` work when cross-compiling. |

### Flags and behaviour

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMETIC_USE_LLD` | `ON` | Link with LLD. |
| `HERMETIC_REPRODUCIBLE` | `ON` | Define `__DATE__`, `__TIME__` and `__TIMESTAMP__` as `"redacted"` (hermetic-llvm's deterministic flags), record the working directory in debug info as `.` and map the cache directory to a fixed name (see [Remote execution](#remote-execution)). |
| `HERMETIC_EXTRA_COMPILE_FLAGS` / `_EXTRA_CXX_FLAGS` / `_EXTRA_LINK_FLAGS` / `_EXTRA_LINK_LIBS` | | Lists appended to the generated `*_INIT` flags. |
| `HERMETIC_CACHE_DIR` | `$HERMETIC_CACHE_DIR`, `$XDG_CACHE_HOME/hermetic-cpp`, `~/.cache/hermetic-cpp`, `%LOCALAPPDATA%/hermetic-cpp` | Where archives, sources, compilers and runtime sets live. Archives placed in `<cache>/downloads/` are used instead of downloading. |
| `HERMETIC_KEEP_ARCHIVES` / `_KEEP_BUILD_DIRS` | `OFF` | Keep downloaded archives / runtime set build trees. |
| `HERMETIC_SHOW_PROGRESS`, `HERMETIC_DOWNLOAD_ARGS`, `HERMETIC_VERBOSE` | | Download progress, extra `file(DOWNLOAD)` arguments (e.g. `NETRC;REQUIRED`), diagnostics. |

After the toolchain file runs, projects can read `HERMETIC_LLVM_ROOT`,
`HERMETIC_LLVM_BIN_DIR` (for `clang-tidy`, `clang-format`, `llvm-cov`, ...),
`HERMETIC_LLVM_RUNTIME_SET`, `HERMETIC_SYSROOT_PATH`,
`HERMETIC_TARGET_TRIPLE`, `HERMETIC_EFFECTIVE_LIBC`,
`HERMETIC_EFFECTIVE_CXX_STDLIB`, `HERMETIC_CROSSCOMPILING` and, on
Windows hosts building Windows targets, `HERMETIC_WINDOWS_SDK_TOOLS_DIR`.

## macOS targets

The macOS SDK comes from Apple's software update CDN, without an Apple
account: the Command Line Tools ship their SDK as a separate package
(`CLTools_macOSNMOS_SDK.pkg`, about 60 MB), which the toolchain downloads
and expands with `pkgutil` from hermetic-llvm's extras prebuilt (a
cross-platform reimplementation, so Linux and Windows hosts do it too) into
`<cache>/macos/MacOSX<version>.sdk`, about 1 GB. The SDK is then a pinned
input like everything else, and a macOS binary comes out identical whether
it was built on a Mac or on a Linux or Windows host. Every SDK version
Apple's catalog has carried since 2021 is listed in
`cmake/distributions/macos_sdk.json` (10.15 through 27.0), and
`scripts/update_macos_sdk.cmake` adds new ones as they appear.

`HERMETIC_SYSROOT=host` keeps the previous behaviour on a macOS host
(the SDK of the installed Xcode or Command Line Tools, via `xcrun`), which
needs no license confirmation; a directory names any SDK. The sample
project pins `CMAKE_OSX_DEPLOYMENT_TARGET`, since the default follows the
SDK version.

Notes:

- Two host differences are papered over so that debug builds and shared
  libraries match across hosts too: the compiler's own directory (named
  after the host, and the source of the builtin headers that macOS
  targets, having no runtime set, record in their debug info) gets its own
  prefix map, and CMake before 4.1 is given the runtime path flag it only
  derives from a macOS host, without which a shared library gets its build
  directory as install name instead of `@rpath`; on a Windows host CMake's
  Ninja generator also writes that install name with a backslash, which the
  link rules undo.
- The 27.0 SDK's library stubs list `arm64e.x1` targets, which only newer
  linkers read (`llvm-23.1.0-4` and later prebuilts). The table records
  such requirements, and the toolchain asks the compiler's `llvm-readtapi`
  (the same TextAPI reader as `ld64.lld`) whether it reads them: the
  default then falls back to the newest SDK the compiler can use, while
  asking for 27.0 explicitly with an older compiler is an error.
- Only macOS SDKs are served this way. The iOS, tvOS, watchOS and visionOS
  SDKs ship inside Xcode, which Apple only serves to signed-in developers,
  so those targets stay out of reach of a hermetic download.
- The SDK holds about 7,500 symbolic links (framework `Versions/Current`,
  library stubs). Windows lets only administrators, or users with Developer
  Mode enabled, create them, so on a Windows host without either the
  extraction fails with a message saying so
  ([hermetic-llvm#517](https://github.com/hermeticbuild/hermetic-llvm/issues/517));
  Dev Drives (ReFS) mishandle directory symlinks created without the
  directory flag, which `pkgutil` does not set yet
  ([#580](https://github.com/hermeticbuild/hermetic-llvm/issues/580)).

## WebAssembly targets

`wasm32` and `wasm64` (`wasm32-unknown-unknown`, `wasm64-unknown-unknown`)
are freestanding, as in hermetic-llvm: no libc, no C++ standard library, no
operating system interface. A build produces WebAssembly modules (`*.wasm`,
CMake's `Generic` platform, so no shared libraries) whose exported
functions a host runtime calls. The toolchain links with `-nostdlib` and
`--no-entry`, and adds the compiler-rt builtins from the runtime set
`<target>-none` (the only thing it holds besides the compiler's builtin
headers; it builds in a minute), which cover what the code generator calls
out to, such as 128-bit multiplication. Functions are exported with
`__attribute__((export_name("name")))` or `-Wl,--export=name`; imports
from the host need `-Wl,--allow-undefined` (or `__attribute__((import_name))`).
C++ works without the standard library: templates, classes and constexpr,
but no exceptions, RTTI-based features or containers. The sample
(`tests/hello/wasm_add.c`, `wasm_mul.cpp`) is run under Node.js by the
tests; `wasm64` needs Node.js 24 or newer (memory64).

A WASI target (wasi-libc plus libc++, `main` and files) would be the next
step and is not there yet, nor are wasm shared libraries.

## Windows targets

Windows targets come in two ABIs. The GNU ABI (`HERMETIC_WINDOWS_ABI=gnu`,
hermetic-llvm's default Windows platforms) builds
[mingw-w64](https://www.mingw-w64.org/) 14.0.0 from source into the runtime
set `<target>-mingw`: its headers, CRT libraries and start files, the
import libraries of the system DLLs generated from mingw-w64's definition
files with `llvm-dlltool`, and winpthreads, all under
`<set>/<arch>-w64-mingw32` where clang's MinGW driver looks for them, plus
the compiler-rt builtins and a static libc++ (win32 threads, libc++abi and
libunwind merged in). The C runtime is the UCRT, as in mingw-w64's own
`--with-default-msvcrt=ucrt` layout (`libmsvcrt.a` is the UCRT), Windows 10
is the default `_WIN32_WINNT`, and the plain `clang` driver links with
`-rtlib=compiler-rt --unwindlib=libunwind -stdlib=libc++` through lld's
MinGW driver, with CMake's GNU-style Windows rules (`libfoo.dll` with a
`libfoo.dll.a` import library, `llvm-windres` for resources). mingw-w64's
autotools build needs a shell, which Windows hosts do not have, so the CRT
is compiled by `runtimes/mingw/CMakeLists.txt` from the source lists in
`runtimes/mingw/sources.cmake`, after hermetic-llvm's translation of
`mingw-w64-crt/Makefile.am`. `libmoldname.a` and `libm.a` are empty, as
there. Nothing is downloaded from Microsoft, so no license confirmation is
needed. Not available on this ABI: the MSVC STL, the sanitizers, `msvcrt.dll`
as the C runtime, and 32-bit x86.

The MSVC ABI (the default) follows hermetic-llvm's `windows_msvc` route:
`clang-cl` and `lld-link` with Microsoft's runtime and SDK.

**MSVC compiler.** With `HERMETIC_COMPILER=msvc` the compiler is
Microsoft's `cl.exe` instead of `clang-cl`: the compiler packages for the
host and target architecture come from the same Visual Studio installer
manifest as the toolset (about 28 MB, with the English message resources
`cl.exe` needs), so a Windows host builds with the exact MSVC release the
toolset version names, and nothing from a Visual Studio installation. Both
host architectures are served and each can build both targets: an x86_64
host gets the `HostX64` compilers for `windows-x86_64` and
`windows-aarch64`, an ARM64 host the native `HostARM64` ones (toolsets
14.32 and newer ship them; the three older ones are x86_64-host only). The
link step is unchanged, `lld-link` through CMake's MSVC rules
(`cmake/HermeticMSVCRules.cmake`), `llvm-lib` creates static libraries and
`llvm-rc` and `llvm-mt` handle resources and manifests, so `link.exe` and
`lib.exe` from the package are never run. The toolset and SDK headers are
plain include directories (`/X` keeps the host's `INCLUDE` out), and with
`HERMETIC_REPRODUCIBLE` the objects get `/Brepro`,
`/experimental:deterministic` and a `/pathmap:` of the cache directory
(toolset 14.40, Visual Studio 17.10, and newer). Debug info goes into the
objects (`/Z7`, `CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded` unless the
project sets it). Only Windows hosts, Windows targets on the MSVC ABI and the
MSVC STL: cross-compiling, libc++ and the sanitizer runtime sets stay with
the `llvm` compiler. `cl.exe` binaries are not expected to match `clang-cl`
ones, and the cross-host identity check does not cover them.

**Toolset and SDK.** The MSVC toolset (C runtime and STL headers and
libraries) comes from the Visual Studio installer manifest and the Windows
SDK from its public NuGet packages, both pinned by URL and hash in
[`cmake/distributions/windows.json`](cmake/distributions/windows.json).
Every toolset of the pinned manifest (14.29 through 14.51, Visual Studio
2019 to 2026) and the newest NuGet package of each SDK build are listed;
`HERMETIC_MSVC_TOOLSET_VERSION` and `HERMETIC_WINDOWS_SDK_VERSION` select
them, and `cmake -DTOPIC=windows -P scripts/help.cmake` prints the tables.
These packages carry Microsoft licenses, so `HERMETIC_ACCEPT_MICROSOFT_EULA=1`
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
`HERMETIC_WINDOWS_SDK_TOOLS_DIR` for custom commands; the toolchain
itself keeps using `llvm-rc` and `llvm-mt` (and `lld-link`'s own manifest
merging), so that outputs stay identical to those of Linux and macOS
hosts. On those hosts the variable is empty; mingw-w64's `widl` and `wmc`
cover classic COM IDL and message tables there, `dxc` has native builds,
and signing or packaging belong outside the hermetic build.

**Linking.** Executables and DLLs are linked through the `clang-cl` driver,
which runs `lld-link`, rather than through `lld-link` directly, so that
sanitized links get everything the driver adds from the compile flags. The
consequences for a project: `-fsanitize=...` belongs in the compile flags
(`HERMETIC_EXTRA_COMPILE_FLAGS` or `CMAKE_<LANG>_FLAGS`), which the
link step receives as well, while `CMAKE_EXE_LINKER_FLAGS`, `LINK_OPTIONS`
and friends keep CMake's usual MSVC-style linker spelling. Static libraries
use `lib.exe` syntax through `llvm-lib` when the prebuilt ships it, else
the `lib` subcommand of the multicall `llvm` driver, else `llvm-ar`.
Executables and DLLs embed a manifest (`/MANIFEST:EMBED`, the default
`asInvoker` one as with CMake's MSVC rules), merged by `lld-link` itself
with any `/MANIFESTINPUT:<file>` a project adds to its link options;
`/MANIFEST:NO` in a target's link options turns it off. This needs a
compiler prebuilt built with libxml2 (`llvm-23.1.0-4` and later), which
the toolchain checks through `llvm-mt`; with older ones links get no
manifest.

**C++ library.** By default the MSVC STL from the toolset. With
`HERMETIC_CXX_STDLIB=libc++` a runtime set `<target>-msvc.<toolset>` is
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
option remaps them, so with `HERMETIC_REPRODUCIBLE` the toolchain
links through relative paths instead: every build directory (try-compile
directories included) gets a link named `hermetic-cpp` to the cache
directory (a symbolic link, or a directory junction on Windows hosts),
the cache gets a host-neutral `llvm/<version>` link to the compiler, and
the link command names the toolset, SDK, runtime set and `lld-link` itself
through them. With a project-chosen `/pdbsourcepath:` (the sample uses
`/build`) the PDB then records `/build/hermetic-cpp/...` everywhere, and
the executable, which embeds the PDB's GUID, matches too. Compilation keeps
absolute paths; the prefix map covers those. The case-insensitive VFS
overlay used for compilation names everything relative to its own location
and reports headers by the path they were found by, so it holds no
absolute path and suits any spelling of the cache (see
[Remote execution](#remote-execution)); links use variants that report
the libraries' real paths, which `lld-link` opens. The link is only created
for Windows targets and only supports the Ninja generators, whose commands
run from the build directory.

Not ported from hermetic-llvm: MinGW targets and the static-CRT variants
of its Windows sanitizer route beyond what is described above.

## Remote execution

Remote build execution (RBE) caches an action by its command line and
inputs, so a compile, archive or link step is only shared between machines
when its command is the same on each. CMake writes absolute paths (the
tools, `-I` directories, sources), and so does the toolchain for the
cache; an RBE wrapper (such as a `CMAKE_<LANG>_COMPILER_LAUNCHER`) rewrites
them relative to the build directory before sending an action out. The
toolchain keeps everything else about the command independent of the
machine, and try_compile checks, which run locally, are left alone.

- **Put the cache inside the source tree**
  (`HERMETIC_CACHE_DIR=<source>/.hermetic-cpp`), so that every input
  lies under the one root the wrapper uploads.
- **Rewrite every absolute path under that root**, including inside joined
  options: `--sysroot=`, `-resource-dir=`, `-isysroot`, `-isystem<dir>`,
  the left-hand side of `-ffile-prefix-map=` (the compiler then sees the
  same spelling in the paths it maps), and for MSVC-ABI targets
  `/vctoolsdir<dir>`, `/winsdkdir<dir>`, `/imsvc<dir>`, `/FI<file>` and
  the `-ivfsoverlay` file. Rewrite them all the same way: the
  case-insensitive VFS overlay names its directories relative to its own
  location, so it matches the toolset and SDK paths when both are spelled
  alike. MSVC-ABI links already name the toolset, SDK and runtime set
  through the build directory's `hermetic-cpp` link (a relative symbolic
  link, which stays inside the tree when the cache does).
- What the toolchain does for it with `HERMETIC_REPRODUCIBLE`: debug
  info records the working directory as `.` (`-ffile-compilation-dir=.`),
  the cache is mapped to a fixed name, and targets without a runtime set
  name the compiler's resource directory explicitly (the driver would
  otherwise derive an absolute path from its own location, which no
  command-line rewrite reaches).

Outputs do not depend on the checkout or on the host OS: a Linux target
built on macOS and on Linux comes out byte-identical, debug info included.
The compiler binary differs per host OS, so commands only match between
machines of the same OS. `llvm-rc` include paths and CMake's own `cmake -E`
steps are not meant to run remotely.

### Debugging

Debug info then names the cache as `/hermetic-cpp/cache`, the compiler as
`/hermetic-cpp/llvm` and the working directory as `.` (sources a remote
execution wrapper made relative stay relative to the build directory), so a
debugger has to be told where those are. The toolchain writes the settings
into every build directory:

```sh
gdb -x build/hermetic-cpp.gdb build/app      # set substitute-path, directory
lldb -s build/hermetic-cpp.lldb build/app    # settings append target.source-map
```

A project that maps its own paths with `-ffile-prefix-map` adds them with
`hermetic_debugger_source_map(<from> <to>)` (the sample does for its
`/src`). On macOS the debug info stays in the object files, which the
executable names relative to the build directory when linked with
`-Wl,-oso_prefix,.`: LLDB finds them when started in the build directory,
or from a dSYM made with `dsymutil --oso-prepend-path=<build dir> <binary>`,
which it loads from next to the binary.

[`scripts/rbe_wrapper.py`](scripts/rbe_wrapper.py) is a reference wrapper
for checking a build, used as the compiler and linker launcher:

```sh
cmake --preset linux-aarch64 -DHERMETIC_CACHE_DIR=$PWD/.hermetic-cpp \
  "-DCMAKE_CXX_COMPILER_LAUNCHER=python3;$PWD/scripts/rbe_wrapper.py;--root=$PWD;--log=$PWD/rbe.jsonl;--strict;--" \
  "-DCMAKE_CXX_LINKER_LAUNCHER=python3;$PWD/scripts/rbe_wrapper.py;--root=$PWD;--log=$PWD/rbe.jsonl;--strict;--"
```

It rewrites each command as above, fails it (with `--strict`) when an
absolute path of the machine is left in it or in the VFS overlays it reads,
runs it with a minimal environment, checks that the depfiles and
`/showIncludes` output it produces are relative too, and logs the action
(key, command) so that checkouts can be compared. Compiler checks
(try_compile) and tools outside the exec root run unchanged. Static
libraries have no launcher; `--dry-run` checks a command without running
it, for archive commands taken from the build files.
[`tests/run_rbe_check.sh`](tests/run_rbe_check.sh) builds presets through
it in this checkout and in a copy at another path and fails unless both run
the same actions (the same remote cache keys) and produce byte-identical
outputs.

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
cmake -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_TARGET=linux-aarch64 \
      -DHERMETIC_LIBC=gnu.2.34 -DHERMETIC_LLVM_PACKAGE=ON -P runtimes/build_runtimes.cmake
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

[![Tests](https://github.com/Orphis/hermetic-cpp-cmake/actions/workflows/tests.yml/badge.svg)](https://github.com/Orphis/hermetic-cpp-cmake/actions/workflows/tests.yml)
[![Nightly](https://github.com/Orphis/hermetic-cpp-cmake/actions/workflows/nightly.yml/badge.svg)](https://github.com/Orphis/hermetic-cpp-cmake/actions/workflows/nightly.yml)

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
  x86_64, covering glibc, musl, the MSVC STL and libc++ Windows targets
  with ASan, MinGW-w64 Windows targets, macOS targets from Linux and the
  WebAssembly targets. Each job builds at most a few runtime sets from
  source.
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
targets from every host, Windows targets from every host, macOS targets
from Linux x86_64 and macOS arm64 hosts (with the downloaded SDK, and once
with the host's Xcode SDK), and WebAssembly modules from Linux x86_64,
macOS arm64 and Windows hosts (run under Node.js on the Linux x86_64
runner); nightly adds macOS targets from Linux arm64 and both Windows
hosts, macOS x86_64 native, the `darwin-x86_64` cross build and WebAssembly
from Linux arm64 and Windows arm64. Only a Windows arm64 host runs nightly rather than per push, and one
combination has no runner at all: `darwin-aarch64` cross-built from a macOS
x86_64 host. Everything a job builds is executed on a runner, or under
Docker/QEMU, of the target platform.

Both workflows cache only `~/.cache/hermetic-cpp/downloads` (about 300 MB,
mostly the LLVM source archive and the macOS SDK package) and rebuild runtime sets every time, which
keeps them honest about the from-source path; a set takes one to three
minutes on GitHub's runners. Build logs are uploaded as artifacts on failure.

`tests/run_rbe_check.sh [presets...]` checks that builds are ready for
remote execution (see [Remote execution](#remote-execution)): it builds
each preset through the reference wrapper in the checkout and in a copy at
another path, and requires the same actions and byte-identical outputs.
It uses `<repo>/.hermetic-cpp` as the cache, or links it to
`HERMETIC_CACHE_DIR` when that points elsewhere. Every build job runs
it after building, on a subset of its presets (the `rbe` list of the job,
built already, so nothing is downloaded or built again), on every host
including Windows; the nightly jobs add sanitizer, Windows runtime set and
macOS x86_64 presets. The "Tables and selection" job runs the wrapper's own
tests (`tests/rbe_wrapper_test.py`), which need no toolchain.

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
information, mapping its source directory to a fixed name (the toolchain
records the build directory as `.` and maps the cache directory for every
build when `HERMETIC_REPRODUCIBLE` is on), so debug info is measured
too.

Result: release and debug binaries built on Linux x86_64, Linux arm64,
macOS and Windows hosts are byte-identical, PDBs included (see
Reproducibility under Windows targets). Three kinds of difference are
reported but not enforced: sanitized program binaries (ASan and UBSan
embed source paths that no prefix map covers); macOS binaries built
against different SDK versions (only with `HERMETIC_SYSROOT=host`,
where the SDK is the host's Xcode; the sample records the version so the
check can tell); and debug info or PDBs built on a Windows host (the
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
- Not ported yet: BPF targets, libstdc++ as an alternative C++ library,
  the msvcrt.dll flavour and 32-bit x86 of the MinGW route, and the
  compiler bootstrap stages.
- Sanitizer runtimes are optional (`HERMETIC_LLVM_RUNTIME_SANITIZERS`)
  rather than always built; hermetic-llvm's per-sanitizer flag groups
  (ignorelists, CFI, MSan libc++) are not reproduced, `-fsanitize=...` is
  passed by the project.
