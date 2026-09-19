# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# CMAKE_USER_MAKE_RULES_OVERRIDE for Windows (MSVC ABI) targets: loaded after
# CMake's platform rules. The hermetic-llvm prebuilts ship no llvm-lib, so
# static libraries are created with llvm-ar (lld-link reads its archives).
foreach(lang C CXX ASM_MASM RC)
  set(CMAKE_${lang}_CREATE_STATIC_LIBRARY "<CMAKE_AR> qcs <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_CREATE "<CMAKE_AR> qcs <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_APPEND "<CMAKE_AR> q <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_FINISH "")
endforeach()
# lib.exe-style static linker flags (/machine:x64) mean nothing to llvm-ar.
set(CMAKE_STATIC_LINKER_FLAGS_INIT "")
set(CMAKE_STATIC_LINKER_FLAGS "")
