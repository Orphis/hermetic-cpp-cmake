# Copyright 2026 The hermetic-cpp-cmake Authors.
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
# Static libraries use lib.exe syntax when a lib front end is available:
# llvm-lib if the prebuilt ships it, else the "lib" subcommand of the
# multicall driver (bin/llvm, which every tool name links to). Both write a
# fresh archive, as lib.exe does, which is what CMake's rule slot assumes:
# the Ninja generator runs CREATE_STATIC_LIBRARY verbatim, without the
# "rm -f" it puts before ARCHIVE_CREATE. Without either, llvm-ar creates the
# archive (lld-link reads its archives) after deleting the old one, since
# "q" would otherwise append a second copy of every rebuilt object.
get_filename_component(_hl_tool_dir "${CMAKE_AR}" DIRECTORY)
get_filename_component(_hl_tool_ext "${CMAKE_AR}" EXT)
if(EXISTS "${_hl_tool_dir}/llvm-lib${_hl_tool_ext}")
  set(_hl_lib "\"${_hl_tool_dir}/llvm-lib${_hl_tool_ext}\"")
elseif(EXISTS "${_hl_tool_dir}/llvm${_hl_tool_ext}")
  set(_hl_lib "\"${_hl_tool_dir}/llvm${_hl_tool_ext}\" lib")
else()
  set(_hl_lib "")
endif()
# On Windows hosts the lib command runs through llvm_lib.cmake, which turns
# the backslashes CMake puts in object paths into forward slashes: lib.exe
# syntax stores members under the path given, and the archive must not
# depend on the host that built it.
if(_hl_lib AND CMAKE_HOST_WIN32)
  if(EXISTS "${_hl_tool_dir}/llvm-lib${_hl_tool_ext}")
    set(_hl_lib "<CMAKE_COMMAND> -DLIB=\"${_hl_tool_dir}/llvm-lib${_hl_tool_ext}\"")
  else()
    set(_hl_lib "<CMAKE_COMMAND> -DLIB=\"${_hl_tool_dir}/llvm${_hl_tool_ext}\" -DSUBCOMMAND=lib")
  endif()
  string(APPEND _hl_lib " -P \"${CMAKE_CURRENT_LIST_DIR}/llvm_lib.cmake\" --")
endif()
foreach(lang C CXX ASM_MASM RC)
  if(_hl_lib)
    set(CMAKE_${lang}_CREATE_STATIC_LIBRARY
      "${_hl_lib} /nologo <LINK_FLAGS> /out:<TARGET> <OBJECTS>")
  else()
    set(CMAKE_${lang}_CREATE_STATIC_LIBRARY
      "<CMAKE_COMMAND> -E rm -f <TARGET> && <CMAKE_AR> qcs <TARGET> <OBJECTS>")
  endif()
  set(CMAKE_${lang}_ARCHIVE_CREATE "<CMAKE_AR> qcs <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_APPEND "<CMAKE_AR> q <TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_FINISH "")
endforeach()
unset(_hl_lib)
unset(_hl_tool_dir)
unset(_hl_tool_ext)
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
# HERMETIC_WINDOWS_LINK_DRIVER_FLAGS: driver options for the link
# command only, after the compile flags so that they take precedence (the
# toolchain names the toolset, SDK and runtime set relative to the build
# directory here, see hermetic_windows_flags).
# HERMETIC_WINDOWS_LINK_TAIL: linker options placed after everything a
# project adds (the runtime set build uses it to override /DEBUG).
set(_hl_link_tail "/link /implib:<TARGET_IMPLIB> /pdb:<TARGET_PDB> /version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR> <LINK_FLAGS> ${HERMETIC_WINDOWS_LINK_TAIL}")
foreach(lang C CXX)
  set(CMAKE_${lang}_LINK_EXECUTABLE
    "<CMAKE_${lang}_COMPILER> ${_hl_link_head} <FLAGS> ${HERMETIC_WINDOWS_LINK_DRIVER_FLAGS} <OBJECTS> <LINK_LIBRARIES> /Fe<TARGET> ${_hl_link_tail}")
  set(CMAKE_${lang}_CREATE_SHARED_LIBRARY
    "<CMAKE_${lang}_COMPILER> ${_hl_link_head} <LANGUAGE_COMPILE_FLAGS> ${HERMETIC_WINDOWS_LINK_DRIVER_FLAGS} <OBJECTS> <LINK_LIBRARIES> /LD /Fe<TARGET> ${_hl_link_tail}")
  set(CMAKE_${lang}_CREATE_SHARED_MODULE "${CMAKE_${lang}_CREATE_SHARED_LIBRARY}")
endforeach()
unset(_hl_link_head)
unset(_hl_link_tail)

# HERMETIC_WINDOWS_COMPILE_TAIL: compile options placed after everything
# a project adds, including per-target options (the runtime set build uses
# it to drop the debug info compiler-rt insists on for the sanitizers).
if(HERMETIC_WINDOWS_COMPILE_TAIL)
  foreach(lang C CXX)
    string(REPLACE "<FLAGS> /Fo<OBJECT>" "<FLAGS> ${HERMETIC_WINDOWS_COMPILE_TAIL} /Fo<OBJECT>"
      CMAKE_${lang}_COMPILE_OBJECT "${CMAKE_${lang}_COMPILE_OBJECT}")
  endforeach()
endif()
