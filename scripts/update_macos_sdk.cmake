# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Lists the macOS SDK packages (CLTools_macOS{N,L}MOS_SDK.pkg of the Command
# Line Tools) in Apple's software update catalog and reports the ones
# cmake/distributions/macos_sdk.json does not know, downloading each new
# package to learn its SDK version and SHA-256:
#
#   cmake -P scripts/update_macos_sdk.cmake                       # report
#   cmake -DHERMETIC_LLVM_WRITE=ON -P scripts/update_macos_sdk.cmake   # add new SDK versions to the table
#
# Another package for an SDK version the table already lists (the catalog
# carries several Command Line Tools releases with the same SDK) is
# reported but not swapped in. Apple keeps packages online for years but not
# forever: a Wayback Machine snapshot (https://web.archive.org/save/<url>)
# makes a good "mirrors" entry for each one.

cmake_minimum_required(VERSION 3.19)
get_filename_component(HERMETIC_LLVM_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMCommon.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMRuntimes.cmake")
include("${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMDarwin.cmake")

set(catalog_url "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog")
set(table "${HERMETIC_LLVM_DIR}/cmake/distributions/macos_sdk.json")
set(payload_prefix "Payload/Library/Developer/CommandLineTools/SDKs")

hermetic_llvm_resolve_cache_dir()
hermetic_llvm_load_runtime_sources()
hermetic_llvm_detect_host(HERMETIC_LLVM_HOST_OS HERMETIC_LLVM_HOST_ARCH)
file(MAKE_DIRECTORY "${HERMETIC_LLVM_CACHE_DIR}/downloads")

set(catalog "${HERMETIC_LLVM_CACHE_DIR}/downloads/apple-sucatalog.xml")
hermetic_llvm_log("Downloading ${catalog_url}")
file(DOWNLOAD "${catalog_url}" "${catalog}" STATUS status TLS_VERIFY ON INACTIVITY_TIMEOUT 120)
list(GET status 0 code)
if(NOT code EQUAL 0)
  hermetic_llvm_fatal("Could not download the catalog: ${status}")
endif()
file(READ "${catalog}" text)
string(REGEX MATCHALL "https://swcdn\\.apple\\.com/content/downloads/[^<]*/CLTools_macOS[LN]MOS_SDK\\.pkg" urls "${text}")
list(REMOVE_DUPLICATES urls)
list(SORT urls)
list(LENGTH urls n)
hermetic_llvm_log("${n} SDK packages in the catalog")

hermetic_llvm_read_json("${table}" json)
string(JSON sdks GET "${json}" "sdks")
hermetic_llvm_macos_sdk_versions(versions default)
set(known_urls "")
foreach(v IN LISTS versions)
  string(JSON u GET "${sdks}" "${v}" "url")
  list(APPEND known_urls "${u}")
endforeach()

hermetic_llvm_fetch_extras(extras)
hermetic_llvm_host_executable("${extras}/bin/pkgutil" pkgutil)

set(changed FALSE)
foreach(url IN LISTS urls)
  if(url IN_LIST known_urls)
    continue()
  endif()
  string(SHA1 key "${url}")
  string(SUBSTRING "${key}" 0 8 key)
  get_filename_component(base "${url}" NAME)
  set(file "${HERMETIC_LLVM_CACHE_DIR}/downloads/${key}-${base}")
  if(NOT EXISTS "${file}")
    hermetic_llvm_log("Downloading ${url}")
    file(DOWNLOAD "${url}" "${file}.part" STATUS status TLS_VERIFY ON INACTIVITY_TIMEOUT 120)
    list(GET status 0 code)
    if(NOT code EQUAL 0)
      file(REMOVE "${file}.part")
      message(WARNING "Could not download ${url}: ${status}")
      continue()
    endif()
    file(RENAME "${file}.part" "${file}")
  endif()
  file(SHA256 "${file}" sha)
  # The Bom lists every payload path; the SDK directory is MacOSX<X.Y>.sdk.
  set(tmp "${HERMETIC_LLVM_CACHE_DIR}/downloads/${key}.expand")
  file(REMOVE_RECURSE "${tmp}")
  execute_process(COMMAND "${pkgutil}" --include Bom --expand "${file}" "${tmp}"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_VARIABLE err)
  if(NOT rc EQUAL 0 OR NOT EXISTS "${tmp}/Bom")
    message(WARNING "Could not expand ${base}: ${err}")
    continue()
  endif()
  file(STRINGS "${tmp}/Bom" bom REGEX "MacOSX[0-9]+\\.[0-9]+\\.sdk")
  file(REMOVE_RECURSE "${tmp}")
  string(REGEX MATCH "MacOSX([0-9]+\\.[0-9]+)\\.sdk" _ "${bom}")
  set(version "${CMAKE_MATCH_1}")
  if(NOT version)
    message(WARNING "No SDK directory in the payload of ${url}")
    continue()
  endif()
  if(version IN_LIST versions)
    hermetic_llvm_log("SDK ${version}: another package ${url} (sha256 ${sha}); the table keeps its current one")
    continue()
  endif()
  hermetic_llvm_log("SDK ${version}: new, ${url} (sha256 ${sha})")
  string(JSON json SET "${json}" "sdks" "${version}"
    "{\"url\": \"${url}\", \"sha256\": \"${sha}\", \"prefix\": \"${payload_prefix}/MacOSX${version}.sdk\"}")
  list(APPEND versions "${version}")
  set(changed TRUE)
endforeach()

if(changed AND HERMETIC_LLVM_WRITE)
  file(WRITE "${table}" "${json}\n")
  hermetic_llvm_log("Updated ${table}; review the default and add mirrors")
elseif(changed)
  hermetic_llvm_log("New SDK versions found; rerun with -DHERMETIC_LLVM_WRITE=ON to add them")
else()
  hermetic_llvm_log("The table lists every SDK version in the catalog (default ${default})")
endif()
