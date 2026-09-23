# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# The macOS SDK for macOS targets, downloaded from Apple's software update
# CDN: the SDK package of the Command Line Tools (CLTools_macOS*_SDK.pkg,
# listed in cmake/distributions/macos_sdk.json) expanded with pkgutil from
# the hermetic-llvm extras prebuilt, so every host gets the same SDK without
# Xcode. Its license (the Xcode and Apple SDKs Agreement) is Apple's; set
# HERMETIC_LLVM_ACCEPT_APPLE_SDK_LICENSE=1 (variable or environment) to
# confirm. Only macOS SDKs are available this way: the SDKs of the other
# Apple platforms ship inside Xcode, which Apple does not serve without an
# account.

include_guard(GLOBAL)

function(hermetic_llvm_check_apple_sdk_license)
  set(value "${HERMETIC_LLVM_ACCEPT_APPLE_SDK_LICENSE}")
  if(NOT value AND DEFINED ENV{HERMETIC_LLVM_ACCEPT_APPLE_SDK_LICENSE})
    set(value "$ENV{HERMETIC_LLVM_ACCEPT_APPLE_SDK_LICENSE}")
  endif()
  string(TOLOWER "${value}" value)
  if(NOT value MATCHES "^(1|on|yes|y|true)$")
    hermetic_llvm_fatal("Building for macOS downloads the macOS SDK from Apple's Command Line Tools package, whose license you must be entitled to (the Xcode and Apple SDKs Agreement, https://www.apple.com/legal/sla/docs/xcode.pdf, which limits its use to Apple-branded computers). Set HERMETIC_LLVM_ACCEPT_APPLE_SDK_LICENSE=1 to confirm and let the toolchain download it, or HERMETIC_LLVM_SYSROOT=host on a macOS host to use the SDK of the installed Xcode or Command Line Tools.")
  endif()
endfunction()

# Lists the SDK versions of the table and its default.
function(hermetic_llvm_macos_sdk_versions OUT_VERSIONS OUT_DEFAULT)
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/macos_sdk.json" json)
  string(JSON sdks GET "${json}" "sdks")
  string(JSON n LENGTH "${sdks}")
  set(versions "")
  if(n GREATER 0)
    math(EXPR last "${n} - 1")
    foreach(i RANGE ${last})
      string(JSON v MEMBER "${sdks}" ${i})
      list(APPEND versions "${v}")
    endforeach()
  endif()
  string(JSON default GET "${json}" "default")
  set(${OUT_VERSIONS} "${versions}" PARENT_SCOPE)
  set(${OUT_DEFAULT} "${default}" PARENT_SCOPE)
endfunction()

# Sets ${OUT_NOTE} to the table's note about SDK VERSION, if any.
function(hermetic_llvm_macos_sdk_note VERSION OUT_NOTE)
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/macos_sdk.json" json)
  string(JSON note ERROR_VARIABLE err GET "${json}" "sdks" "${VERSION}" "note")
  if(err)
    set(note "")
  endif()
  set(${OUT_NOTE} "${note}" PARENT_SCOPE)
endfunction()

