# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# A consumer of vcpkg packages built with the toolchain's triplets (see
# tests/run_vcpkg.sh): CMake ports (fmt, spdlog with its thread_local
# objects, zlib, libpng, zstd, which asks for CMake 3.10) and, except on the
# MSVC ABI (no MASM assembler, see README.md), Boost.Context with its
# assembly and an autotools port (libffi).
cmake_minimum_required(VERSION 3.21)
project(hermetic_vcpkg_test C CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(boost_context CONFIG)
find_package(fmt CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(ZLIB REQUIRED)
find_package(PNG REQUIRED)
find_package(zstd CONFIG REQUIRED)
find_package(unofficial-libffi CONFIG)

add_executable(vcpkg_app main.cpp)
target_link_libraries(vcpkg_app PRIVATE fmt::fmt spdlog::spdlog ZLIB::ZLIB PNG::PNG
  $<IF:$<TARGET_EXISTS:zstd::libzstd_static>,zstd::libzstd_static,zstd::libzstd>)
if(TARGET Boost::context)
  target_link_libraries(vcpkg_app PRIVATE Boost::context)
  target_compile_definitions(vcpkg_app PRIVATE HAVE_BOOST_CONTEXT)
endif()
if(TARGET unofficial::libffi::libffi)
  target_link_libraries(vcpkg_app PRIVATE unofficial::libffi::libffi)
  target_compile_definitions(vcpkg_app PRIVATE HAVE_FFI)
endif()
