# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Included after every project() call when HERMETIC_MALLOC is set (see
# HermeticMalloc.cmake). At the end of the top-level CMakeLists.txt, when the
# project has defined its targets, every executable of the build tree gets the
# platform's shim as a source of its own, and links the backend:
#
# - The shim is compiled with each executable's own flags, so it can tell a
#   Windows C runtime flavour (MSVC_RUNTIME_LIBRARY, per configuration) or a
#   sanitizer that brings its own allocator, and stays empty then.
# - The backend is a static library built once (hermetic_malloc), or the
#   project's own target: nothing of it is linked unless the shim uses it.
#
# An executable opts out with the HERMETIC_MALLOC target property set to OFF.

if(HERMETIC_MALLOC_CHAINED_PROJECT_INCLUDE)
  include("${HERMETIC_MALLOC_CHAINED_PROJECT_INCLUDE}")
endif()

get_property(_hm_registered GLOBAL PROPERTY _HERMETIC_MALLOC_REGISTERED)
if(_hm_registered OR NOT HERMETIC_MALLOC_BACKEND)
  return()
endif()
set_property(GLOBAL PROPERTY _HERMETIC_MALLOC_REGISTERED TRUE)

# Policies of the functions below, whatever the project asks for.
cmake_policy(PUSH)
cmake_policy(VERSION 3.19)

