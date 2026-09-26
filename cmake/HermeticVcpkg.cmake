# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# vcpkg ports. vcpkg configures every port with its own toolchain file
# (scripts/buildsystems/vcpkg.cmake), which chain-loads this one when the
# triplet names it (VCPKG_CHAINLOAD_TOOLCHAIN_FILE; vcpkg/hermetic-triplet.cmake
# does), and passes the triplet's settings as cache variables. vcpkg's own
# platform toolchains (scripts/toolchains/*.cmake) turn those into flags; a
# chain-loaded toolchain replaces them, so it reads them here:
#
# - VCPKG_CRT_LINKAGE: the C runtime of MSVC ABI targets. vcpkg's Windows
#   toolchain sets CMAKE_MSVC_RUNTIME_LIBRARY from it; without that, ports
#   were built against the DLL runtime whatever the triplet asked for.
# - VCPKG_C_FLAGS, VCPKG_CXX_FLAGS, VCPKG_LINKER_FLAGS (and their _DEBUG and
#   _RELEASE variants): the triplet's own flags.
# - Position-independent code for ELF targets, as vcpkg's Linux toolchain
#   does: static libraries of ports end up in shared libraries too.
# - Paths: debug info names the port's sources (<buildtrees>/<port>/src/...)
#   and its dependencies' headers (<installed>/<triplet>/include) where this
#   vcpkg checkout keeps them. They are mapped to /vcpkg/buildtrees and
#   /vcpkg/installed, so a binary cache serves the same bytes to every
#   machine.
#
# The consuming project (the one that uses vcpkg.cmake as its toolchain and
# installs a manifest) must be built for the same target, with the same C
# runtime: when VCPKG_TARGET_TRIPLET names a triplet made with
# vcpkg/hermetic-triplet.cmake, its HERMETIC_* options become the defaults,
# and on MSVC ABI targets its VCPKG_CRT_LINKAGE the default
# CMAKE_MSVC_RUNTIME_LIBRARY. The project maps its own paths,
# VCPKG_INSTALLED_DIR included (see README.md).

include_guard(GLOBAL)

list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
  VCPKG_CRT_LINKAGE VCPKG_TARGET_ARCHITECTURE
  VCPKG_C_FLAGS VCPKG_CXX_FLAGS VCPKG_C_FLAGS_DEBUG VCPKG_CXX_FLAGS_DEBUG
  VCPKG_C_FLAGS_RELEASE VCPKG_CXX_FLAGS_RELEASE
  VCPKG_LINKER_FLAGS VCPKG_LINKER_FLAGS_DEBUG VCPKG_LINKER_FLAGS_RELEASE)

function(_hermetic_vcpkg_port_build OUT)
  # vcpkg_cmake_configure passes both to every port (and so does
  # vcpkg_cmake_get_vars, which extracts the flags that autotools, Meson and
  # other ports build with); a project that merely uses vcpkg.cmake has
  # neither on its first configure.
  if(DEFINED VCPKG_CRT_LINKAGE AND DEFINED _VCPKG_INSTALLED_DIR)
    set(${OUT} TRUE PARENT_SCOPE)
  else()
    set(${OUT} FALSE PARENT_SCOPE)
  endif()
endfunction()

