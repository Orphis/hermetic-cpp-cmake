# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Resolves host, target, compiler and runtime set (or macOS SDK) into the
# HERMETIC_LLVM_RESOLVED_* variables. Skipped inside try_compile projects,
# which receive the resolved values through CMAKE_TRY_COMPILE_PLATFORM_VARIABLES.

include_guard(GLOBAL)

function(hermetic_llvm_darwin_sdk_path OUT)
  if(DEFINED ENV{SDKROOT} AND IS_DIRECTORY "$ENV{SDKROOT}")
    set(${OUT} "$ENV{SDKROOT}" PARENT_SCOPE)
    return()
  endif()
  execute_process(COMMAND /usr/bin/xcrun --show-sdk-path --sdk macosx
    OUTPUT_VARIABLE sdk OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_VARIABLE err RESULT_VARIABLE result)
  if(NOT result EQUAL 0 OR NOT IS_DIRECTORY "${sdk}")
    hermetic_llvm_fatal("Could not locate the macOS SDK with xcrun (${err}); install Xcode or the Command Line Tools, or set HERMETIC_LLVM_SYSROOT")
  endif()
  set(${OUT} "${sdk}" PARENT_SCOPE)
endfunction()

# Locates the runtime set ID: HERMETIC_LLVM_RUNTIME_SET_DIR, a prebuilt from
# the index (unless HERMETIC_LLVM_RUNTIMES=build), or else a local build by
# calling BUILDER(<args>... <out var>). Sets ${OUT}.
function(hermetic_llvm_obtain_runtime_set LLVM_VERSION ID OUT BUILDER)
  set(dir "")
  if(HERMETIC_LLVM_RUNTIME_SET_DIR)
    if(NOT EXISTS "${HERMETIC_LLVM_RUNTIME_SET_DIR}/runtime-set.json")
      hermetic_llvm_fatal("HERMETIC_LLVM_RUNTIME_SET_DIR '${HERMETIC_LLVM_RUNTIME_SET_DIR}' is not a runtime set (no runtime-set.json)")
    endif()
    get_filename_component(dir "${HERMETIC_LLVM_RUNTIME_SET_DIR}" ABSOLUTE)
  else()
    set(mode "${HERMETIC_LLVM_RUNTIMES}")
    if(NOT mode)
      set(mode auto)
    endif()
    if(NOT mode STREQUAL "build")
      hermetic_llvm_download_runtime_set("${LLVM_VERSION}" "${ID}" dir)
    endif()
    if(NOT dir)
      if(mode STREQUAL "download")
        hermetic_llvm_fatal("No prebuilt runtime set ${ID} for LLVM ${LLVM_VERSION} is listed; set HERMETIC_LLVM_RUNTIMES=auto to build it locally")
      endif()
      string(REPLACE ";" "\" \"" build_args "${ARGN}")
      cmake_language(EVAL CODE "${BUILDER}(\"${build_args}\" dir)")
    endif()
  endif()
  set(${OUT} "${dir}" PARENT_SCOPE)
endfunction()

# Downloads a prebuilt runtime set if the index knows one. Sets ${OUT} to its
# directory, or "" when none is listed.
function(hermetic_llvm_download_runtime_set LLVM_VERSION ID OUT)
  set(dir "")
  foreach(file IN ITEMS "${HERMETIC_LLVM_DIR}/cmake/distributions/runtime_sets.json" ${HERMETIC_LLVM_RUNTIME_SETS_FILES})
    hermetic_llvm_read_json("${file}" json)
    string(JSON entry ERROR_VARIABLE err GET "${json}" "${LLVM_VERSION}" "${ID}")
    if(err)
      continue()
    endif()
    string(JSON url GET "${entry}" "url")
    string(JSON sha GET "${entry}" "sha256")
    hermetic_llvm_fetch_archive(NAME "${ID}" KIND "runtimes/${LLVM_VERSION}" SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS 0 OUT_DIR dir)
  endforeach()
  set(${OUT} "${dir}" PARENT_SCOPE)
endfunction()

