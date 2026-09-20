# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# CMAKE_USER_MAKE_RULES_OVERRIDE for Windows (MSVC ABI) targets: loaded after
# CMake's platform rules.
#
# Executables and DLLs are linked through the clang-cl driver (which runs
# lld-link) instead of lld-link directly: the driver adds what sanitized
# links need (the ASan runtime and its thunk with /wholearchive, libFuzzer,
# the compiler-rt library path from -resource-dir) based on the compile
# flags, which CMake hands to the link step as <FLAGS>. Linker options
# (<LINK_FLAGS>, <LINK_LIBRARIES>) keep CMake's MSVC-style spelling and go
# after /link, so -fsanitize=... belongs in the compile flags only.
#
# The hermetic-llvm prebuilts ship no llvm-lib, so static libraries are
# created with llvm-ar (lld-link reads its archives).
foreach(lang C CXX ASM_MASM RC)
  set(CMAKE_${lang}_CREATE_STATIC_LIBRARY "<CMAKE_AR> qcs <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_CREATE "<CMAKE_AR> qcs <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_APPEND "<CMAKE_AR> q <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_FINISH "")
endforeach()
# lib.exe-style static linker flags (/machine:x64) mean nothing to llvm-ar.
set(CMAKE_STATIC_LINKER_FLAGS_INIT "")
set(CMAKE_STATIC_LINKER_FLAGS "")

# Compile-only flags among <FLAGS> (/EHsc, /GR, /imsvc, ...) are unused at link time.
set(_hl_link_head "/nologo -fuse-ld=lld -Wno-unused-command-line-argument")
# Link libraries are driver inputs right after the objects, not /link
# arguments: when CMake moves objects and libraries into a response file
# (Windows, long command lines) they land at <OBJECTS> anyway, and lld resolves
# symbols in input order, so this keeps the order (and the import thunk
# layout of the output) identical whether or not a response file is used.
# HERMETIC_LLVM_WINDOWS_LINK_TAIL: linker options placed after everything a
# project adds (the runtime set build uses it to override /DEBUG).
set(_hl_link_tail "/link /implib:<TARGET_IMPLIB> /pdb:<TARGET_PDB> /version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR> <LINK_FLAGS> ${HERMETIC_LLVM_WINDOWS_LINK_TAIL}")
foreach(lang C CXX)
  set(CMAKE_${lang}_LINK_EXECUTABLE
    "<CMAKE_${lang}_COMPILER> ${_hl_link_head} <FLAGS> <OBJECTS> <LINK_LIBRARIES> /Fe<TARGET> ${_hl_link_tail}")
  set(CMAKE_${lang}_CREATE_SHARED_LIBRARY
    "<CMAKE_${lang}_COMPILER> ${_hl_link_head} <LANGUAGE_COMPILE_FLAGS> <OBJECTS> <LINK_LIBRARIES> /LD /Fe<TARGET> ${_hl_link_tail}")
  set(CMAKE_${lang}_CREATE_SHARED_MODULE "${CMAKE_${lang}_CREATE_SHARED_LIBRARY}")
endforeach()
unset(_hl_link_head)
unset(_hl_link_tail)
