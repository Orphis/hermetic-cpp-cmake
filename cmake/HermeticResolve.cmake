# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Resolves host, target, compiler and runtime set (or macOS SDK) into the
# HERMETIC_RESOLVED_* variables. Skipped inside try_compile projects,
# which receive the resolved values through CMAKE_TRY_COMPILE_PLATFORM_VARIABLES.

include_guard(GLOBAL)

function(hermetic_darwin_sdk_path OUT)
  if(DEFINED ENV{SDKROOT} AND IS_DIRECTORY "$ENV{SDKROOT}")
    set(${OUT} "$ENV{SDKROOT}" PARENT_SCOPE)
    return()
  endif()
  execute_process(COMMAND /usr/bin/xcrun --show-sdk-path --sdk macosx
    OUTPUT_VARIABLE sdk OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_VARIABLE err RESULT_VARIABLE result)
  if(NOT result EQUAL 0 OR NOT IS_DIRECTORY "${sdk}")
    hermetic_fatal("Could not locate the macOS SDK with xcrun (${err}); install Xcode or the Command Line Tools, or set HERMETIC_SYSROOT")
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
      hermetic_fatal("HERMETIC_LLVM_RUNTIME_SET_DIR '${HERMETIC_LLVM_RUNTIME_SET_DIR}' is not a runtime set (no runtime-set.json)")
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
        hermetic_fatal("No prebuilt runtime set ${ID} for LLVM ${LLVM_VERSION} is listed; set HERMETIC_LLVM_RUNTIMES=auto to build it locally")
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
  foreach(file IN ITEMS "${HERMETIC_DIR}/cmake/distributions/runtime_sets.json" ${HERMETIC_LLVM_RUNTIME_SETS_FILES})
    hermetic_read_json("${file}" json)
    string(JSON entry ERROR_VARIABLE err GET "${json}" "${LLVM_VERSION}" "${ID}")
    if(err)
      continue()
    endif()
    string(JSON url GET "${entry}" "url")
    string(JSON sha GET "${entry}" "sha256")
    hermetic_fetch_archive(NAME "${ID}" KIND "runtimes/${LLVM_VERSION}" SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS 0 OUT_DIR dir)
  endforeach()
  set(${OUT} "${dir}" PARENT_SCOPE)
endfunction()

