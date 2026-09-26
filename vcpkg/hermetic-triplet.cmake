# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# vcpkg triplets that build ports with this toolchain. A triplet sets the
# toolchain's options, then includes this file:
#
#   set(HERMETIC_TARGET linux-x86_64)
#   set(HERMETIC_LIBC musl)
#   include("${CMAKE_CURRENT_LIST_DIR}/../hermetic-triplet.cmake")
#
# Every HERMETIC_* variable the triplet sets is passed on to the toolchain.
# This file fills in what vcpkg needs to know about the target
# (VCPKG_TARGET_ARCHITECTURE, VCPKG_CMAKE_SYSTEM_NAME) and the settings that
# make vcpkg work with a toolchain it did not set up. The triplet may set any
# VCPKG_* variable itself, before or after the include; linkage defaults to
# static libraries, and on Windows (MSVC ABI) to the DLL runtime, like
# CMake's default for the consuming project (VCPKG_CRT_LINKAGE static for
# /MT). The triplets next to this file are ready to use:
#
#   vcpkg install --overlay-triplets=<this dir>/triplets --triplet=x64-linux-musl-hermetic

get_filename_component(_hermetic_vcpkg_repo "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

# The triplet's options, before the modules below define HERMETIC_* names.
set(_hermetic_vcpkg_options "")
get_cmake_property(_hermetic_vcpkg_vars VARIABLES)
foreach(_hermetic_vcpkg_var IN LISTS _hermetic_vcpkg_vars)
  if(_hermetic_vcpkg_var MATCHES "^HERMETIC_")
    list(APPEND _hermetic_vcpkg_options "${_hermetic_vcpkg_var}")
  endif()
endforeach()

if(_HERMETIC_VCPKG_READ_OPTIONS)
  return()  # the toolchain, configuring the consuming project, only needs the options
endif()

if(NOT HERMETIC_TARGET)
  message(FATAL_ERROR "[hermetic-cpp] The triplet ${TARGET_TRIPLET} must set HERMETIC_TARGET before including hermetic-triplet.cmake")
endif()
function(hermetic_fatal)
  message(FATAL_ERROR "[hermetic-cpp] " ${ARGN})
endfunction()
include("${_hermetic_vcpkg_repo}/cmake/HermeticTargets.cmake")
hermetic_target_info("${HERMETIC_TARGET}" _hermetic_vcpkg_tgt)

# vcpkg's architecture names.
if(_hermetic_vcpkg_tgt_ARCH STREQUAL "x86_64")
  set(_hermetic_vcpkg_arch x64)
elseif(_hermetic_vcpkg_tgt_ARCH STREQUAL "aarch64")
  set(_hermetic_vcpkg_arch arm64)
elseif(_hermetic_vcpkg_tgt_ARCH STREQUAL "armv7")
  set(_hermetic_vcpkg_arch arm)
elseif(_hermetic_vcpkg_tgt_ARCH MATCHES "^(riscv64|s390x)$")
  set(_hermetic_vcpkg_arch "${_hermetic_vcpkg_tgt_ARCH}")
else()
  message(FATAL_ERROR "[hermetic-cpp] ${HERMETIC_TARGET}: no vcpkg triplet support (vcpkg's WebAssembly ports expect Emscripten)")
endif()
if(NOT DEFINED VCPKG_TARGET_ARCHITECTURE)
  set(VCPKG_TARGET_ARCHITECTURE "${_hermetic_vcpkg_arch}")
endif()

# The target's system, and the GNU triple autotools ports are configured
# with: vcpkg would derive it from the compiler's name, which is just clang.
set(_hermetic_vcpkg_gnu_triple "")
if(_hermetic_vcpkg_tgt_OS STREQUAL "linux")
  set(_hermetic_vcpkg_system Linux)
  set(_hermetic_vcpkg_family gnu)
  if(HERMETIC_LIBC STREQUAL "musl")
    set(_hermetic_vcpkg_family musl)
  endif()
  string(REPLACE "-gnu" "-${_hermetic_vcpkg_family}" _hermetic_vcpkg_gnu_triple "${_hermetic_vcpkg_tgt_TRIPLE}")
elseif(_hermetic_vcpkg_tgt_OS STREQUAL "darwin")
  set(_hermetic_vcpkg_system Darwin)
  set(_hermetic_vcpkg_gnu_triple "${_hermetic_vcpkg_tgt_ARCH}-apple-darwin")
elseif(HERMETIC_WINDOWS_ABI STREQUAL "gnu")
  set(_hermetic_vcpkg_system MinGW)
  set(_hermetic_vcpkg_gnu_triple "${_hermetic_vcpkg_tgt_ARCH}-w64-mingw32")
else()
  set(_hermetic_vcpkg_system "")  # vcpkg's name for Windows (MSVC ABI)
  # The toolchain sets CMAKE_MSVC_RUNTIME_LIBRARY from VCPKG_CRT_LINKAGE, as
  # vcpkg's own Windows toolchain does. A port that asks for CMake before
  # 3.15 follows it only with this policy (it would get CMake's /MD in its
  # default flags otherwise), which must be set before its
  # cmake_minimum_required, so before the toolchain runs.
  list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS -DCMAKE_POLICY_DEFAULT_CMP0091=NEW)