# The options of the triplet VCPKG_TARGET_TRIPLET names, found in the
# overlay directories or vcpkg/triplets, become defaults. Runs before the
# options get theirs; the command line's win.
function(hermetic_vcpkg_triplet_defaults)
  set(_HERMETIC_VCPKG_TRIPLET_CRT "" PARENT_SCOPE)
  if(NOT VCPKG_TARGET_TRIPLET OR VCPKG_TARGET_TRIPLET STREQUAL HERMETIC_VCPKG_GENERATED_TARGET_TRIPLET)
    return()  # none, or the one HERMETIC_VCPKG wrote on an earlier run
  endif()
  _hermetic_vcpkg_port_build(port)
  if(port)
    return()  # vcpkg passes the triplet's options itself
  endif()
  set(dirs ${VCPKG_OVERLAY_TRIPLETS})
  if(DEFINED ENV{VCPKG_OVERLAY_TRIPLETS})
    if(CMAKE_HOST_WIN32)
      list(APPEND dirs "$ENV{VCPKG_OVERLAY_TRIPLETS}")
    else()
      string(REPLACE ":" ";" env_dirs "$ENV{VCPKG_OVERLAY_TRIPLETS}")
      list(APPEND dirs ${env_dirs})
    endif()
  endif()
  list(APPEND dirs "${HERMETIC_DIR}/vcpkg/triplets")
  set(file "")
  foreach(dir IN LISTS dirs)
    if(EXISTS "${dir}/${VCPKG_TARGET_TRIPLET}.cmake")
      set(file "${dir}/${VCPKG_TARGET_TRIPLET}.cmake")
      break()
    endif()
  endforeach()
  if(NOT file)
    return()
  endif()

  get_cmake_property(vars VARIABLES)
  set(before "")
  foreach(var IN LISTS vars)
    if(var MATCHES "^HERMETIC_")
      list(APPEND before "${var}")
      set(before_${var} "${${var}}")
    endif()
  endforeach()
  unset(VCPKG_CRT_LINKAGE)
  # hermetic-triplet.cmake returns once it has listed the options.
  set(_HERMETIC_VCPKG_READ_OPTIONS TRUE)
  include("${file}")
  if(NOT DEFINED _hermetic_vcpkg_options)
    return()  # a triplet of some other toolchain
  endif()
  hermetic_log("vcpkg triplet ${VCPKG_TARGET_TRIPLET}: ${file}")
  foreach(var IN LISTS _hermetic_vcpkg_options)
    if(NOT var IN_LIST before)
      set(${var} "${${var}}" PARENT_SCOPE)
    elseif(NOT "${before_${var}}" STREQUAL "${${var}}")
      message(WARNING "[hermetic-cpp] ${var}=${before_${var}} differs from the vcpkg triplet ${VCPKG_TARGET_TRIPLET} (${${var}}): the project and its vcpkg packages are built differently")
    endif()
  endforeach()
  set(_HERMETIC_VCPKG_TRIPLET_CRT "${VCPKG_CRT_LINKAGE}" PARENT_SCOPE)
endfunction()

# Run after hermetic_configure, whose _hl_* variables it reads.
macro(hermetic_vcpkg_setup)
  _hermetic_vcpkg_port_build(HERMETIC_VCPKG_PORT_BUILD)
  if(HERMETIC_VCPKG_PORT_BUILD)
    _hermetic_vcpkg_port_setup()
  elseif(_HERMETIC_VCPKG_TRIPLET_CRT AND _hl_windows)
    _hermetic_vcpkg_msvc_runtime("${_HERMETIC_VCPKG_TRIPLET_CRT}")
  endif()
endmacro()