macro(hermetic_llvm_resolve)
  if(NOT HERMETIC_LLVM_RESOLVED)
    hermetic_llvm_detect_host(HERMETIC_LLVM_HOST_OS HERMETIC_LLVM_HOST_ARCH)
    if(NOT DEFINED HERMETIC_LLVM_TARGET OR HERMETIC_LLVM_TARGET STREQUAL "" OR HERMETIC_LLVM_TARGET STREQUAL "host")
      set(HERMETIC_LLVM_TARGET "${HERMETIC_LLVM_HOST_OS}-${HERMETIC_LLVM_HOST_ARCH}")
    endif()
    hermetic_llvm_target_info("${HERMETIC_LLVM_TARGET}" _hl_target)
    hermetic_llvm_resolve_cache_dir()
    hermetic_llvm_load_runtime_sources()

    hermetic_llvm_provide_compiler("${HERMETIC_LLVM_VERSION}" "${HERMETIC_LLVM_HOST_OS}" "${HERMETIC_LLVM_HOST_ARCH}" _hl_dist)
    set(HERMETIC_LLVM_RESOLVED_ROOT "${_hl_dist_ROOT}")
    set(HERMETIC_LLVM_RESOLVED_VERSION "${_hl_dist_VERSION}")
    set(HERMETIC_LLVM_RESOLVED_RELEASE "${_hl_dist_RELEASE}")

    set(HERMETIC_LLVM_RESOLVED_RUNTIME_SET "")
    set(HERMETIC_LLVM_RESOLVED_SYSROOT "")
    set(HERMETIC_LLVM_RESOLVED_LIBC "")
    set(HERMETIC_LLVM_RESOLVED_WINSDK "")
    # Windows ABI: the MSVC one (clang-cl, the Microsoft runtime and SDK) or
    # the GNU one (MinGW-w64, no Microsoft download).
    set(HERMETIC_LLVM_RESOLVED_WINDOWS_ABI "")
    if(_hl_target_OS STREQUAL "windows")
      set(HERMETIC_LLVM_RESOLVED_WINDOWS_ABI "${HERMETIC_LLVM_WINDOWS_ABI}")
      if(NOT HERMETIC_LLVM_RESOLVED_WINDOWS_ABI OR HERMETIC_LLVM_RESOLVED_WINDOWS_ABI STREQUAL "default")
        set(HERMETIC_LLVM_RESOLVED_WINDOWS_ABI msvc)
      endif()
      if(NOT HERMETIC_LLVM_RESOLVED_WINDOWS_ABI MATCHES "^(msvc|gnu)$")
        hermetic_llvm_fatal("HERMETIC_LLVM_WINDOWS_ABI must be msvc or gnu, not '${HERMETIC_LLVM_WINDOWS_ABI}'")
      endif()
    endif()
    # C++ standard library: libc++ everywhere; Windows targets default to the
    # MSVC STL and may choose a libc++ runtime set instead.
    set(_hl_stdlib "${HERMETIC_LLVM_CXX_STDLIB}")
    if(NOT _hl_stdlib OR _hl_stdlib STREQUAL "default")
      if(_hl_target_OS STREQUAL "windows")
        set(_hl_stdlib msvc)
      else()
        set(_hl_stdlib libc++)
      endif()
    endif()
    if(_hl_target_OS STREQUAL "windows" AND HERMETIC_LLVM_RESOLVED_WINDOWS_ABI STREQUAL "gnu")
      if(_hl_stdlib STREQUAL "msvc")
        set(_hl_stdlib libc++)
      elseif(NOT _hl_stdlib STREQUAL "libc++")
        hermetic_llvm_fatal("HERMETIC_LLVM_CXX_STDLIB must be libc++ for Windows targets on the GNU ABI, not '${_hl_stdlib}'")
      endif()
    elseif(_hl_target_OS STREQUAL "windows")
      if(NOT _hl_stdlib MATCHES "^(msvc|libc\\+\\+)$")
        hermetic_llvm_fatal("HERMETIC_LLVM_CXX_STDLIB must be msvc or libc++ for Windows targets, not '${_hl_stdlib}'")
      endif()
    elseif(_hl_target_OS STREQUAL "wasm")
      # Freestanding: no C++ standard library at all.
      set(_hl_stdlib none)
    elseif(NOT _hl_stdlib STREQUAL "libc++")
      hermetic_llvm_fatal("HERMETIC_LLVM_CXX_STDLIB must be libc++ for ${_hl_target_OS} targets, not '${_hl_stdlib}'")
    endif()
    set(HERMETIC_LLVM_RESOLVED_CXX_STDLIB "${_hl_stdlib}")
    if(_hl_target_OS STREQUAL "windows" AND HERMETIC_LLVM_RESOLVED_WINDOWS_ABI STREQUAL "gnu")
      if(HERMETIC_LLVM_RUNTIME_SANITIZERS)
        hermetic_llvm_fatal("Sanitizer runtimes are not available for Windows targets on the GNU ABI")
      endif()
      hermetic_llvm_obtain_runtime_set("${HERMETIC_LLVM_RESOLVED_VERSION}" "${HERMETIC_LLVM_TARGET}-mingw"
        HERMETIC_LLVM_RESOLVED_RUNTIME_SET
        hermetic_llvm_build_mingw_runtime_set "${HERMETIC_LLVM_RESOLVED_ROOT}" "${HERMETIC_LLVM_RESOLVED_VERSION}"
          "${HERMETIC_LLVM_TARGET}")
    elseif(_hl_target_OS STREQUAL "windows")
      hermetic_llvm_provide_windows_sdk("${_hl_target_ARCH}" _hl_win)
      # One list, forwarded to try_compile projects as a single variable.
      set(HERMETIC_LLVM_RESOLVED_WINSDK
        "${_hl_win_MSVC_VERSION}" "${_hl_win_MSVC_COMPAT_VERSION}" "${_hl_win_MSVC_INCLUDE}" "${_hl_win_MSVC_LIB}"
        "${_hl_win_SDK_VERSION}" "${_hl_win_SDK_INCLUDE_VERSION}" "${_hl_win_SDK_INCLUDE}"
        "${_hl_win_SDK_UCRT_LIB}" "${_hl_win_SDK_UM_LIB}" "${_hl_win_OVERLAY}" "${_hl_win_TOOLS}")
      if(_hl_stdlib STREQUAL "libc++" OR HERMETIC_LLVM_RUNTIME_SANITIZERS)
        # libc++ (static, Microsoft ABI), compiler-rt builtins and optionally
        # the sanitizer, fuzzer and profile runtimes, built against this
        # toolset's C runtime.
        hermetic_llvm_obtain_runtime_set("${HERMETIC_LLVM_RESOLVED_VERSION}" "${HERMETIC_LLVM_TARGET}-msvc.${_hl_win_MSVC_VERSION}"
          HERMETIC_LLVM_RESOLVED_RUNTIME_SET
          hermetic_llvm_build_windows_runtime_set "${HERMETIC_LLVM_RESOLVED_ROOT}" "${HERMETIC_LLVM_RESOLVED_VERSION}"
            "${HERMETIC_LLVM_TARGET}")
      endif()
    elseif(_hl_target_OS STREQUAL "linux")
      if(HERMETIC_LLVM_SYSROOT AND NOT HERMETIC_LLVM_SYSROOT STREQUAL "default")
        # Bring-your-own sysroot: no runtime set, the sysroot must provide crt,
        # libc, C++ library and compiler runtime.
        if(HERMETIC_LLVM_SYSROOT MATCHES "^[a-z]+://")
          if(NOT HERMETIC_LLVM_SYSROOT_SHA256)
            hermetic_llvm_fatal("HERMETIC_LLVM_SYSROOT_SHA256 is required when HERMETIC_LLVM_SYSROOT is a URL")
          endif()
          string(SUBSTRING "${HERMETIC_LLVM_SYSROOT_SHA256}" 0 16 _hl_short)
          if(NOT DEFINED HERMETIC_LLVM_SYSROOT_STRIP_COMPONENTS OR HERMETIC_LLVM_SYSROOT_STRIP_COMPONENTS STREQUAL "")
            set(HERMETIC_LLVM_SYSROOT_STRIP_COMPONENTS 0)
          endif()
          hermetic_llvm_fetch_archive(NAME "url-${_hl_short}" KIND sysroot SHA256 "${HERMETIC_LLVM_SYSROOT_SHA256}"
            URLS "${HERMETIC_LLVM_SYSROOT}" STRIP_COMPONENTS "${HERMETIC_LLVM_SYSROOT_STRIP_COMPONENTS}" OUT_DIR HERMETIC_LLVM_RESOLVED_SYSROOT)
        elseif(IS_DIRECTORY "${HERMETIC_LLVM_SYSROOT}")
          get_filename_component(HERMETIC_LLVM_RESOLVED_SYSROOT "${HERMETIC_LLVM_SYSROOT}" ABSOLUTE)
        else()
          hermetic_llvm_fatal("HERMETIC_LLVM_SYSROOT '${HERMETIC_LLVM_SYSROOT}' is not a directory or URL")
        endif()
      else()
        if(NOT HERMETIC_LLVM_LIBC OR HERMETIC_LLVM_LIBC STREQUAL "default")
          set(HERMETIC_LLVM_LIBC "${HERMETIC_LLVM_DEFAULT_LIBC}")
        endif()
        hermetic_llvm_parse_libc("${HERMETIC_LLVM_LIBC}" _hl_libc_family _hl_libc_version)
        set(HERMETIC_LLVM_RESOLVED_LIBC "${HERMETIC_LLVM_LIBC}")
        hermetic_llvm_obtain_runtime_set("${HERMETIC_LLVM_RESOLVED_VERSION}" "${HERMETIC_LLVM_TARGET}-${HERMETIC_LLVM_LIBC}"
          HERMETIC_LLVM_RESOLVED_RUNTIME_SET
          hermetic_llvm_build_runtime_set "${HERMETIC_LLVM_RESOLVED_ROOT}" "${HERMETIC_LLVM_RESOLVED_VERSION}"
            "${HERMETIC_LLVM_TARGET}" "${HERMETIC_LLVM_LIBC}")
      endif()
    elseif(_hl_target_OS STREQUAL "wasm")
      # The compiler-rt builtins for the target, nothing else.
      hermetic_llvm_obtain_runtime_set("${HERMETIC_LLVM_RESOLVED_VERSION}" "${HERMETIC_LLVM_TARGET}-none"
        HERMETIC_LLVM_RESOLVED_RUNTIME_SET
        hermetic_llvm_build_wasm_runtime_set "${HERMETIC_LLVM_RESOLVED_ROOT}" "${HERMETIC_LLVM_RESOLVED_VERSION}"
          "${HERMETIC_LLVM_TARGET}")
    elseif(_hl_target_OS STREQUAL "darwin")
      if(NOT HERMETIC_LLVM_SYSROOT OR HERMETIC_LLVM_SYSROOT MATCHES "^(default|sdk)$")
        # The SDK from Apple's CDN, the same on every host.
        hermetic_llvm_provide_macos_sdk("${HERMETIC_LLVM_MACOS_SDK_VERSION}" HERMETIC_LLVM_RESOLVED_SYSROOT
          COMPILER_ROOT "${HERMETIC_LLVM_RESOLVED_ROOT}")
      elseif(HERMETIC_LLVM_SYSROOT STREQUAL "host")
        if(NOT HERMETIC_LLVM_HOST_OS STREQUAL "darwin")
          hermetic_llvm_fatal("HERMETIC_LLVM_SYSROOT=host (the SDK of the installed Xcode or Command Line Tools) needs a macOS host; leave it unset to download the SDK, or point it at an SDK directory")
        endif()
        hermetic_llvm_darwin_sdk_path(HERMETIC_LLVM_RESOLVED_SYSROOT)
      elseif(IS_DIRECTORY "${HERMETIC_LLVM_SYSROOT}")
        get_filename_component(HERMETIC_LLVM_RESOLVED_SYSROOT "${HERMETIC_LLVM_SYSROOT}" ABSOLUTE)
      elseif(NOT HERMETIC_LLVM_SYSROOT STREQUAL "none")
        hermetic_llvm_fatal("HERMETIC_LLVM_SYSROOT '${HERMETIC_LLVM_SYSROOT}' is not a directory")
      endif()
    endif()

    set(HERMETIC_LLVM_RESOLVED_HOST_OS "${HERMETIC_LLVM_HOST_OS}")
    set(HERMETIC_LLVM_RESOLVED_HOST_ARCH "${HERMETIC_LLVM_HOST_ARCH}")
    set(HERMETIC_LLVM_RESOLVED TRUE)

    hermetic_llvm_log("LLVM ${HERMETIC_LLVM_RESOLVED_VERSION} (${HERMETIC_LLVM_RESOLVED_RELEASE}) at ${HERMETIC_LLVM_RESOLVED_ROOT}")
    hermetic_llvm_log("Target ${HERMETIC_LLVM_TARGET}")
    if(HERMETIC_LLVM_RESOLVED_RUNTIME_SET)
      hermetic_llvm_log("Runtime set at ${HERMETIC_LLVM_RESOLVED_RUNTIME_SET}")
    endif()
    if(HERMETIC_LLVM_RESOLVED_SYSROOT)
      hermetic_llvm_log("Sysroot ${HERMETIC_LLVM_RESOLVED_SYSROOT}")
    endif()
    if(HERMETIC_LLVM_RESOLVED_WINSDK)
      list(GET HERMETIC_LLVM_RESOLVED_WINSDK 0 _hl_msvc_v)
      list(GET HERMETIC_LLVM_RESOLVED_WINSDK 5 _hl_sdk_v)
      hermetic_llvm_log("MSVC ${_hl_msvc_v} runtime and Windows SDK ${_hl_sdk_v}")
    endif()
  else()
    if(NOT DEFINED HERMETIC_LLVM_TARGET OR HERMETIC_LLVM_TARGET STREQUAL "" OR HERMETIC_LLVM_TARGET STREQUAL "host")
      set(HERMETIC_LLVM_TARGET "${HERMETIC_LLVM_RESOLVED_HOST_OS}-${HERMETIC_LLVM_RESOLVED_HOST_ARCH}")
    endif()
  endif()
endmacro()
