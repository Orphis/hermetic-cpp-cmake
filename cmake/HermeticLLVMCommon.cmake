# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for the hermetic LLVM toolchain: logging, host detection,
# the download cache, and archive fetching/extraction with locking.

include_guard(GLOBAL)

# Environment fallbacks for options that CI systems set globally.
foreach(_hl_env HERMETIC_LLVM_KEEP_ARCHIVES HERMETIC_LLVM_KEEP_BUILD_DIRS HERMETIC_LLVM_SHOW_PROGRESS HERMETIC_LLVM_VERBOSE)
  if(NOT DEFINED ${_hl_env} AND DEFINED ENV{${_hl_env}})
    set(${_hl_env} "$ENV{${_hl_env}}")
  endif()
endforeach()

# Suffix of host executables (".exe" on Windows); CMAKE_HOST_EXECUTABLE_SUFFIX
# is not available in script mode.
set(HERMETIC_LLVM_HOST_EXE "")
if(CMAKE_HOST_WIN32)
  set(HERMETIC_LLVM_HOST_EXE ".exe")
endif()

# Sets ${OUT} to PATH, PATH.exe or PATH without suffix, whichever exists
# (prebuilt tool archives are inconsistent about the suffix on Windows).
function(hermetic_llvm_host_executable PATH OUT)
  if(EXISTS "${PATH}${HERMETIC_LLVM_HOST_EXE}")
    set(${OUT} "${PATH}${HERMETIC_LLVM_HOST_EXE}" PARENT_SCOPE)
    return()
  endif()
  if(CMAKE_HOST_WIN32 AND EXISTS "${PATH}")
    # cmd.exe (used by Ninja) only runs files with an executable extension.
    file(COPY_FILE "${PATH}" "${PATH}.exe" ONLY_IF_DIFFERENT)
    set(${OUT} "${PATH}.exe" PARENT_SCOPE)
    return()
  endif()
  set(${OUT} "${PATH}" PARENT_SCOPE)
endfunction()

# The name of the link every build directory gets to the cache directory
# when building Windows targets reproducibly (see hermetic_llvm_configure).
set(HERMETIC_LLVM_CACHE_LINK_NAME "hermetic-llvm")

# Makes LINK a link to the directory TARGET: a symbolic link on Unix hosts,
# a directory junction on Windows hosts (no privilege or developer mode
# needed, unlike a symbolic link there). An existing link to somewhere else
# is replaced; only the link itself is ever removed, never its contents.
# Sets ${OUT_OK} to TRUE when LINK resolves to TARGET afterwards, FALSE with
# a warning otherwise.
function(hermetic_llvm_link_directory TARGET LINK OUT_OK)
  set(${OUT_OK} FALSE PARENT_SCOPE)
  file(REAL_PATH "${TARGET}" target_real)
  if(EXISTS "${LINK}")
    file(REAL_PATH "${LINK}" link_real)
    if(link_real STREQUAL target_real)
      set(${OUT_OK} TRUE PARENT_SCOPE)
      return()
    endif()
    if(CMAKE_HOST_WIN32 AND IS_DIRECTORY "${LINK}")
      # rmdir removes a junction (or an empty directory), nothing inside it.
      file(TO_NATIVE_PATH "${LINK}" link_native)
      execute_process(COMMAND cmd /c rmdir "${link_native}" OUTPUT_QUIET ERROR_QUIET)
    elseif(IS_SYMLINK "${LINK}")
      file(REMOVE "${LINK}")
    endif()
    if(EXISTS "${LINK}")
      message(WARNING "[hermetic-llvm] ${LINK} exists and is not a link to ${TARGET}; remove it")
      return()
    endif()
  endif()
  get_filename_component(parent "${LINK}" DIRECTORY)
  file(MAKE_DIRECTORY "${parent}")
  if(CMAKE_HOST_WIN32)
    file(TO_NATIVE_PATH "${LINK}" link_native)
    file(TO_NATIVE_PATH "${target_real}" target_native)
    execute_process(COMMAND cmd /c mklink /J "${link_native}" "${target_native}"
      RESULT_VARIABLE rc OUTPUT_QUIET ERROR_VARIABLE err)
  else()
    file(CREATE_LINK "${target_real}" "${LINK}" SYMBOLIC RESULT rc)
    set(err "${rc}")
  endif()
  if(EXISTS "${LINK}")
    file(REAL_PATH "${LINK}" link_real)
    if(link_real STREQUAL target_real)
      set(${OUT_OK} TRUE PARENT_SCOPE)
      return()
    endif()
  endif()
  message(WARNING "[hermetic-llvm] Could not link ${LINK} to ${TARGET}: ${err}")