# The triplet's C runtime, as vcpkg's Windows toolchain sets it, unless the
# project chose one.
macro(_hermetic_vcpkg_msvc_runtime LINKAGE)
  if(NOT "${LINKAGE}" MATCHES "^(static|dynamic)$")
    hermetic_fatal("VCPKG_CRT_LINKAGE must be static or dynamic, not \"${LINKAGE}\"")
  endif()
  set(_hv_runtime "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  if("${LINKAGE}" STREQUAL "dynamic")
    string(APPEND _hv_runtime "DLL")
  endif()
  set(CMAKE_MSVC_RUNTIME_LIBRARY "${_hv_runtime}" CACHE STRING "")
endmacro()

macro(_hermetic_vcpkg_port_setup)
  if(_hl_windows)
    # Ports that still ask for CMake before 3.15 only follow it with
    # CMP0091, which cmake_minimum_required sets before this file runs:
    # hermetic-triplet.cmake sets it on the command line.
    _hermetic_vcpkg_msvc_runtime("${VCPKG_CRT_LINKAGE}")
  elseif(NOT _hl_mingw AND NOT _hl_tgt_OS STREQUAL "wasm")
    foreach(_hv_lang C CXX)
      hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT -fPIC)
    endforeach()
  endif()
  # Autotools and Meson ports get their flags from vcpkg_cmake_get_vars's
  # project (ports/vcpkg-cmake-get-vars/cmake_get_vars), and LDFLAGS from its
  # shared-library link flags, with which they link executables too,
  # configure's test programs included. musl targets are static only (no
  # libc.so): without the executables' link mode there, those programs ask
  # for a dynamic loader that does not exist, and configure fails to run
  # them on a host of the target's architecture. (Not for the ports' own
  # CMake builds: lld refuses -static-pie with -shared.)
  if(_hl_libc_family STREQUAL "musl" AND CMAKE_SOURCE_DIR MATCHES "/cmake_get_vars$")
    hermetic_append_flags(CMAKE_SHARED_LINKER_FLAGS_INIT ${_hl_exe_link_flags})
  endif()

  if(HERMETIC_REPRODUCIBLE)
    set(_hv_maps "")
    # The port's build directories are <buildtrees>/<port>/<triplet>-rel and
    # -dbg, its sources <buildtrees>/<port>/src/<ref>.
    get_filename_component(_hv_build_name "${CMAKE_BINARY_DIR}" NAME)
    if(DEFINED VCPKG_TARGET_TRIPLET AND _hv_build_name MATCHES "^${VCPKG_TARGET_TRIPLET}-(rel|dbg)$")
      get_filename_component(_hv_buildtrees "${CMAKE_BINARY_DIR}/../.." ABSOLUTE)
      list(APPEND _hv_maps "${_hv_buildtrees}=/vcpkg/buildtrees")
    endif()
    list(APPEND _hv_maps "${_VCPKG_INSTALLED_DIR}=/vcpkg/installed")
    foreach(_hv_map IN LISTS _hv_maps)
      if(_hl_msvc)
        set(_hv_flag "/pathmap:${_hv_map}")
      elseif(_hl_windows)
        set(_hv_flag "/clang:-ffile-prefix-map=${_hv_map}")
      else()
        set(_hv_flag "-ffile-prefix-map=${_hv_map}")
      endif()
      foreach(_hv_lang C CXX ASM OBJC OBJCXX)
        hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT "${_hv_flag}")
      endforeach()
    endforeach()
  endif()

  foreach(_hv_lang C CXX)
    hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT ${VCPKG_${_hv_lang}_FLAGS})
    foreach(_hv_config DEBUG RELEASE)
      hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_${_hv_config}_INIT ${VCPKG_${_hv_lang}_FLAGS_${_hv_config}})
    endforeach()
  endforeach()
  foreach(_hv_kind EXE SHARED MODULE)
    hermetic_append_flags(CMAKE_${_hv_kind}_LINKER_FLAGS_INIT ${VCPKG_LINKER_FLAGS})
    foreach(_hv_config DEBUG RELEASE)
      hermetic_append_flags(CMAKE_${_hv_kind}_LINKER_FLAGS_${_hv_config}_INIT ${VCPKG_LINKER_FLAGS_${_hv_config}})
    endforeach()
  endforeach()
endmacro()

# ---- The toolchain in front: HERMETIC_VCPKG --------------------------------
#
# With HERMETIC_VCPKG (ON, or a vcpkg directory) the project names this
# toolchain only, and the toolchain sets vcpkg up the other way round: it
# writes a triplet for its own configuration (and one for build tools, when
# the target's programs cannot run on the host) into
# <build>/hermetic-cpp-vcpkg, then includes vcpkg's toolchain file, which
# installs the manifest with them. The triplets chain-load this toolchain for
# the ports, as the ones in vcpkg/triplets do.

# The options that decide what a port's code is built for and with; the
# rest (cache, downloads, logging, the allocator of executables) do not
# change the packages.
set(HERMETIC_VCPKG_TRIPLET_OPTIONS
  HERMETIC_LLVM_VERSION HERMETIC_LLVM_RELEASE HERMETIC_LLVM_HERMETICBUILD_INDEX
  HERMETIC_LLVM_DISTRIBUTION_URL HERMETIC_LLVM_DISTRIBUTION_SHA256 HERMETIC_LLVM_DISTRIBUTION_STRIP_COMPONENTS
  HERMETIC_TARGET HERMETIC_LIBC HERMETIC_CXX_STDLIB HERMETIC_LLVM_RUNTIMES HERMETIC_LLVM_RUNTIME_SANITIZERS
  HERMETIC_SYSROOT HERMETIC_SYSROOT_SHA256 HERMETIC_SYSROOT_STRIP_COMPONENTS
  HERMETIC_MSVC_TOOLSET_VERSION HERMETIC_WINDOWS_SDK_VERSION HERMETIC_WINDOWS_ABI HERMETIC_MACOS_SDK_VERSION
  HERMETIC_PIE HERMETIC_USE_LLD HERMETIC_REPRODUCIBLE HERMETIC_COMPILER)

