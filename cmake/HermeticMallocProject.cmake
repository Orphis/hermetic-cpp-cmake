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

# Compile settings shared by mimalloc's static library and DLL, built from the
# sources copied into DIR: mimalloc.c includes mimalloc's single translation
# unit (src/static.c), whose directory is an include directory.
function(_hermetic_malloc_mimalloc_settings TARGET DIR MAP)
  set(src "${HERMETIC_MALLOC_SOURCE_DIR}")
  target_include_directories(${TARGET} PRIVATE "${src}/include" "${src}/src" "${DIR}")
  # mimalloc's own knobs (MI_SECURE, MI_DEBUG, MI_DEFAULT_*, ...).
  target_compile_definitions(${TARGET} PRIVATE ${HERMETIC_MALLOC_DEFINITIONS})
  target_compile_options(${TARGET} PRIVATE ${MAP})
  # Third-party code: the project's warning flags are not its concern.
  if(CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC" OR MSVC)
    target_compile_options(${TARGET} PRIVATE /w)
    # mimalloc's C++ atomics with MSVC-style compilers, as its own build does.
    get_property(languages GLOBAL PROPERTY ENABLED_LANGUAGES)
    if("CXX" IN_LIST languages)
      set_source_files_properties("${DIR}/mimalloc.c" PROPERTIES LANGUAGE CXX)
      target_compile_options(${TARGET} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/Zc:__cplusplus>)
    endif()
    target_link_libraries(${TARGET} PRIVATE psapi shell32 user32 advapi32 bcrypt)
  else()
    target_compile_options(${TARGET} PRIVATE -w -fvisibility=hidden)
    if(NOT APPLE)
      target_compile_options(${TARGET} PRIVATE -ftls-model=initial-exec)
      target_link_libraries(${TARGET} INTERFACE pthread)
    endif()
  endif()
  if(HERMETIC_EFFECTIVE_LIBC STREQUAL "musl")
    target_compile_definitions(${TARGET} PRIVATE MI_LIBC_MUSL=1)
  endif()
endfunction()

# mimalloc as the hermetic_malloc static library, and for Windows targets on
# the MSVC ABI also as mimalloc.dll (hermetic_malloc_dll) with its redirection
# DLL, for executables on the DLL C runtime. Sets ${OUT_REDIRECT} to the
# redirection DLL, or to nothing.
function(_hermetic_malloc_add_mimalloc DIR MAP OUT_REDIRECT)
  set(src "${HERMETIC_MALLOC_SOURCE_DIR}")
  file(CONFIGURE OUTPUT "${DIR}/mimalloc.c"
    CONTENT "/* mimalloc @HERMETIC_MALLOC_VERSION@ (src/ is an include directory) */\n#include \"static.c\"\n" @ONLY)
  configure_file("${HERMETIC_DIR}/malloc/backend_mimalloc.c" "${DIR}/backend_mimalloc.c" COPYONLY)
  add_library(hermetic_malloc STATIC "${DIR}/mimalloc.c" "${DIR}/backend_mimalloc.c")
  _hermetic_malloc_mimalloc_settings(hermetic_malloc "${DIR}" "${MAP}")
  set(redirect "")
  if(CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC" OR MSVC)
    # The shim replaces the static runtime's allocator (see shim_windows.c).
    set_target_properties(hermetic_malloc PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreaded)
    # The DLL runtime is ucrtbase.dll's, which mimalloc-redirect.dll (a
    # prebuilt that ships with mimalloc's sources) patches when mimalloc.dll
    # loads, so that every module of the process allocates with mimalloc.
    # It finds mimalloc.dll by that name.
    set(suffix "")
    if(HERMETIC_TARGET MATCHES "aarch64")
      set(suffix "-arm64")
    endif()
    # Copied next to the other sources: an absolute path on the link line
    # would read as an option to clang-cl on hosts other than Windows.
    set(redirect "${DIR}/mimalloc-redirect${suffix}")
    configure_file("${src}/bin/mimalloc-redirect${suffix}.lib" "${redirect}.lib" COPYONLY)
    configure_file("${src}/bin/mimalloc-redirect${suffix}.dll" "${redirect}.dll" COPYONLY)
    add_library(hermetic_malloc_dll SHARED "${DIR}/mimalloc.c")
    _hermetic_malloc_mimalloc_settings(hermetic_malloc_dll "${DIR}" "${MAP}")
    target_compile_definitions(hermetic_malloc_dll PRIVATE MI_SHARED_LIB MI_SHARED_LIB_EXPORT MI_MALLOC_OVERRIDE)
    target_link_libraries(hermetic_malloc_dll PRIVATE "${redirect}.lib")
    set_target_properties(hermetic_malloc_dll PROPERTIES OUTPUT_NAME mimalloc
      ARCHIVE_OUTPUT_NAME mimalloc.dll PDB_NAME mimalloc.dll MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
    set(redirect "${redirect}.dll")
  endif()
  set(${OUT_REDIRECT} "${redirect}" PARENT_SCOPE)
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
  set(redirect "")
  if(HERMETIC_MALLOC_SOURCE_DIR)
    _hermetic_malloc_add_mimalloc("${dir}" "${map}" redirect)
    set(backends hermetic_malloc)
    if(redirect)
      # After the static library, whose members must resolve among
      # themselves; before everything else, for mimalloc.dll to come first
      # in the import table (the shim names __imp_mi_version).
      list(APPEND backends hermetic_malloc_dll)
    endif()
  elseif(TARGET "${HERMETIC_MALLOC_BACKEND}")
    set(backends "${HERMETIC_MALLOC_BACKEND}")
  else()
    message(FATAL_ERROR "[hermetic-cpp] HERMETIC_MALLOC=${HERMETIC_MALLOC_BACKEND} is neither a built-in allocator (${HERMETIC_MALLOC_BUILTIN_BACKENDS}) nor a target of this project implementing malloc/hermetic_malloc.h")
  endif()
  set(windows_redirect 0)
  if(redirect)
    set(windows_redirect 1)
  endif()
  get_filename_component(shim_name "${HERMETIC_MALLOC_SHIM}" NAME)
  configure_file("${HERMETIC_MALLOC_SHIM}" "${dir}/${shim_name}" COPYONLY)
  configure_file("${HERMETIC_DIR}/malloc/hermetic_malloc.h" "${dir}/hermetic_malloc.h" COPYONLY)
  file(CONFIGURE OUTPUT "${dir}/hermetic_malloc_config.h"
    CONTENT "/* Written by the hermetic-cpp toolchain. */\n#define HERMETIC_MALLOC_WINDOWS_REDIRECT ${windows_redirect}\n")

  get_property(multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
  _hermetic_malloc_executables("${CMAKE_SOURCE_DIR}" executables)
  set(count 0)
  set(copies "")
  foreach(exe IN LISTS executables)
    get_target_property(wanted "${exe}" HERMETIC_MALLOC)
    if(NOT wanted STREQUAL "wanted-NOTFOUND" AND NOT wanted)
      continue()
    endif()
    # Set directly rather than with target_sources/target_link_libraries,
    # which some policy settings restrict to targets of the calling directory.
    set_property(TARGET "${exe}" APPEND PROPERTY SOURCES "${dir}/${shim_name}")
    if(map)
      get_target_property(exe_dir "${exe}" SOURCE_DIR)
      set_source_files_properties("${dir}/${shim_name}" DIRECTORY "${exe_dir}" PROPERTIES COMPILE_OPTIONS "${map}")
    endif()
    get_target_property(libraries "${exe}" LINK_LIBRARIES)
    if(NOT libraries)
      set(libraries "")
    endif()
    set_property(TARGET "${exe}" PROPERTY LINK_LIBRARIES ${backends} ${libraries})
    if(redirect)
      # Executables on the DLL runtime (CMake's default) find mimalloc.dll and
      # the redirection DLL next to them. The runtime flavour may depend on
      # the configuration, hence a generator expression.
      get_target_property(runtime "${exe}" MSVC_RUNTIME_LIBRARY)
      if(NOT runtime)
        set(runtime "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
      endif()
      get_target_property(out "${exe}" RUNTIME_OUTPUT_DIRECTORY)
      if(NOT out)
        get_target_property(out "${exe}" BINARY_DIR)
        if(multi_config)
          string(APPEND out "/$<CONFIG>")
        endif()
      endif()
      list(APPEND copies "$<$<NOT:$<OR:$<STREQUAL:${runtime},MultiThreaded>,$<STREQUAL:${runtime},MultiThreadedDebug>>>:${out}>")
    endif()
    math(EXPR count "${count} + 1")
  endforeach()
  if(redirect)
    # Referencing the executables themselves ($<TARGET_FILE_DIR:...>) would
    # make the DLL depend on them, which link it: their directories are named.
    list(REMOVE_DUPLICATES copies)
    foreach(copy IN LISTS copies)
      add_custom_command(TARGET hermetic_malloc_dll POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E "$<IF:$<BOOL:${copy}>,make_directory,true>" "${copy}"
        COMMAND "${CMAKE_COMMAND}" -E "$<IF:$<BOOL:${copy}>,copy_if_different,true>"
          "$<TARGET_FILE:hermetic_malloc_dll>" "${redirect}" "${copy}"
        VERBATIM)
    endforeach()
  endif()
  message(STATUS "[hermetic-cpp] HERMETIC_MALLOC=${HERMETIC_MALLOC_BACKEND}: ${count} executable(s)")
endfunction()

cmake_policy(POP)

# The shim is C, whatever languages the project enabled.
get_property(_hm_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
if(NOT "C" IN_LIST _hm_languages)
  enable_language(C)
endif()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _hermetic_malloc_attach)