endfunction()

function(hermetic_llvm_log)
  message(STATUS "[hermetic-llvm] ${ARGN}")
endfunction()

function(hermetic_llvm_debug)
  if(HERMETIC_LLVM_VERBOSE)
    message(STATUS "[hermetic-llvm] ${ARGN}")
  endif()
endfunction()

function(hermetic_llvm_fatal)
  message(FATAL_ERROR "[hermetic-llvm] ${ARGN}")
endfunction()

# Sets ${OUT_OS} to one of linux/darwin/windows and ${OUT_ARCH} to one of
# x86_64/aarch64/armv7/riscv64 for the machine running CMake.
function(hermetic_llvm_detect_host OUT_OS OUT_ARCH)
  set(os "${CMAKE_HOST_SYSTEM_NAME}")
  if(NOT os)
    cmake_host_system_information(RESULT os QUERY OS_NAME)
  endif()
  if(os MATCHES "^(Darwin|macOS)$")
    set(os darwin)
  elseif(os STREQUAL "Linux")
    set(os linux)
  elseif(os MATCHES "^Windows")
    set(os windows)
  else()
    hermetic_llvm_fatal("Unsupported host OS: ${os}")
  endif()

  cmake_host_system_information(RESULT arch QUERY OS_PLATFORM)
  string(TOLOWER "${arch}" arch)
  if(arch MATCHES "^(arm64|aarch64)$")
    set(arch aarch64)
  elseif(arch MATCHES "^(x86_64|amd64|x64)$")
    set(arch x86_64)
  elseif(arch MATCHES "^armv7")
    set(arch armv7)
  elseif(arch STREQUAL "riscv64")
    set(arch riscv64)
  else()
    hermetic_llvm_fatal("Unsupported host architecture: ${arch}")
  endif()
  set(${OUT_OS} "${os}" PARENT_SCOPE)
  set(${OUT_ARCH} "${arch}" PARENT_SCOPE)
endfunction()

