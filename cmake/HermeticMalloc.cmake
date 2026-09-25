# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# HERMETIC_MALLOC: replaces the C library's allocator in every executable of
# the project. A per-platform shim (malloc/shim_*.c) defines what the target's
# C runtime needs replaced and forwards it to a backend implementing
# malloc/hermetic_malloc.h: mimalloc, built from a pinned source, or a
# library target of the project.
#
# The toolchain only checks the request and fetches sources here; the targets
# are made by HermeticMallocProject.cmake, which every project() call includes
# (CMAKE_PROJECT_INCLUDE), at the end of the top-level CMakeLists.txt.

include_guard(GLOBAL)

set(HERMETIC_MALLOC_BUILTIN_BACKENDS mimalloc)

# Fetches the source of a built-in backend into <cache>/src. Sets ${OUT_DIR}
# and ${OUT_VERSION}.
function(hermetic_fetch_malloc_source NAME OUT_DIR OUT_VERSION)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/malloc_sources.json" json)
  string(JSON entry ERROR_VARIABLE err GET "${json}" "${NAME}")
  if(err)
    hermetic_fatal("No source listed for the allocator '${NAME}' in cmake/distributions/malloc_sources.json")
  endif()
  string(JSON version GET "${entry}" "version")
  string(JSON sha GET "${entry}" "sha256")
  string(JSON strip GET "${entry}" "strip_components")
  string(JSON n LENGTH "${entry}" "urls")
  math(EXPR last "${n} - 1")
  set(urls "")
  foreach(i RANGE ${last})
    string(JSON u GET "${entry}" "urls" ${i})
    list(APPEND urls "${u}")
  endforeach()
  hermetic_fetch_archive(NAME "${NAME}-${version}" KIND src SHA256 "${sha}" URLS ${urls}
    STRIP_COMPONENTS ${strip} OUT_DIR dir)
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
  set(${OUT_VERSION} "${version}" PARENT_SCOPE)
endfunction()

# Called by the toolchain file after hermetic_configure. Sets
# HERMETIC_MALLOC_SHIM (the shim source for the target), HERMETIC_MALLOC_BACKEND
# (a built-in backend's name, or the project target to use), and for a
# built-in backend HERMETIC_MALLOC_SOURCE_DIR and HERMETIC_MALLOC_VERSION.
macro(hermetic_malloc_setup)
  set(HERMETIC_MALLOC_BACKEND "")
  set(HERMETIC_MALLOC_SHIM "")
  set(HERMETIC_MALLOC_SOURCE_DIR "")
  set(HERMETIC_MALLOC_VERSION "")
  if(HERMETIC_MALLOC AND NOT HERMETIC_MALLOC STREQUAL "system")
    hermetic_target_info("${HERMETIC_TARGET}" _hm_tgt)
    if(_hm_tgt_OS STREQUAL "wasm")
      hermetic_fatal("HERMETIC_MALLOC: WebAssembly targets are freestanding, without a C library allocator to replace; link an allocator of your own as malloc instead")
    elseif(_hm_tgt_OS STREQUAL "windows" AND HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "gnu"
        AND NOT HERMETIC_MALLOC IN_LIST HERMETIC_MALLOC_BUILTIN_BACKENDS)
      hermetic_fatal("HERMETIC_MALLOC=${HERMETIC_MALLOC}: Windows targets on the GNU ABI run on ucrtbase.dll, whose heap only mimalloc redirects (HERMETIC_MALLOC=mimalloc)")
    elseif(_hm_tgt_OS STREQUAL "windows")
      set(HERMETIC_MALLOC_SHIM "${HERMETIC_DIR}/malloc/shim_windows.c")
    elseif(_hm_tgt_OS STREQUAL "darwin")
      set(HERMETIC_MALLOC_SHIM "${HERMETIC_DIR}/malloc/shim_darwin.c")
    else()
      set(HERMETIC_MALLOC_SHIM "${HERMETIC_DIR}/malloc/shim_elf.c")
    endif()
    set(HERMETIC_MALLOC_BACKEND "${HERMETIC_MALLOC}")
    if(HERMETIC_MALLOC IN_LIST HERMETIC_MALLOC_BUILTIN_BACKENDS)
      hermetic_fetch_malloc_source("${HERMETIC_MALLOC}" HERMETIC_MALLOC_SOURCE_DIR HERMETIC_MALLOC_VERSION)
      # mimalloc's compile-time knobs; overriding stays the shim's business.
      foreach(_hm_def IN LISTS HERMETIC_MALLOC_DEFINITIONS)
        if(_hm_def MATCHES "^-?D?(MI_MALLOC_OVERRIDE|MI_OSX_ZONE|MI_OSX_INTERPOSE|MI_SHARED_LIB|MI_SHARED_LIB_EXPORT|MI_WIN_NOREDIRECT|MI_LIBC_MUSL)(=|$)")
          hermetic_fatal("HERMETIC_MALLOC_DEFINITIONS: ${CMAKE_MATCH_1} is set by the toolchain, which decides how the allocator replaces the C library's")
        endif()
      endforeach()
    elseif(HERMETIC_MALLOC_DEFINITIONS)
      hermetic_fatal("HERMETIC_MALLOC_DEFINITIONS configures a built-in allocator (${HERMETIC_MALLOC_BUILTIN_BACKENDS}); a backend target of the project takes its own compile definitions")
    endif()
    # Executables get the shim once the project has defined them. try_compile
    # projects are left alone: checks do not need a different allocator.
    get_property(_hm_in_try_compile GLOBAL PROPERTY IN_TRY_COMPILE)
    if(NOT _hm_in_try_compile)
      if(CMAKE_PROJECT_INCLUDE AND NOT CMAKE_PROJECT_INCLUDE STREQUAL "${HERMETIC_DIR}/cmake/HermeticMallocProject.cmake")
        set(HERMETIC_MALLOC_CHAINED_PROJECT_INCLUDE "${CMAKE_PROJECT_INCLUDE}")
      endif()
      set(CMAKE_PROJECT_INCLUDE "${HERMETIC_DIR}/cmake/HermeticMallocProject.cmake")
    endif()
  endif()
endmacro()