# Sets ${OUT} to TRUE when the compiler under COMPILER_ROOT can link against
# SDK VERSION: the table lists the TextAPI targets of an SDK's library stubs
# that older linkers reject (requires_tapi_targets), and the prebuilt's
# llvm-readtapi, which shares ld64.lld's TextAPI reader, is asked to read a
# stub listing them.
function(hermetic_llvm_macos_sdk_usable VERSION COMPILER_ROOT OUT)
  set(${OUT} TRUE PARENT_SCOPE)
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/macos_sdk.json" json)
  string(JSON targets ERROR_VARIABLE err GET "${json}" "sdks" "${VERSION}" "requires_tapi_targets")
  if(err)
    return()
  endif()
  string(JSON n LENGTH "${targets}")
  if(n EQUAL 0)
    return()
  endif()
  math(EXPR last "${n} - 1")
  set(list "")
  foreach(i RANGE ${last})
    string(JSON t GET "${targets}" ${i})
    list(APPEND list "${t}")
  endforeach()
  string(REPLACE ";" ", " list "${list}")
  set(${OUT} FALSE PARENT_SCOPE)
  hermetic_llvm_host_executable("${COMPILER_ROOT}/bin/llvm-readtapi" readtapi)
  if(NOT EXISTS "${readtapi}")
    return()
  endif()
  string(RANDOM LENGTH 8 id)
  set(stub "${HERMETIC_LLVM_CACHE_DIR}/build/tapi-probe-${id}.tbd")
  file(WRITE "${stub}" "--- !tapi-tbd\ntbd-version: 4\ntargets: [ ${list} ]\ninstall-name: '/usr/lib/libhermetic_llvm_probe.dylib'\n...\n")
  execute_process(COMMAND "${readtapi}" "${stub}" RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
  file(REMOVE "${stub}")
  if(rc EQUAL 0)
    set(${OUT} TRUE PARENT_SCOPE)
  endif()
endfunction()

# Provides the macOS SDK selected by SPEC (an exact version, a prefix such
# as 15 for its newest listed version, latest, or default) and sets
# ${OUT_DIR} to its directory (<cache>/macos/MacOSX<version>.sdk). With
# COMPILER_ROOT, SDKs that compiler cannot link against are left out of the
# choice (see hermetic_llvm_macos_sdk_usable): the default and latest select
# the newest usable one, an exact version or a prefix fails.
function(hermetic_llvm_provide_macos_sdk SPEC OUT_DIR)
  cmake_parse_arguments(arg "" "COMPILER_ROOT" "" ${ARGN})
  hermetic_llvm_check_apple_sdk_license()
  hermetic_llvm_macos_sdk_versions(versions default)
  set(what "macOS SDK (HERMETIC_LLVM_MACOS_SDK_VERSION)")
  hermetic_llvm_select_version("${what}" "${SPEC}" "${default}" "${versions}" version)
  if(arg_COMPILER_ROOT)
    hermetic_llvm_macos_sdk_usable("${version}" "${arg_COMPILER_ROOT}" usable)
    if(NOT usable)
      if(SPEC AND NOT SPEC MATCHES "^(default|latest)$")
        hermetic_llvm_fatal("The macOS ${version} SDK needs a newer compiler: its library stubs list targets the linker of ${arg_COMPILER_ROOT} does not read. Use a newer LLVM or another SDK version.")
      endif()
      set(usable_versions "")
      foreach(v IN LISTS versions)
        hermetic_llvm_macos_sdk_usable("${v}" "${arg_COMPILER_ROOT}" ok)
        if(ok)
          list(APPEND usable_versions "${v}")
        endif()
      endforeach()
      set(skipped "${version}")
      hermetic_llvm_select_version("${what}" latest "" "${usable_versions}" version)
      hermetic_llvm_log("macOS SDK ${skipped} needs a newer compiler; using ${version}")
    endif()
  endif()
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/macos_sdk.json" json)
  string(JSON entry GET "${json}" "sdks" "${version}")
  string(JSON url GET "${entry}" "url")
  string(JSON sha GET "${entry}" "sha256")
  string(JSON prefix GET "${entry}" "prefix")
  set(urls "${url}")
  string(JSON mirrors ERROR_VARIABLE err GET "${entry}" "mirrors")
  if(NOT err)
    string(JSON m LENGTH "${mirrors}")
    if(m GREATER 0)
      math(EXPR last "${m} - 1")
      foreach(i RANGE ${last})
        string(JSON mirror GET "${mirrors}" ${i})
        list(APPEND urls "${mirror}")
      endforeach()
    endif()
  endif()
  set(name "MacOSX${version}.sdk")
  if(NOT EXISTS "${HERMETIC_LLVM_CACHE_DIR}/macos/${name}/.hermetic-llvm.stamp")
    hermetic_llvm_log("Downloading the macOS ${version} SDK (Command Line Tools package, about 60 MB; expands to about 1 GB)")
  endif()
  # pkgutil from the extras prebuilt expands the package on every host.
  hermetic_llvm_fetch_extras(extras)
  hermetic_llvm_host_executable("${extras}/bin/pkgutil" pkgutil)
  hermetic_llvm_fetch_archive(NAME "${name}" KIND macos SHA256 "${sha}" URLS ${urls}
    PKGUTIL "${pkgutil}" PKG_PREFIX "${prefix}" OUT_DIR dir)
  foreach(probe usr/include/stdio.h usr/lib/libSystem.tbd usr/include/c++/v1/vector)
    if(NOT EXISTS "${dir}/${probe}")
      hermetic_llvm_fatal("The macOS ${version} SDK at ${dir} has no ${probe}; delete the directory to re-extract it")
    endif()
  endforeach()
  hermetic_llvm_log("macOS SDK ${version} at ${dir}")
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
endfunction()