# The executables of DIR and its subdirectories.
function(_hermetic_malloc_executables DIR OUT)
  set(result "")
  get_property(targets DIRECTORY "${DIR}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(target IN LISTS targets)
    get_target_property(type "${target}" TYPE)
    if(type STREQUAL "EXECUTABLE")
      list(APPEND result "${target}")
    endif()
  endforeach()
  get_property(subdirs DIRECTORY "${DIR}" PROPERTY SUBDIRECTORIES)
  foreach(subdir IN LISTS subdirs)
    _hermetic_malloc_executables("${subdir}" sub)
    list(APPEND result ${sub})
  endforeach()
  set(${OUT} "${result}" PARENT_SCOPE)
endfunction()

# mimalloc as the hermetic_malloc static library, from the sources copied into
# DIR: mimalloc.c includes mimalloc's single translation unit (src/static.c).
function(_hermetic_malloc_add_mimalloc DIR)
  set(src "${HERMETIC_MALLOC_SOURCE_DIR}")
  file(CONFIGURE OUTPUT "${DIR}/mimalloc.c"
    CONTENT "/* mimalloc @HERMETIC_MALLOC_VERSION@ (src/ is an include directory) */\n#include \"static.c\"\n" @ONLY)
  configure_file("${HERMETIC_DIR}/malloc/backend_mimalloc.c" "${DIR}/backend_mimalloc.c" COPYONLY)
  add_library(hermetic_malloc STATIC "${DIR}/mimalloc.c" "${DIR}/backend_mimalloc.c")
  target_include_directories(hermetic_malloc PRIVATE "${src}/include" "${src}/src" "${DIR}")
  # Third-party code: the project's warning flags are not its concern.
  if(CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC" OR MSVC)
    target_compile_options(hermetic_malloc PRIVATE /w)
    # mimalloc's C++ atomics with MSVC-style compilers, as its own build does.
    get_property(languages GLOBAL PROPERTY ENABLED_LANGUAGES)
    if("CXX" IN_LIST languages)
      set_source_files_properties("${DIR}/mimalloc.c" PROPERTIES LANGUAGE CXX)
      target_compile_options(hermetic_malloc PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/Zc:__cplusplus>)
    endif()
    # The shim only replaces the static release runtime (see shim_windows.c).
    set_target_properties(hermetic_malloc PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreaded)
    target_link_libraries(hermetic_malloc INTERFACE psapi shell32 user32 advapi32 bcrypt)
  else()
    target_compile_options(hermetic_malloc PRIVATE -w -fvisibility=hidden)
    if(NOT APPLE)
      target_compile_options(hermetic_malloc PRIVATE -ftls-model=initial-exec)
      target_link_libraries(hermetic_malloc INTERFACE pthread)
    endif()
  endif()
  if(HERMETIC_EFFECTIVE_LIBC STREQUAL "musl")
    target_compile_definitions(hermetic_malloc PRIVATE MI_LIBC_MUSL=1)
  endif()
endfunction()

function(_hermetic_malloc_attach)
  # Everything compiled goes through the build directory: CMake names the
  # objects of sources outside the source and build trees after their
  # absolute path, and the Ninja generators hand sources inside the build
  # tree to the compiler by a relative path, which keeps commands, debug info
  # and PDBs independent of where the toolchain and the cache are.
  set(dir "${CMAKE_BINARY_DIR}/hermetic-cpp-malloc")
  # With HERMETIC_REPRODUCIBLE the copies get a prefix map of their own, like
  # the cache: the build directory is not mapped otherwise.
  set(map "")
  if(HERMETIC_REPRODUCIBLE)
    if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
      if(CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL 19.40)
        set(map "/pathmap:${dir}=/hermetic-cpp/malloc")
      endif()
    elseif(CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
      set(map "/clang:-ffile-prefix-map=${dir}=/hermetic-cpp/malloc")
    else()
      set(map "-ffile-prefix-map=${dir}=/hermetic-cpp/malloc")
    endif()
    hermetic_debugger_source_map("/hermetic-cpp/malloc" "${dir}")
  endif()
  get_filename_component(shim_name "${HERMETIC_MALLOC_SHIM}" NAME)
  configure_file("${HERMETIC_MALLOC_SHIM}" "${dir}/${shim_name}" COPYONLY)
  configure_file("${HERMETIC_DIR}/malloc/hermetic_malloc.h" "${dir}/hermetic_malloc.h" COPYONLY)
  if(HERMETIC_MALLOC_SOURCE_DIR)
    _hermetic_malloc_add_mimalloc("${dir}")
    target_compile_options(hermetic_malloc PRIVATE ${map})
    set(backend hermetic_malloc)
  elseif(TARGET "${HERMETIC_MALLOC_BACKEND}")
    set(backend "${HERMETIC_MALLOC_BACKEND}")
  else()
    message(FATAL_ERROR "[hermetic-cpp] HERMETIC_MALLOC=${HERMETIC_MALLOC_BACKEND} is neither a built-in allocator (${HERMETIC_MALLOC_BUILTIN_BACKENDS}) nor a target of this project implementing malloc/hermetic_malloc.h")
  endif()
  _hermetic_malloc_executables("${CMAKE_SOURCE_DIR}" executables)
  set(count 0)
  foreach(exe IN LISTS executables)
    get_target_property(wanted "${exe}" HERMETIC_MALLOC)
    if(NOT wanted STREQUAL "wanted-NOTFOUND" AND NOT wanted)
      continue()
    endif()
    # Appended directly rather than with target_sources/target_link_libraries,
    # which some policy settings restrict to targets of the calling directory.
    set_property(TARGET "${exe}" APPEND PROPERTY SOURCES "${dir}/${shim_name}")
    if(map)
      get_target_property(exe_dir "${exe}" SOURCE_DIR)
      set_source_files_properties("${dir}/${shim_name}" DIRECTORY "${exe_dir}" PROPERTIES COMPILE_OPTIONS "${map}")
    endif()
    set_property(TARGET "${exe}" APPEND PROPERTY LINK_LIBRARIES "${backend}")
    math(EXPR count "${count} + 1")
  endforeach()
  message(STATUS "[hermetic-cpp] HERMETIC_MALLOC=${HERMETIC_MALLOC_BACKEND}: ${count} executable(s)")
endfunction()

cmake_policy(POP)

# The shim is C, whatever languages the project enabled.
get_property(_hm_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
if(NOT "C" IN_LIST _hm_languages)
  enable_language(C)
endif()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _hermetic_malloc_attach)
