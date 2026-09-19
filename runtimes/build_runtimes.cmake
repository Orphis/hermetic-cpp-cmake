# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Builds (and optionally packages) a runtime set for a Linux target:
#
#   cmake -DHERMETIC_LLVM_VERSION=23.1.0 -DHERMETIC_LLVM_TARGET=linux-aarch64 \
#         -DHERMETIC_LLVM_LIBC=gnu.2.28 [-DHERMETIC_LLVM_PACKAGE=ON] \
#         [-DHERMETIC_LLVM_RUNTIME_SANITIZERS=ON] -P runtimes/build_runtimes.cmake
#
# The compiler is the hermeticbuild prebuilt for this host (downloaded if
# needed). The result lands in <cache>/runtimes/<llvm>/<target>-<libc>/ and is
# what toolchain.cmake uses for that target; toolchain.cmake also builds sets
# on demand, this script exists to prebuild and publish them.

cmake_minimum_required(VERSION 3.19)
get_filename_component(HERMETIC_LLVM_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED HERMETIC_LLVM_VERSION OR HERMETIC_LLVM_VERSION STREQUAL "")
  set(HERMETIC_LLVM_VERSION "latest")
endif()
if(NOT HERMETIC_LLVM_TARGET)
  message(FATAL_ERROR "HERMETIC_LLVM_TARGET is required (e.g. linux-x86_64)")
endif()
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMCommon.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMDistributions.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMTargets.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMConfigure.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMRuntimes.cmake")

hermetic_llvm_detect_host(HERMETIC_LLVM_HOST_OS HERMETIC_LLVM_HOST_ARCH)
hermetic_llvm_resolve_cache_dir()
hermetic_llvm_load_runtime_sources()
if(NOT HERMETIC_LLVM_LIBC)
  set(HERMETIC_LLVM_LIBC "${HERMETIC_LLVM_DEFAULT_LIBC}")
endif()
hermetic_llvm_provide_compiler("${HERMETIC_LLVM_VERSION}" "${HERMETIC_LLVM_HOST_OS}" "${HERMETIC_LLVM_HOST_ARCH}" dist)
hermetic_llvm_log("Compiler: LLVM ${dist_VERSION} at ${dist_ROOT}")
hermetic_llvm_build_runtime_set("${dist_ROOT}" "${dist_VERSION}" "${HERMETIC_LLVM_TARGET}" "${HERMETIC_LLVM_LIBC}" set_dir)
if(HERMETIC_LLVM_PACKAGE)
  hermetic_llvm_package_runtime_set("${set_dir}" archive)
endif()