# Reads /etc/os-release on Linux hosts. Sets ${OUT_NAME} (ID, or a known
# ID_LIKE) and ${OUT_VERSION} (VERSION_ID), both possibly empty.
function(hermetic_llvm_detect_linux_distribution OUT_NAME OUT_VERSION)
  set(name "")
  set(version "")
  if(EXISTS /etc/os-release)
    file(STRINGS /etc/os-release lines)
    set(id "")
    set(id_like "")
    foreach(line IN LISTS lines)
      if(line MATCHES "^ID=\"?([^\"]*)\"?$")
        set(id "${CMAKE_MATCH_1}")
      elseif(line MATCHES "^ID_LIKE=\"?([^\"]*)\"?$")
        set(id_like "${CMAKE_MATCH_1}")
      elseif(line MATCHES "^VERSION_ID=\"?([^\"]*)\"?$")
        set(version "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    set(known almalinux amzn arch centos debian fedora freebsd manjaro ol pop raspbian rhel suse ubuntu)
    set(name "${id}")
    if(NOT id IN_LIST known AND id_like)
      string(REPLACE " " ";" id_like "${id_like}")
      foreach(candidate IN LISTS id_like)
        if(candidate IN_LIST known)
          set(name "${candidate}")
          break()
        endif()
      endforeach()
    endif()
  endif()
  set(${OUT_NAME} "${name}" PARENT_SCOPE)
  set(${OUT_VERSION} "${version}" PARENT_SCOPE)
endfunction()

# Resolves the on-disk cache directory into HERMETIC_LLVM_CACHE_DIR.
function(hermetic_llvm_resolve_cache_dir)
  if(HERMETIC_LLVM_CACHE_DIR)
    set(dir "${HERMETIC_LLVM_CACHE_DIR}")
  elseif(DEFINED ENV{HERMETIC_LLVM_CACHE_DIR} AND NOT "$ENV{HERMETIC_LLVM_CACHE_DIR}" STREQUAL "")
    set(dir "$ENV{HERMETIC_LLVM_CACHE_DIR}")
  elseif(CMAKE_HOST_WIN32)
    set(dir "$ENV{LOCALAPPDATA}/hermetic-llvm")
  elseif(DEFINED ENV{XDG_CACHE_HOME} AND NOT "$ENV{XDG_CACHE_HOME}" STREQUAL "")
    set(dir "$ENV{XDG_CACHE_HOME}/hermetic-llvm")
  else()
    set(dir "$ENV{HOME}/.cache/hermetic-llvm")
  endif()
  file(TO_CMAKE_PATH "${dir}" dir)
  get_filename_component(dir "${dir}" ABSOLUTE)
  set(HERMETIC_LLVM_CACHE_DIR "${dir}" PARENT_SCOPE)
endfunction()

# Reads a JSON file into ${OUT_VAR}, failing with a useful message.
function(hermetic_llvm_read_json PATH OUT_VAR)
  if(NOT EXISTS "${PATH}")
    hermetic_llvm_fatal("JSON file not found: ${PATH}")
  endif()
  file(READ "${PATH}" content)
  string(JSON _type ERROR_VARIABLE err TYPE "${content}")
  if(err)
    hermetic_llvm_fatal("Failed to parse ${PATH}: ${err}")
  endif()
  set(${OUT_VAR} "${content}" PARENT_SCOPE)
endfunction()

# Downloads (unless present in <cache>/downloads) and extracts an archive into
# <cache>/<KIND>/<NAME>, verifying its SHA-256. The extraction is atomic and
# guarded by a lock so concurrent configures (or try_compile runs) share one
# copy. Re-runs are a stamp-file check.
#
#   hermetic_llvm_fetch_archive(
#     NAME <dir name>  KIND <llvm|sysroot|...>  SHA256 <hex>
#     URLS <url>...  [STRIP_COMPONENTS <n>]  [PATTERNS <glob>...]
#     [PKGUTIL <exe> PKG_PREFIX <path>]  OUT_DIR <var>)
#
# With PKGUTIL and PKG_PREFIX the archive is an Apple flat package (.pkg),
# expanded with pkgutil (the cross-platform reimplementation from the
# hermetic-llvm extras prebuilt); only the payload directory PKG_PREFIX is
# extracted and becomes the destination.
function(hermetic_llvm_fetch_archive)
  cmake_parse_arguments(A "" "NAME;KIND;SHA256;HASH;STRIP_COMPONENTS;OUT_DIR;PKGUTIL;PKG_PREFIX" "URLS;PATTERNS" ${ARGN})
  foreach(required NAME KIND URLS OUT_DIR)
    if(NOT A_${required})
      hermetic_llvm_fatal("hermetic_llvm_fetch_archive: missing ${required}")
    endif()
  endforeach()
  if(NOT DEFINED A_STRIP_COMPONENTS)
    set(A_STRIP_COMPONENTS 0)
  endif()
  # The expected digest: SHA256 <hex>, or HASH <ALGO>=<hex> (SHA256/SHA512/...).
  if(A_HASH)
    if(NOT A_HASH MATCHES "^([A-Za-z0-9]+)=([0-9a-fA-F]+)$")
      hermetic_llvm_fatal("hermetic_llvm_fetch_archive: HASH must be <ALGO>=<hex>, not '${A_HASH}'")
    endif()
    string(TOUPPER "${CMAKE_MATCH_1}" A_ALGO)
    string(TOLOWER "${CMAKE_MATCH_2}" A_SHA256)
  elseif(A_SHA256)
    set(A_ALGO SHA256)
    string(TOLOWER "${A_SHA256}" A_SHA256)
  else()
    hermetic_llvm_fatal("hermetic_llvm_fetch_archive: missing SHA256 or HASH")
  endif()

  set(dest "${HERMETIC_LLVM_CACHE_DIR}/${A_KIND}/${A_NAME}")
  set(stamp "${dest}/.hermetic-llvm.stamp")
  if(EXISTS "${stamp}")
    file(READ "${stamp}" existing)
    string(STRIP "${existing}" existing)
    if(existing STREQUAL A_SHA256)
      set(${A_OUT_DIR} "${dest}" PARENT_SCOPE)
      return()
    endif()
  endif()

  file(MAKE_DIRECTORY "${HERMETIC_LLVM_CACHE_DIR}/locks" "${HERMETIC_LLVM_CACHE_DIR}/downloads" "${HERMETIC_LLVM_CACHE_DIR}/${A_KIND}")
  string(REPLACE "/" "-" lock_name "${A_KIND}-${A_NAME}")
  set(lock "${HERMETIC_LLVM_CACHE_DIR}/locks/${lock_name}.lock")
  file(LOCK "${lock}" GUARD FUNCTION TIMEOUT 7200 RESULT_VARIABLE lock_result)
  if(NOT lock_result EQUAL 0)
    hermetic_llvm_fatal("Could not acquire ${lock}: ${lock_result}")
  endif()
  # Another process may have completed the work while we waited.
  if(EXISTS "${stamp}")
    file(READ "${stamp}" existing)
    string(STRIP "${existing}" existing)
    if(existing STREQUAL A_SHA256)
      set(${A_OUT_DIR} "${dest}" PARENT_SCOPE)
      return()
    endif()
  endif()

  list(GET A_URLS 0 first_url)
  string(REGEX REPLACE "[?#].*$" "" basename "${first_url}")
  get_filename_component(basename "${basename}" NAME)
  if(NOT basename MATCHES "\\.(tar\\.(xz|gz|zst|bz2)|tgz|zip|vsix|nupkg|pkg)$")
    # URLs without a recognisable archive name (e.g. Chromium's sysroots are
    # addressed by hash); fall back to the target name.
    set(basename "${A_NAME}.tar.xz")
  endif()
  set(archive "${HERMETIC_LLVM_CACHE_DIR}/downloads/${basename}")

  if(EXISTS "${archive}")
    file(${A_ALGO} "${archive}" actual)
    if(NOT actual STREQUAL A_SHA256)
      hermetic_llvm_log("Discarding ${archive}: checksum mismatch")
      file(REMOVE "${archive}")
    else()
      hermetic_llvm_log("Using cached archive ${archive}")
    endif()
  endif()

  if(NOT EXISTS "${archive}")
    # The hash is checked separately: with EXPECTED_HASH, a failed transfer
    # is a hard CMake error and no retry or mirror would be attempted.
    set(downloaded FALSE)
    set(progress "")
    if(HERMETIC_LLVM_SHOW_PROGRESS)
      set(progress SHOW_PROGRESS)
    endif()
    if(NOT DEFINED HERMETIC_LLVM_DOWNLOAD_ATTEMPTS)
      set(HERMETIC_LLVM_DOWNLOAD_ATTEMPTS 3)
    endif()
    foreach(url IN LISTS A_URLS)
      foreach(attempt RANGE 1 ${HERMETIC_LLVM_DOWNLOAD_ATTEMPTS})
        hermetic_llvm_log("Downloading ${url}")
        file(REMOVE "${archive}.part")
        file(DOWNLOAD "${url}" "${archive}.part"
          STATUS status
          TLS_VERIFY ON
          INACTIVITY_TIMEOUT 120
          ${progress}
          ${HERMETIC_LLVM_DOWNLOAD_ARGS})
        list(GET status 0 code)
        list(GET status 1 text)
        if(code EQUAL 0)
          file(${A_ALGO} "${archive}.part" actual)
          if(actual STREQUAL A_SHA256)
            file(RENAME "${archive}.part" "${archive}")
            set(downloaded TRUE)
            break()
          endif()
          set(text "${A_ALGO} mismatch: expected ${A_SHA256}, got ${actual}")
        endif()
        message(WARNING "[hermetic-llvm] Download of ${url} failed (attempt ${attempt}/${HERMETIC_LLVM_DOWNLOAD_ATTEMPTS}): ${text}")
      endforeach()
      if(downloaded)
        break()
      endif()
    endforeach()
    file(REMOVE "${archive}.part")
    if(NOT downloaded)
      hermetic_llvm_fatal("Could not download ${A_NAME} from any of: ${A_URLS}")
    endif()
  endif()

  hermetic_llvm_log("Extracting ${basename} into ${dest}")
  set(tmp "${dest}.tmp")
  file(REMOVE_RECURSE "${tmp}" "${dest}")
  if(A_PKG_PREFIX)
    string(REGEX REPLACE "[^/]+" "" slashes "${A_PKG_PREFIX}")
    string(LENGTH "${slashes}" strip)
    math(EXPR strip "${strip} + 1")
    execute_process(COMMAND "${A_PKGUTIL}" --include "${A_PKG_PREFIX}/**" --strip-components ${strip}
        --expand-full "${archive}" "${tmp}"
      RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
    if(NOT rc EQUAL 0)
      set(hint "")
      if(CMAKE_HOST_WIN32)
        set(hint " The package contains symbolic links, which Windows only lets administrators, or users with Developer Mode enabled, create (hermeticbuild/hermetic-llvm#517); Dev Drives mishandle some of them (#580).")
      endif()
      hermetic_llvm_fatal("Could not expand ${basename} with pkgutil: ${err}${out}${hint}")
    endif()
    set(A_STRIP_COMPONENTS 0)
  else()
    set(patterns "")
    if(A_PATTERNS)
      set(patterns PATTERNS ${A_PATTERNS})
    endif()
    file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${tmp}" ${patterns})
  endif()

  # Archives made on macOS may carry AppleDouble (._name) and .DS_Store
  # entries, which Linux extracts as real files; drop them.
  file(GLOB_RECURSE junk "${tmp}/._*" "${tmp}/.DS_Store")
  file(GLOB top_junk "${tmp}/._*" "${tmp}/.DS_Store")
  if(junk OR top_junk)
    file(REMOVE ${junk} ${top_junk})
  endif()

  set(current "${tmp}")
  set(remaining "${A_STRIP_COMPONENTS}")
  while(remaining GREATER 0)
    file(GLOB entries LIST_DIRECTORIES true "${current}/*" "${current}/.*")
    list(FILTER entries EXCLUDE REGEX "/(\\.\\.?|\\._[^/]*|\\.DS_Store)$")
    list(LENGTH entries count)
    if(NOT count EQUAL 1)
      hermetic_llvm_fatal("Cannot strip ${A_STRIP_COMPONENTS} leading path component(s) from ${basename}: ${current} has ${count} entries (${entries})")
    endif()
    list(GET entries 0 current)
    if(NOT IS_DIRECTORY "${current}")
      hermetic_llvm_fatal("Cannot strip path components from ${basename}: ${current} is not a directory")
    endif()
    math(EXPR remaining "${remaining} - 1")
  endwhile()
  file(RENAME "${current}" "${dest}")
  file(REMOVE_RECURSE "${tmp}")
  file(WRITE "${stamp}" "${A_SHA256}\n")
  if(NOT HERMETIC_LLVM_KEEP_ARCHIVES)
    file(REMOVE "${archive}")
  endif()
  set(${A_OUT_DIR} "${dest}" PARENT_SCOPE)
endfunction()

# Appends every FLAG to the string variable VAR (space separated) in the
# caller's scope.
function(hermetic_llvm_append_flags VAR)
  set(value "${${VAR}}")
  foreach(flag IN LISTS ARGN)
    if(value STREQUAL "")
      set(value "${flag}")
    else()
      set(value "${value} ${flag}")
    endif()
  endforeach()
  set(${VAR} "${value}" PARENT_SCOPE)
endfunction()