macro(hermetic_resolve)
  if(NOT HERMETIC_RESOLVED)
    hermetic_detect_host(HERMETIC_HOST_OS HERMETIC_HOST_ARCH)
    if(NOT DEFINED HERMETIC_TARGET OR HERMETIC_TARGET STREQUAL "" OR HERMETIC_TARGET STREQUAL "host")
      set(HERMETIC_TARGET "${HERMETIC_HOST_OS}-${HERMETIC_HOST_ARCH}")
    endif()
    hermetic_target_info("${HERMETIC_TARGET}" _hl_target)
    hermetic_resolve_cache_dir()
    hermetic_llvm_load_runtime_sources()

    hermetic_llvm_provide_compiler("${HERMETIC_LLVM_VERSION}" "${HERMETIC_HOST_OS}" "${HERMETIC_HOST_ARCH}" _hl_dist)
    set(HERMETIC_RESOLVED_LLVM_ROOT "${_hl_dist_ROOT}")
    set(HERMETIC_RESOLVED_LLVM_VERSION "${_hl_dist_VERSION}")
    set(HERMETIC_RESOLVED_LLVM_RELEASE "${_hl_dist_RELEASE}")

    set(HERMETIC_RESOLVED_LLVM_RUNTIME_SET "")
    set(HERMETIC_RESOLVED_SYSROOT "")
    set(HERMETIC_RESOLVED_LIBC "")
    set(HERMETIC_RESOLVED_WINSDK "")
    set(HERMETIC_RESOLVED_MSVC_BIN "")
    # Windows ABI: the MSVC one (clang-cl, the Microsoft runtime and SDK) or
    # the GNU one (MinGW-w64, no Microsoft download).
    set(HERMETIC_RESOLVED_WINDOWS_ABI "")
    if(_hl_target_OS STREQUAL "windows")
      set(HERMETIC_RESOLVED_WINDOWS_ABI "${HERMETIC_WINDOWS_ABI}")
      if(NOT HERMETIC_RESOLVED_WINDOWS_ABI OR HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "default")
        set(HERMETIC_RESOLVED_WINDOWS_ABI msvc)
      endif()
      if(NOT HERMETIC_RESOLVED_WINDOWS_ABI MATCHES "^(msvc|gnu)$")
        hermetic_fatal("HERMETIC_WINDOWS_ABI must be msvc or gnu, not '${HERMETIC_WINDOWS_ABI}'")
      endif()
    endif()
    # The compiler: clang (LLVM prebuilt) everywhere, or MSVC's cl.exe for
    # Windows targets on the MSVC ABI from a Windows host; lld-link and the
    # LLVM tools serve both.
    set(HERMETIC_RESOLVED_COMPILER "${HERMETIC_COMPILER}")
    if(NOT HERMETIC_RESOLVED_COMPILER MATCHES "^(llvm|msvc)$")
      hermetic_fatal("HERMETIC_COMPILER must be llvm or msvc, not '${HERMETIC_COMPILER}'")
    endif()
    if(HERMETIC_RESOLVED_COMPILER STREQUAL "msvc")
      if(NOT HERMETIC_HOST_OS STREQUAL "windows")
        hermetic_fatal("HERMETIC_COMPILER=msvc (cl.exe) needs a Windows host (x86_64 or aarch64, each with compilers for both target architectures); use the llvm compiler to cross-compile for Windows from elsewhere")
      endif()
      if(NOT _hl_target_OS STREQUAL "windows" OR NOT HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "msvc")
        hermetic_fatal("HERMETIC_COMPILER=msvc builds Windows targets on the MSVC ABI only (HERMETIC_TARGET=windows-*, HERMETIC_WINDOWS_ABI=msvc)")
      endif()
      if(HERMETIC_LLVM_RUNTIME_SANITIZERS)
        hermetic_fatal("HERMETIC_COMPILER=msvc: sanitizer runtime sets are built for clang; cl.exe's own /fsanitize=address ships with Visual Studio, not with the toolset packages")
      endif()
    endif()
    # C++ standard library: libc++ everywhere; Windows targets default to the
    # MSVC STL and may choose a libc++ runtime set instead.
    set(_hl_stdlib "${HERMETIC_CXX_STDLIB}")
    if(NOT _hl_stdlib OR _hl_stdlib STREQUAL "default")
      if(_hl_target_OS STREQUAL "windows")
        set(_hl_stdlib msvc)
      else()
        set(_hl_stdlib libc++)
      endif()
    endif()
    if(HERMETIC_RESOLVED_COMPILER STREQUAL "msvc")
      if(NOT _hl_stdlib STREQUAL "msvc")
        hermetic_fatal("HERMETIC_CXX_STDLIB must be msvc (the MSVC STL) with HERMETIC_COMPILER=msvc, not '${_hl_stdlib}'")
      endif()
    elseif(_hl_target_OS STREQUAL "windows" AND HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "gnu")
      if(_hl_stdlib STREQUAL "msvc")
        set(_hl_stdlib libc++)
      elseif(NOT _hl_stdlib STREQUAL "libc++")
        hermetic_fatal("HERMETIC_CXX_STDLIB must be libc++ for Windows targets on the GNU ABI, not '${_hl_stdlib}'")
      endif()
    elseif(_hl_target_OS STREQUAL "windows")
      if(NOT _hl_stdlib MATCHES "^(msvc|libc\\+\\+)$")
        hermetic_fatal("HERMETIC_CXX_STDLIB must be msvc or libc++ for Windows targets, not '${_hl_stdlib}'")
      endif()
    elseif(_hl_target_OS STREQUAL "wasm")
      # Freestanding: no C++ standard library at all.
      set(_hl_stdlib none)
    elseif(NOT _hl_stdlib STREQUAL "libc++")
      hermetic_fatal("HERMETIC_CXX_STDLIB must be libc++ for ${_hl_target_OS} targets, not '${_hl_stdlib}'")
    endif()
    set(HERMETIC_RESOLVED_CXX_STDLIB "${_hl_stdlib}")
    if(_hl_target_OS STREQUAL "windows" AND HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "gnu")
      if(HERMETIC_LLVM_RUNTIME_SANITIZERS)
        hermetic_fatal("Sanitizer runtimes are not available for Windows targets on the GNU ABI")
      endif()
      hermetic_llvm_obtain_runtime_set("${HERMETIC_RESOLVED_LLVM_VERSION}" "${HERMETIC_TARGET}-mingw"
        HERMETIC_RESOLVED_LLVM_RUNTIME_SET
        hermetic_llvm_build_mingw_runtime_set "${HERMETIC_RESOLVED_LLVM_ROOT}" "${HERMETIC_RESOLVED_LLVM_VERSION}"
          "${HERMETIC_TARGET}")
    elseif(_hl_target_OS STREQUAL "windows")
      hermetic_provide_windows_sdk("${_hl_target_ARCH}" _hl_win)
      set(HERMETIC_RESOLVED_MSVC_BIN "${_hl_win_MSVC_BIN}")
      # One list, forwarded to try_compile projects as a single variable.
      set(HERMETIC_RESOLVED_WINSDK
        "${_hl_win_MSVC_VERSION}" "${_hl_win_MSVC_COMPAT_VERSION}" "${_hl_win_MSVC_INCLUDE}" "${_hl_win_MSVC_LIB}"
        "${_hl_win_SDK_VERSION}" "${_hl_win_SDK_INCLUDE_VERSION}" "${_hl_win_SDK_INCLUDE}"
        "${_hl_win_SDK_UCRT_LIB}" "${_hl_win_SDK_UM_LIB}" "${_hl_win_OVERLAY}" "${_hl_win_TOOLS}")
      if(_hl_stdlib STREQUAL "libc++" OR HERMETIC_LLVM_RUNTIME_SANITIZERS)
        # libc++ (static, Microsoft ABI), compiler-rt builtins and optionally
        # the sanitizer, fuzzer and profile runtimes, built against this
        # toolset's C runtime.
        hermetic_llvm_obtain_runtime_set("${HERMETIC_RESOLVED_LLVM_VERSION}" "${HERMETIC_TARGET}-msvc.${_hl_win_MSVC_VERSION}"
          HERMETIC_RESOLVED_LLVM_RUNTIME_SET
          hermetic_llvm_build_windows_runtime_set "${HERMETIC_RESOLVED_LLVM_ROOT}" "${HERMETIC_RESOLVED_LLVM_VERSION}"
            "${HERMETIC_TARGET}")
      endif()
    elseif(_hl_target_OS STREQUAL "linux")
      if(HERMETIC_SYSROOT AND NOT HERMETIC_SYSROOT STREQUAL "default")
        # Bring-your-own sysroot: no runtime set, the sysroot must provide crt,
        # libc, C++ library and compiler runtime.
        if(HERMETIC_SYSROOT MATCHES "^[a-z]+://")
          if(NOT HERMETIC_SYSROOT_SHA256)
            hermetic_fatal("HERMETIC_SYSROOT_SHA256 is required when HERMETIC_SYSROOT is a URL")
          endif()
          string(SUBSTRING "${HERMETIC_SYSROOT_SHA256}" 0 16 _hl_short)
          if(NOT DEFINED HERMETIC_SYSROOT_STRIP_COMPONENTS OR HERMETIC_SYSROOT_STRIP_COMPONENTS STREQUAL "")
            set(HERMETIC_SYSROOT_STRIP_COMPONENTS 0)
          endif()
          hermetic_fetch_archive(NAME "url-${_hl_short}" KIND sysroot SHA256 "${HERMETIC_SYSROOT_SHA256}"
            URLS "${HERMETIC_SYSROOT}" STRIP_COMPONENTS "${HERMETIC_SYSROOT_STRIP_COMPONENTS}" OUT_DIR HERMETIC_RESOLVED_SYSROOT)
        elseif(IS_DIRECTORY "${HERMETIC_SYSROOT}")
          get_filename_component(HERMETIC_RESOLVED_SYSROOT "${HERMETIC_SYSROOT}" ABSOLUTE)
        else()
          hermetic_fatal("HERMETIC_SYSROOT '${HERMETIC_SYSROOT}' is not a directory or URL")
        endif()
      else()
        if(NOT HERMETIC_LIBC OR HERMETIC_LIBC STREQUAL "default")
          set(HERMETIC_LIBC "${HERMETIC_DEFAULT_LIBC}")
        endif()
        hermetic_parse_libc("${HERMETIC_LIBC}" _hl_libc_family _hl_libc_version)
        set(HERMETIC_RESOLVED_LIBC "${HERMETIC_LIBC}")
        hermetic_llvm_obtain_runtime_set("${HERMETIC_RESOLVED_LLVM_VERSION}" "${HERMETIC_TARGET}-${HERMETIC_LIBC}"
          HERMETIC_RESOLVED_LLVM_RUNTIME_SET
          hermetic_llvm_build_runtime_set "${HERMETIC_RESOLVED_LLVM_ROOT}" "${HERMETIC_RESOLVED_LLVM_VERSION}"
            "${HERMETIC_TARGET}" "${HERMETIC_LIBC}")
      endif()
    elseif(_hl_target_OS STREQUAL "wasm")
      # The compiler-rt builtins for the target, nothing else.
      hermetic_llvm_obtain_runtime_set("${HERMETIC_RESOLVED_LLVM_VERSION}" "${HERMETIC_TARGET}-none"
        HERMETIC_RESOLVED_LLVM_RUNTIME_SET
        hermetic_llvm_build_wasm_runtime_set "${HERMETIC_RESOLVED_LLVM_ROOT}" "${HERMETIC_RESOLVED_LLVM_VERSION}"
          "${HERMETIC_TARGET}")
    elseif(_hl_target_OS STREQUAL "darwin")
      if(NOT HERMETIC_SYSROOT OR HERMETIC_SYSROOT MATCHES "^(default|sdk)$")
        # The SDK from Apple's CDN, the same on every host.
        hermetic_provide_macos_sdk("${HERMETIC_MACOS_SDK_VERSION}" HERMETIC_RESOLVED_SYSROOT
          COMPILER_ROOT "${HERMETIC_RESOLVED_LLVM_ROOT}")
      elseif(HERMETIC_SYSROOT STREQUAL "host")
        if(NOT HERMETIC_HOST_OS STREQUAL "darwin")
          hermetic_fatal("HERMETIC_SYSROOT=host (the SDK of the installed Xcode or Command Line Tools) needs a macOS host; leave it unset to download the SDK, or point it at an SDK directory")
        endif()
        hermetic_darwin_sdk_path(HERMETIC_RESOLVED_SYSROOT)
      elseif(IS_DIRECTORY "${HERMETIC_SYSROOT}")
        get_filename_component(HERMETIC_RESOLVED_SYSROOT "${HERMETIC_SYSROOT}" ABSOLUTE)
      elseif(NOT HERMETIC_SYSROOT STREQUAL "none")
        hermetic_fatal("HERMETIC_SYSROOT '${HERMETIC_SYSROOT}' is not a directory")
      endif()
    endif()

    set(HERMETIC_RESOLVED_HOST_OS "${HERMETIC_HOST_OS}")
    set(HERMETIC_RESOLVED_HOST_ARCH "${HERMETIC_HOST_ARCH}")
    set(HERMETIC_RESOLVED TRUE)

    hermetic_log("LLVM ${HERMETIC_RESOLVED_LLVM_VERSION} (${HERMETIC_RESOLVED_LLVM_RELEASE}) at ${HERMETIC_RESOLVED_LLVM_ROOT}")
    hermetic_log("Target ${HERMETIC_TARGET}")
    if(HERMETIC_RESOLVED_LLVM_RUNTIME_SET)
      hermetic_log("Runtime set at ${HERMETIC_RESOLVED_LLVM_RUNTIME_SET}")
    endif()
    if(HERMETIC_RESOLVED_SYSROOT)
      hermetic_log("Sysroot ${HERMETIC_RESOLVED_SYSROOT}")
    endif()
    if(HERMETIC_RESOLVED_WINSDK)
      list(GET HERMETIC_RESOLVED_WINSDK 0 _hl_msvc_v)
      list(GET HERMETIC_RESOLVED_WINSDK 5 _hl_sdk_v)
      hermetic_log("MSVC ${_hl_msvc_v} runtime and Windows SDK ${_hl_sdk_v}")
    endif()
  else()
    if(NOT DEFINED HERMETIC_TARGET OR HERMETIC_TARGET STREQUAL "" OR HERMETIC_TARGET STREQUAL "host")
      set(HERMETIC_TARGET "${HERMETIC_RESOLVED_HOST_OS}-${HERMETIC_RESOLVED_HOST_ARCH}")
    endif()
  endif()
endmacro()
