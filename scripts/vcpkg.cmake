# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Prints the vcpkg checkout HERMETIC_VCPKG=ON uses when VCPKG_ROOT is not
# set, cloning it into the cache first (cmake/distributions/vcpkg.json):
#
#   cmake -P scripts/vcpkg.cmake

cmake_minimum_required(VERSION 3.19)
get_filename_component(HERMETIC_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
include("${HERMETIC_DIR}/cmake/HermeticCommon.cmake")
include("${HERMETIC_DIR}/cmake/HermeticVcpkg.cmake")
hermetic_resolve_cache_dir()
hermetic_vcpkg_fetch(root)
message("${root}")