# The vcpkg checkout pinned in cmake/distributions/vcpkg.json, cloned into
# the cache once: the history without trees or files until they are needed
# (manifests with a builtin-baseline read older versions from it).
function(hermetic_vcpkg_fetch OUT)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/vcpkg.json" json)
  string(JSON repository GET "${json}" vcpkg repository)
  string(JSON commit GET "${json}" vcpkg commit)
  string(SUBSTRING "${commit}" 0 12 short)
  set(dest "${HERMETIC_CACHE_DIR}/vcpkg/${short}")
  set(stamp "${dest}/.hermetic-cpp.stamp")
  if(EXISTS "${stamp}")
    set(${OUT} "${dest}" PARENT_SCOPE)
    return()
  endif()
  file(MAKE_DIRECTORY "${HERMETIC_CACHE_DIR}/locks")
  file(LOCK "${HERMETIC_CACHE_DIR}/locks/vcpkg-${short}.lock" GUARD FUNCTION TIMEOUT 7200)
  if(EXISTS "${stamp}")
    set(${OUT} "${dest}" PARENT_SCOPE)
    return()
  endif()
  find_program(HERMETIC_GIT git)
  if(NOT HERMETIC_GIT)
    hermetic_fatal("HERMETIC_VCPKG=ON clones vcpkg with git, which was not found; install it, or set VCPKG_ROOT or HERMETIC_VCPKG to a vcpkg checkout")
  endif()
  hermetic_log("vcpkg: cloning ${repository} at ${commit}")
  set(tmp "${dest}.tmp")
  file(REMOVE_RECURSE "${tmp}" "${dest}")
  foreach(step IN ITEMS clone checkout)
    if(step STREQUAL "clone")
      set(cmd "${HERMETIC_GIT}" clone -q --filter=tree:0 --no-checkout "${repository}" "${tmp}")
    else()
      set(cmd "${HERMETIC_GIT}" -C "${tmp}" -c advice.detachedHead=false checkout -q "${commit}")
    endif()
    execute_process(COMMAND ${cmd} RESULT_VARIABLE result ERROR_VARIABLE error)
    if(NOT result EQUAL 0)
      file(REMOVE_RECURSE "${tmp}")
      hermetic_fatal("vcpkg: git ${step} failed: ${error}")
    endif()
  endforeach()
  file(RENAME "${tmp}" "${dest}")
  file(WRITE "${stamp}" "${commit}\n")
  set(${OUT} "${dest}" PARENT_SCOPE)
endfunction()

# vcpkg's name for a target, in the scheme of vcpkg/triplets.
function(_hermetic_vcpkg_triplet_name OS ARCH LIBC WINDOWS_ABI CRT OUT)
  if(ARCH STREQUAL "x86_64")
    set(name x64)
  elseif(ARCH STREQUAL "aarch64")
    set(name arm64)
  elseif(ARCH STREQUAL "armv7")
    set(name arm)
  else()
    set(name "${ARCH}")
  endif()
  if(OS STREQUAL "linux")
    string(APPEND name "-linux")
    if(LIBC MATCHES "^musl")
      string(APPEND name "-musl")
    endif()
  elseif(OS STREQUAL "darwin")
    string(APPEND name "-osx")
  elseif(WINDOWS_ABI STREQUAL "gnu")
    string(APPEND name "-mingw-static")
  elseif(CRT STREQUAL "static")
    string(APPEND name "-windows-static")
  else()
    string(APPEND name "-windows-static-md")
  endif()
  set(${OUT} "${name}-hermetic" PARENT_SCOPE)
endfunction()

# Writes <DIR>/<NAME>.cmake: the options given as NAME=VALUE, then
# vcpkg/hermetic-triplet.cmake. Its location is in a file of its own, so the
# triplet's text, which vcpkg hashes into every package's ABI, is the same
# on every machine.
function(_hermetic_vcpkg_write_triplet DIR NAME)
  set(text "# Generated by hermetic-cpp-cmake for this build (HERMETIC_VCPKG).\n")
  foreach(assignment IN LISTS ARGN)
    string(REGEX MATCH "^([^=]+)=(.*)$" _ "${assignment}")
    string(REPLACE "\\" "\\\\" value "${CMAKE_MATCH_2}")
    string(REPLACE "\"" "\\\"" value "${value}")
    string(APPEND text "set(${CMAKE_MATCH_1} \"${value}\")\n")
  endforeach()
  string(APPEND text "include(\"\${CMAKE_CURRENT_LIST_DIR}/hermetic-triplet.location\")\n")
  file(CONFIGURE OUTPUT "${DIR}/${NAME}.cmake" CONTENT "${text}" @ONLY)
