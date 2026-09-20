# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Downloads the compiler and prepares the runtime set a configuration would
# use, without configuring a project. Handy for warming caches:
#
#   cmake -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_LLVM_TARGET=linux-aarch64 \
#         -DHERMETIC_LLVM_LIBC=musl -P scripts/prefetch.cmake
#
# Accepts the same HERMETIC_LLVM_* options as toolchain.cmake, plus
# -DHERMETIC_LLVM_DRY_RUN=ON to only print what would be selected.

cmake_minimum_required(VERSION 3.19)
get_filename_component(HERMETIC_LLVM_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED HERMETIC_LLVM_VERSION OR HERMETIC_LLVM_VERSION STREQUAL "")
  set(HERMETIC_LLVM_VERSION "latest")
endif()
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMCommon.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMDistributions.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMTargets.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMConfigure.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMRuntimes.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMWindows.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMResolve.cmake")

if(HERMETIC_LLVM_DRY_RUN)
  hermetic_llvm_detect_host(host_os host_arch)
  if(NOT DEFINED HERMETIC_LLVM_TARGET OR HERMETIC_LLVM_TARGET STREQUAL "" OR HERMETIC_LLVM_TARGET STREQUAL "host")
    set(HERMETIC_LLVM_TARGET "${host_os}-${host_arch}")
  endif()
  hermetic_llvm_target_info("${HERMETIC_LLVM_TARGET}" tgt)
  hermetic_llvm_resolve_cache_dir()
  hermetic_llvm_load_runtime_sources()
  hermetic_llvm_select_hermeticbuild("${HERMETIC_LLVM_VERSION}" "${host_os}" "${host_arch}" sel)
  message(STATUS "host:      ${host_os}-${host_arch}")
  message(STATUS "llvm:      ${sel_VERSION} ${sel_KEY} [${sel_RELEASE}]")
  message(STATUS "sha256:    ${sel_SHA256}")
  message(STATUS "urls:      ${sel_URLS}")
  if(tgt_OS STREQUAL "linux")
    if(NOT HERMETIC_LLVM_LIBC)
      set(HERMETIC_LLVM_LIBC "${HERMETIC_LLVM_DEFAULT_LIBC}")
    endif()
    hermetic_llvm_parse_libc("${HERMETIC_LLVM_LIBC}" family version)
    hermetic_llvm_libc_triple("${tgt_ARCH}" "${family}" triple)
    message(STATUS "target:    ${HERMETIC_LLVM_TARGET} (${triple})")
    message(STATUS "runtimes:  ${HERMETIC_LLVM_TARGET}-${HERMETIC_LLVM_LIBC} in ${HERMETIC_LLVM_CACHE_DIR}/runtimes/${sel_VERSION}/")
  elseif(tgt_OS STREQUAL "windows" AND HERMETIC_LLVM_CXX_STDLIB STREQUAL "libc++")
    hermetic_llvm_windows_versions(msvc msvc_default sdk sdk_default)
    hermetic_llvm_select_version("MSVC toolset (HERMETIC_LLVM_MSVC_VERSION)" "${HERMETIC_LLVM_MSVC_VERSION}" "${msvc_default}" "${msvc}" msvc_version)
    message(STATUS "target:    ${HERMETIC_LLVM_TARGET} (${tgt_TRIPLE}), libc++")
    message(STATUS "runtimes:  ${HERMETIC_LLVM_TARGET}-msvc.${msvc_version} in ${HERMETIC_LLVM_CACHE_DIR}/runtimes/${sel_VERSION}/")
  else()
    message(STATUS "target:    ${HERMETIC_LLVM_TARGET} (${tgt_TRIPLE})")
  endif()
  message(STATUS "cache dir: ${HERMETIC_LLVM_CACHE_DIR}")
else()
  hermetic_llvm_resolve()
endif()