endif()
if(NOT DEFINED VCPKG_CMAKE_SYSTEM_NAME AND _hermetic_vcpkg_system)
  set(VCPKG_CMAKE_SYSTEM_NAME "${_hermetic_vcpkg_system}")
endif()
if(NOT DEFINED VCPKG_MAKE_BUILD_TRIPLET AND _hermetic_vcpkg_gnu_triple)
  set(VCPKG_MAKE_BUILD_TRIPLET "--host=${_hermetic_vcpkg_gnu_triple}")
endif()

if(NOT DEFINED VCPKG_LIBRARY_LINKAGE)
  set(VCPKG_LIBRARY_LINKAGE static)
endif()
if(NOT DEFINED VCPKG_CRT_LINKAGE)
  set(VCPKG_CRT_LINKAGE dynamic)
endif()
if(VCPKG_LIBRARY_LINKAGE STREQUAL "static" AND NOT DEFINED VCPKG_FIXUP_ELF_RPATH)
  # Nothing to fix without shared libraries, and the fix needs patchelf on
  # the host.
  set(VCPKG_FIXUP_ELF_RPATH OFF)
endif()

set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE "${_hermetic_vcpkg_repo}/toolchain.cmake")
foreach(_hermetic_vcpkg_var IN LISTS _hermetic_vcpkg_options)
  string(REPLACE ";" "\\;" _hermetic_vcpkg_value "${${_hermetic_vcpkg_var}}")
  list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS "-D${_hermetic_vcpkg_var}=${_hermetic_vcpkg_value}")
endforeach()

# vcpkg builds ports in a cleaned environment on Windows hosts. The licence
# answers are part of what is built (tracked: they change the package ABI);
# the cache location and pkg-config are machine-specific (untracked: a
# binary cache is shared across machines).
list(APPEND VCPKG_ENV_PASSTHROUGH HERMETIC_ACCEPT_MICROSOFT_EULA HERMETIC_ACCEPT_APPLE_SDK_LICENSE)
list(APPEND VCPKG_ENV_PASSTHROUGH_UNTRACKED HERMETIC_CACHE_DIR XDG_CACHE_HOME LOCALAPPDATA PKG_CONFIG)

# vcpkg's package ABI covers the triplet and toolchain.cmake, but not the
# rest of the toolchain: its modules, pinned distributions and runtime set
# recipes (and this file).
file(GLOB_RECURSE _hermetic_vcpkg_abi_files
  "${_hermetic_vcpkg_repo}/cmake/*"
  "${_hermetic_vcpkg_repo}/runtimes/*"
  "${_hermetic_vcpkg_repo}/malloc/*")
list(SORT _hermetic_vcpkg_abi_files)
list(APPEND VCPKG_HASH_ADDITIONAL_FILES "${CMAKE_CURRENT_LIST_FILE}" ${_hermetic_vcpkg_abi_files})