endfunction()

# Run last in the toolchain, after hermetic_configure.
macro(hermetic_vcpkg_include)
  _hermetic_vcpkg_port_build(_hv_port)
  if(HERMETIC_VCPKG AND NOT _hv_port)
    if(DEFINED VCPKG_CHAINLOAD_TOOLCHAIN_FILE)
      message(WARNING "[hermetic-cpp] HERMETIC_VCPKG is ignored: vcpkg's toolchain file is already the project's and chain-loads this one")
    else()
      get_property(_hv_in_try_compile GLOBAL PROPERTY IN_TRY_COMPILE)
      if(NOT _hv_in_try_compile)
        _hermetic_vcpkg_prepare()
      endif()
      include("${HERMETIC_VCPKG_RESOLVED_ROOT}/scripts/buildsystems/vcpkg.cmake")
    endif()
  endif()
endmacro()

macro(_hermetic_vcpkg_prepare)
  # The checkout.
  if(IS_DIRECTORY "${HERMETIC_VCPKG}")
    get_filename_component(HERMETIC_VCPKG_RESOLVED_ROOT "${HERMETIC_VCPKG}" ABSOLUTE)
  elseif(DEFINED ENV{VCPKG_ROOT} AND IS_DIRECTORY "$ENV{VCPKG_ROOT}")
    file(TO_CMAKE_PATH "$ENV{VCPKG_ROOT}" HERMETIC_VCPKG_RESOLVED_ROOT)
  else()
    hermetic_vcpkg_fetch(HERMETIC_VCPKG_RESOLVED_ROOT)
  endif()
  if(NOT EXISTS "${HERMETIC_VCPKG_RESOLVED_ROOT}/scripts/buildsystems/vcpkg.cmake")
    hermetic_fatal("HERMETIC_VCPKG: ${HERMETIC_VCPKG_RESOLVED_ROOT} is not a vcpkg checkout")
  endif()
  hermetic_log("vcpkg: ${HERMETIC_VCPKG_RESOLVED_ROOT}")

  set(_hv_dir "${CMAKE_BINARY_DIR}/hermetic-cpp-vcpkg")
  file(CONFIGURE OUTPUT "${_hv_dir}/hermetic-triplet.location"
    CONTENT "include(\"${HERMETIC_DIR}/vcpkg/hermetic-triplet.cmake\")\n")

  # The target's triplet, from this configuration, unless the project named
  # one (hermetic_vcpkg_triplet_defaults then read its options). vcpkg's
  # toolchain file caches the name: the one written on an earlier run is
  # rewritten, for options that may have changed since.
  if(NOT VCPKG_TARGET_TRIPLET OR VCPKG_TARGET_TRIPLET STREQUAL HERMETIC_VCPKG_GENERATED_TARGET_TRIPLET)
    set(_hv_crt dynamic)
    if(_hl_windows AND DEFINED CMAKE_MSVC_RUNTIME_LIBRARY AND NOT CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "DLL")
      set(_hv_crt static)
    endif()
    _hermetic_vcpkg_triplet_name("${_hl_tgt_OS}" "${_hl_tgt_ARCH}" "${HERMETIC_RESOLVED_LIBC}"
      "${HERMETIC_RESOLVED_WINDOWS_ABI}" "${_hv_crt}" VCPKG_TARGET_TRIPLET)
    set(_hv_options "")
    foreach(_hv_var IN LISTS HERMETIC_VCPKG_TRIPLET_OPTIONS)
      if(DEFINED ${_hv_var} AND NOT "${${_hv_var}}" STREQUAL "")
        list(APPEND _hv_options "${_hv_var}=${${_hv_var}}")
      endif()
    endforeach()
    if(_hl_windows AND _hv_crt STREQUAL "static")
      list(APPEND _hv_options "VCPKG_CRT_LINKAGE=static")
    endif()
    _hermetic_vcpkg_write_triplet("${_hv_dir}" "${VCPKG_TARGET_TRIPLET}" ${_hv_options})
    set(HERMETIC_VCPKG_GENERATED_TARGET_TRIPLET "${VCPKG_TARGET_TRIPLET}" CACHE INTERNAL "")
  endif()

  # Build tools (the host triplet): the target's triplet when its programs
  # run here, else one for the host with the same compiler. Without the
  # licence answers, the host's own SDK on macOS and MinGW-w64 on Windows,
  # which need no download from Apple or Microsoft.
  if(NOT VCPKG_HOST_TRIPLET OR VCPKG_HOST_TRIPLET STREQUAL HERMETIC_VCPKG_GENERATED_HOST_TRIPLET)
    if(_hl_native)
      set(VCPKG_HOST_TRIPLET "${VCPKG_TARGET_TRIPLET}")
    else()
      set(_hv_options "HERMETIC_TARGET=${HERMETIC_RESOLVED_HOST_OS}-${HERMETIC_RESOLVED_HOST_ARCH}")
      foreach(_hv_var IN ITEMS HERMETIC_LLVM_VERSION HERMETIC_LLVM_RELEASE HERMETIC_LLVM_HERMETICBUILD_INDEX
          HERMETIC_LLVM_DISTRIBUTION_URL HERMETIC_LLVM_DISTRIBUTION_SHA256 HERMETIC_LLVM_DISTRIBUTION_STRIP_COMPONENTS)
        if(DEFINED ${_hv_var} AND NOT "${${_hv_var}}" STREQUAL "")
          list(APPEND _hv_options "${_hv_var}=${${_hv_var}}")
        endif()
      endforeach()
      set(_hv_host_abi msvc)
      if(HERMETIC_RESOLVED_HOST_OS STREQUAL "darwin")
        if(NOT HERMETIC_ACCEPT_APPLE_SDK_LICENSE AND NOT "$ENV{HERMETIC_ACCEPT_APPLE_SDK_LICENSE}")
          list(APPEND _hv_options "HERMETIC_SYSROOT=host")
        endif()
      elseif(HERMETIC_RESOLVED_HOST_OS STREQUAL "windows")
        if(NOT HERMETIC_ACCEPT_MICROSOFT_EULA AND NOT "$ENV{HERMETIC_ACCEPT_MICROSOFT_EULA}")
          set(_hv_host_abi gnu)
          list(APPEND _hv_options "HERMETIC_WINDOWS_ABI=gnu")
        endif()
      endif()
      _hermetic_vcpkg_triplet_name("${HERMETIC_RESOLVED_HOST_OS}" "${HERMETIC_RESOLVED_HOST_ARCH}" gnu
        "${_hv_host_abi}" dynamic VCPKG_HOST_TRIPLET)
      _hermetic_vcpkg_write_triplet("${_hv_dir}" "${VCPKG_HOST_TRIPLET}" ${_hv_options})
    endif()
    set(HERMETIC_VCPKG_GENERATED_HOST_TRIPLET "${VCPKG_HOST_TRIPLET}" CACHE INTERNAL "")
  endif()
  set(VCPKG_OVERLAY_TRIPLETS "${_hv_dir}" ${VCPKG_OVERLAY_TRIPLETS})
  list(REMOVE_DUPLICATES VCPKG_OVERLAY_TRIPLETS)

  # vcpkg builds the ports in processes of its own: they get the licence
  # answers and the cache given to this configuration through the
  # environment (vcpkg/hermetic-triplet.cmake passes them on).
  foreach(_hv_var IN ITEMS HERMETIC_ACCEPT_MICROSOFT_EULA HERMETIC_ACCEPT_APPLE_SDK_LICENSE)
    if(${_hv_var})
      set(ENV{${_hv_var}} 1)
    endif()
  endforeach()
  set(ENV{HERMETIC_CACHE_DIR} "${HERMETIC_CACHE_DIR}")

  if(NOT CMAKE_HOST_WIN32 AND NOT DEFINED ENV{PKG_CONFIG})
    find_program(HERMETIC_PKG_CONFIG NAMES pkg-config pkgconf)
    if(NOT HERMETIC_PKG_CONFIG)
      message(WARNING "[hermetic-cpp] vcpkg checks the pkg-config files of most ports with pkg-config, which was not found: install it (or pkgconf), or name one with the PKG_CONFIG environment variable")
    endif()
  endif()
endmacro()
