# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runtime sets: per-target directories holding everything needed to compile
# and link for a Linux target without a distribution sysroot, built from
# source with the hermetic compiler the way hermeticbuild/hermetic-llvm does:
#
#   <set>/usr/include        libc headers (glibc headers or generated musl headers) + Linux UAPI headers
#   <set>/usr/include/c++/v1 libc++ headers
#   <set>/usr/lib            crt1.o Scrt1.o [rcrt1.o] crti.o crtn.o, libc (musl: libc.a; glibc: stub
#                            libc.so.6 & co, linker scripts, libc_nonshared.a), libc++.a libc++abi.a libunwind.a
#   <set>/resource           clang resource directory: the compiler's builtin headers plus
#                            lib/<triple>/libclang_rt.builtins.a, clang_rt.crtbegin.o, clang_rt.crtend.o
#                            (and sanitizer runtimes when built with them)
#   <set>/runtime-set.json   manifest
#
# A set is identified by "<target>-<libc>", e.g. linux-x86_64-gnu.2.28 or
# linux-aarch64-musl, and lives under <cache>/runtimes/<llvm version>/.

include_guard(GLOBAL)

# Bump when the build recipe changes incompatibly, to invalidate cached sets.
set(HERMETIC_LLVM_RUNTIME_RECIPE_VERSION 16)

function(hermetic_llvm_load_runtime_sources)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/runtime_sources.json" json)
  set(_HERMETIC_LLVM_RUNTIME_SOURCES "${json}" PARENT_SCOPE)
  string(JSON default_libc GET "${json}" "default_libc")
  set(HERMETIC_DEFAULT_LIBC "${default_libc}" PARENT_SCOPE)
endfunction()

# Lists the glibc versions the tables know about.
function(hermetic_glibc_versions OUT)
  if(NOT _HERMETIC_LLVM_RUNTIME_SOURCES)
    hermetic_llvm_load_runtime_sources()
  endif()
  string(JSON glibc GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "glibc")
  string(JSON n LENGTH "${glibc}")
  set(versions "")
  math(EXPR last "${n} - 1")
  foreach(i RANGE ${last})
    string(JSON v MEMBER "${glibc}" ${i})
    list(APPEND versions "${v}")
  endforeach()
  set(${OUT} "${versions}" PARENT_SCOPE)
endfunction()

# Validates a libc spec ("gnu.2.28" or "musl") and splits it.
function(hermetic_parse_libc LIBC OUT_FAMILY OUT_VERSION)
  if(LIBC STREQUAL "musl")
    set(${OUT_FAMILY} musl PARENT_SCOPE)
    set(${OUT_VERSION} "" PARENT_SCOPE)
  elseif(LIBC MATCHES "^gnu\\.([0-9]+\\.[0-9]+)$")
    hermetic_glibc_versions(versions)
    if(NOT CMAKE_MATCH_1 IN_LIST versions)
      string(REPLACE ";" ", " known "${versions}")
      hermetic_fatal("Unknown glibc version ${CMAKE_MATCH_1}; known versions: ${known}")
    endif()
    set(${OUT_FAMILY} gnu PARENT_SCOPE)
    set(${OUT_VERSION} "${CMAKE_MATCH_1}" PARENT_SCOPE)
  else()
    hermetic_fatal("HERMETIC_LIBC must be 'musl' or 'gnu.<version>' (e.g. gnu.2.28), not '${LIBC}'")
  endif()
endfunction()

# Target triple for a Linux arch and libc family.
function(hermetic_libc_triple ARCH FAMILY OUT)
  if(ARCH STREQUAL "armv7")
    set(triple "armv7-unknown-linux-${FAMILY}eabihf")
  else()
    set(triple "${ARCH}-unknown-linux-${FAMILY}")
  endif()
  set(${OUT} "${triple}" PARENT_SCOPE)
endfunction()

function(hermetic_kernel_arch ARCH OUT)
  if(ARCH STREQUAL "x86_64")
    set(${OUT} x86 PARENT_SCOPE)
  elseif(ARCH STREQUAL "aarch64")
    set(${OUT} arm64 PARENT_SCOPE)
  elseif(ARCH STREQUAL "riscv64")
    set(${OUT} riscv PARENT_SCOPE)
  elseif(ARCH STREQUAL "s390x")
    set(${OUT} s390 PARENT_SCOPE)
  elseif(ARCH STREQUAL "armv7")
    set(${OUT} arm PARENT_SCOPE)
  else()
    hermetic_fatal("No kernel headers architecture for ${ARCH}")
  endif()
endfunction()

function(hermetic_glibc_headers_triple ARCH OUT)
  if(ARCH STREQUAL "armv7")
    set(${OUT} arm-linux-gnueabihf PARENT_SCOPE)
  else()
    set(${OUT} "${ARCH}-linux-gnu" PARENT_SCOPE)
  endif()
endfunction()

# ---- Fetching inputs ------------------------------------------------------------

# The directories of the LLVM source tree that the runtime set builds read:
# LLVM's runtimes/ build, its CMake modules, the runtimes themselves, LLVM
# libc, whose shared headers libc++ includes (charconv), and third-party/
# (SipHash, for the aarch64 builtins). About 15% of the archive's files,
# which matters most on Windows hosts, where extracting the whole tree took
# minutes.
set(HERMETIC_LLVM_SOURCE_DIRS runtimes cmake llvm/cmake compiler-rt libcxx libcxxabi libunwind libc third-party)

function(hermetic_llvm_fetch_llvm_source VERSION OUT_DIR)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/llvm_sources.json" json)
  string(JSON entry ERROR_VARIABLE err GET "${json}" "${VERSION}")
  if(err)
    hermetic_fatal("No LLVM source archive is known for ${VERSION} (cmake/distributions/llvm_sources.json)")
  endif()
  string(JSON url GET "${entry}" "url")
  string(JSON sha GET "${entry}" "sha256")
  # Patterns start with the archive's top-level directory, named after the
  # archive (llvm-project-<version>.src); a wildcard would also match the
  # same names deeper in the tree.
  get_filename_component(top "${url}" NAME)
  string(REGEX REPLACE "\\.tar\\.[a-z0-9]+$" "" top "${top}")
  set(patterns "")
  foreach(sub IN LISTS HERMETIC_LLVM_SOURCE_DIRS)
    list(APPEND patterns "${top}/${sub}")
  endforeach()
  # A tree extracted with fewer directories (the list grew) is extracted
  # again; a whole tree from an older toolchain has them all and is kept.
  set(dest "${HERMETIC_CACHE_DIR}/src/llvm-project-${VERSION}")
  foreach(sub IN LISTS HERMETIC_LLVM_SOURCE_DIRS)
    if(EXISTS "${dest}/.hermetic-cpp.stamp" AND NOT IS_DIRECTORY "${dest}/${sub}")
      file(REMOVE "${dest}/.hermetic-cpp.stamp")
    endif()
  endforeach()
  hermetic_fetch_archive(NAME "llvm-project-${VERSION}" KIND src SHA256 "${sha}" URLS "${url}"
    STRIP_COMPONENTS 1 PATTERNS ${patterns} OUT_DIR dir)
  foreach(sub IN LISTS HERMETIC_LLVM_SOURCE_DIRS)
    if(NOT IS_DIRECTORY "${dir}/${sub}")
      hermetic_fatal("${sub} is missing from the LLVM source archive ${url} (expected under ${top}/)")
    endif()
  endforeach()
  hermetic_llvm_patch_llvm_source("${dir}")
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
endfunction()

# Source fixes hermetic-llvm applies to the LLVM tree (3rd_party/llvm-project/
# x.x/patches), done here as exact text replacements so no patch tool is
# needed; each is idempotent and fails loudly on an unexpected source.
function(hermetic_llvm_patch_llvm_source DIR)
  # libcxx-vcruntime-nothrow.patch: on the Microsoft ABI std::nothrow comes
  # from the C runtime (msvcrt.lib); libc++ defining it too makes lld-link
  # report a duplicate as soon as both archives are pulled in.
  set(file "${DIR}/libcxx/src/new_helpers.cpp")
  file(READ "${file}" content)
  set(before "#ifndef __GLIBCXX__\nconst nothrow_t nothrow{};\n#endif\n")
  set(after "#if !defined(__GLIBCXX__) && !defined(_LIBCPP_ABI_VCRUNTIME) // hermetic-llvm: libcxx-vcruntime-nothrow.patch\nconst nothrow_t nothrow{};\n#endif\n")
  string(FIND "${content}" "${after}" pos)
  if(pos EQUAL -1)
    string(FIND "${content}" "${before}" pos)
    if(pos EQUAL -1)
      hermetic_fatal("${file} does not contain the expected std::nothrow definition; update hermetic_llvm_patch_llvm_source")
    endif()
    string(REPLACE "${before}" "${after}" content "${content}")
    file(WRITE "${file}" "${content}")
  endif()
endfunction()

# The hermetic-llvm "extras" tool prebuilts (glibc-stubs-generator, pkgutil, ...).
function(hermetic_fetch_extras OUT_DIR)
  set(os "${HERMETIC_HOST_OS}")
  set(arch "${HERMETIC_HOST_ARCH}")
  if(arch STREQUAL "aarch64")
    set(arch arm64)
  elseif(arch STREQUAL "x86_64")
    set(arch amd64)
  endif()
  if(os STREQUAL "linux")
    set(key "linux-${arch}-musl")
  elseif(os STREQUAL "windows")
    set(key "windows-${arch}-gnu")
  else()
    set(key "${os}-${arch}")
  endif()
  string(JSON extras GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "extras")
  string(JSON version GET "${extras}" "version")
  string(JSON entry ERROR_VARIABLE err GET "${extras}" "hosts" "${key}")
  if(err)
    hermetic_fatal("No hermetic-llvm extras prebuilt for host ${key}")
  endif()
  string(JSON url GET "${entry}" "url")
  string(JSON sha GET "${entry}" "sha256")
  hermetic_fetch_archive(NAME "extras-${version}-${key}" KIND tools SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS 0 OUT_DIR dir)
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
endfunction()

# The mingw-w64 source tree (headers, CRT, winpthreads). Sets ${OUT_DIR}, ${OUT_VERSION}.
function(hermetic_fetch_mingw_source OUT_DIR OUT_VERSION)
  string(JSON entry GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "mingw")
  string(JSON version GET "${entry}" "version")
  string(JSON sha GET "${entry}" "sha256")
  string(JSON strip GET "${entry}" "strip_components")
  string(JSON urls GET "${entry}" "urls")
  string(JSON url GET "${urls}" 0)
  hermetic_fetch_archive(NAME "mingw-w64-${version}" KIND src SHA256 "${sha}" URLS "${url}"
    STRIP_COMPONENTS "${strip}" OUT_DIR dir)
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
  set(${OUT_VERSION} "${version}" PARENT_SCOPE)
endfunction()

function(hermetic_fetch_kernel_headers VERSION ARCH OUT_DIR)
  hermetic_kernel_arch("${ARCH}" karch)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/kernel_headers.json" json)
  string(JSON entry ERROR_VARIABLE err GET "${json}" "${VERSION}" "${karch}")
  if(err)
    hermetic_fatal("No Linux ${VERSION} UAPI headers for ${karch} in cmake/distributions/kernel_headers.json")
  endif()
  string(JSON url GET "${entry}" "url")
  string(JSON sha GET "${entry}" "sha256")
  hermetic_fetch_archive(NAME "linux-${VERSION}-${karch}" KIND headers SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS 1 OUT_DIR dir)
  set(${OUT_DIR} "${dir}/include" PARENT_SCOPE)
endfunction()

function(hermetic_fetch_glibc_headers VERSION ARCH OUT_DIR)
  hermetic_glibc_headers_triple("${ARCH}" triple)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/glibc_headers.json" json)
  string(JSON entry ERROR_VARIABLE err GET "${json}" "${VERSION}" "${triple}")
  if(err)
    hermetic_fatal("No glibc ${VERSION} headers for ${triple} in cmake/distributions/glibc_headers.json")
  endif()
  string(JSON url GET "${entry}" "url")
  string(JSON sha GET "${entry}" "sha256")
  hermetic_fetch_archive(NAME "glibc-headers-${triple}-${VERSION}" KIND headers SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS 1 OUT_DIR dir)
  set(${OUT_DIR} "${dir}/include" PARENT_SCOPE)
endfunction()

function(hermetic_fetch_glibc_source VERSION OUT_DIR)
  string(JSON entry GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "glibc" "${VERSION}")
  string(JSON urls_json GET "${entry}" "urls")
  string(JSON sha GET "${entry}" "sha256")
  string(JSON strip GET "${entry}" "strip_components")
  string(JSON n LENGTH "${urls_json}")
  set(urls "")
  math(EXPR last "${n} - 1")
  foreach(i RANGE ${last})
    string(JSON u GET "${urls_json}" ${i})
    list(APPEND urls "${u}")
  endforeach()
  hermetic_fetch_archive(NAME "glibc-${VERSION}" KIND src SHA256 "${sha}" URLS ${urls} STRIP_COMPONENTS ${strip} OUT_DIR dir)
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
endfunction()

function(hermetic_fetch_musl_source OUT_DIR OUT_VERSION)
  string(JSON entry GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "musl")
  string(JSON version GET "${entry}" "version")
  string(JSON url GET "${entry}" "urls" 0)
  string(JSON sha GET "${entry}" "sha256")
  string(JSON strip GET "${entry}" "strip_components")
  hermetic_fetch_archive(NAME "musl-${version}" KIND src SHA256 "${sha}" URLS "${url}" STRIP_COMPONENTS ${strip} OUT_DIR dir)
  set(${OUT_DIR} "${dir}" PARENT_SCOPE)
  set(${OUT_VERSION} "${version}" PARENT_SCOPE)
endfunction()

# ---- Building ---------------------------------------------------------------------

# Configures, builds and installs a CMake project with the bootstrap toolchain.
#   hermetic_llvm_build_stage(NAME <stage> SOURCE <dir> BUILD <dir> INSTALL_PREFIX <dir>
#     BOOTSTRAP <var=value>... ARGS <-D...>...)
function(hermetic_llvm_build_stage)
  cmake_parse_arguments(A "" "NAME;SOURCE;BUILD;INSTALL_PREFIX;LOG_DIR" "BOOTSTRAP;ARGS;CACHE" ${ARGN})
  file(MAKE_DIRECTORY "${A_LOG_DIR}")
  set(log "${A_LOG_DIR}/${A_NAME}.log")
  set(generator "")
  find_program(HERMETIC_NINJA ninja ninja-build)
  if(HERMETIC_NINJA)
    set(generator -G Ninja "-DCMAKE_MAKE_PROGRAM=${HERMETIC_NINJA}")
  endif()
  set(bootstrap "")
  foreach(kv IN LISTS A_BOOTSTRAP)
    list(APPEND bootstrap "-D${kv}")
  endforeach()
  file(REMOVE_RECURSE "${A_BUILD}")
  # Settings whose values contain ';' (CMake lists) go through an initial
  # cache file, since they cannot survive as execute_process arguments.
  set(cache_args "")
  if(A_CACHE)
    set(cache_content "")
    foreach(kv IN LISTS A_CACHE)
      string(REPLACE "|" ";" kv "${kv}")
      string(REGEX MATCH "^([^=]+)=(.*)$" _ "${kv}")
      string(APPEND cache_content "set(${CMAKE_MATCH_1} \"${CMAKE_MATCH_2}\" CACHE STRING \"\" FORCE)\n")
    endforeach()
    file(WRITE "${A_LOG_DIR}/${A_NAME}.cache.cmake" "${cache_content}")
    set(cache_args -C "${A_LOG_DIR}/${A_NAME}.cache.cmake")
  endif()
  hermetic_log("  ${A_NAME}: configuring (log: ${log})")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${A_SOURCE}" -B "${A_BUILD}" ${generator} ${cache_args}
      "-DCMAKE_TOOLCHAIN_FILE=${HERMETIC_DIR}/runtimes/bootstrap.toolchain.cmake"
      "-DCMAKE_INSTALL_PREFIX=${A_INSTALL_PREFIX}" -DCMAKE_BUILD_TYPE=Release
      ${bootstrap} ${A_ARGS}
    OUTPUT_FILE "${log}" ERROR_FILE "${log}" RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    hermetic_fatal("${A_NAME}: configure failed, see ${log}")
  endif()
  hermetic_log("  ${A_NAME}: building")
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${A_BUILD}"
    OUTPUT_FILE "${log}.build" ERROR_FILE "${log}.build" RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    hermetic_fatal("${A_NAME}: build failed, see ${log}.build")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --install "${A_BUILD}"
    OUTPUT_FILE "${log}.install" ERROR_FILE "${log}.install" RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    hermetic_fatal("${A_NAME}: install failed, see ${log}.install")
  endif()
  if(NOT HERMETIC_KEEP_BUILD_DIRS)
    file(REMOVE_RECURSE "${A_BUILD}")
  endif()
endfunction()


# True when the stamp of an existing runtime set covers a request: same
# recipe and LLVM version, and every requested component present (a set built
# with sanitizers also serves requests without them).
function(hermetic_llvm_runtime_set_satisfies STAMP_FILE RECIPE LLVM COMPONENTS OUT)
  set(${OUT} FALSE PARENT_SCOPE)
  if(NOT EXISTS "${STAMP_FILE}")
    return()
  endif()
  file(READ "${STAMP_FILE}" existing)
  string(STRIP "${existing}" existing)
  if(NOT existing MATCHES "^recipe=([0-9]+);llvm=([^;]+);components=(.*)$")
    return()
  endif()
  if(NOT CMAKE_MATCH_1 STREQUAL RECIPE OR NOT CMAKE_MATCH_2 STREQUAL LLVM)
    return()
  endif()
  string(REPLACE "," ";" have "${CMAKE_MATCH_3}")
  foreach(c IN LISTS COMPONENTS)
    if(NOT c IN_LIST have)
      return()
    endif()
  endforeach()
  set(${OUT} TRUE PARENT_SCOPE)
endfunction()

# Builds (or reuses) the runtime set for TARGET (e.g. linux-x86_64) and LIBC
# (gnu.2.28 / musl) with the compiler at LLVM_ROOT. Sets ${OUT_DIR}.
function(hermetic_llvm_build_runtime_set LLVM_ROOT LLVM_VERSION TARGET LIBC OUT_DIR)
  hermetic_target_info("${TARGET}" tgt)
  if(NOT tgt_OS STREQUAL "linux")
    hermetic_fatal("Runtime sets are only built for Linux targets, not ${TARGET}")
  endif()
  hermetic_parse_libc("${LIBC}" family libc_version)
  hermetic_libc_triple("${tgt_ARCH}" "${family}" triple)
  set(id "${TARGET}-${LIBC}")
  set(components builtins libcxx)
  if(HERMETIC_LLVM_RUNTIME_SANITIZERS)
    list(APPEND components sanitizers)
  endif()
  string(REPLACE ";" "," components_str "${components}")
  set(stamp_content "recipe=${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION};llvm=${LLVM_VERSION};components=${components_str}")

  set(set_dir "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}/${id}")
  set(stamp "${set_dir}/.hermetic-cpp.stamp")
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()
  file(MAKE_DIRECTORY "${HERMETIC_CACHE_DIR}/locks" "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}")
  file(LOCK "${HERMETIC_CACHE_DIR}/locks/runtimes-${LLVM_VERSION}-${id}.lock" GUARD FUNCTION TIMEOUT 7200)
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()

  hermetic_log("Building runtime set ${id} for LLVM ${LLVM_VERSION} (${triple}); this takes a few minutes")
  hermetic_llvm_load_runtime_sources()
  hermetic_llvm_fetch_llvm_source("${LLVM_VERSION}" llvm_src)
  set(tmp "${set_dir}.tmp")
  set(build_root "${HERMETIC_CACHE_DIR}/build/${LLVM_VERSION}/${id}")
  set(log_dir "${HERMETIC_CACHE_DIR}/logs/${LLVM_VERSION}/${id}")
  file(REMOVE_RECURSE "${tmp}" "${set_dir}" "${build_root}")
  file(MAKE_DIRECTORY "${tmp}/usr/include" "${tmp}/usr/lib" "${tmp}/resource")

  # Reproducibility: no build-host path may end up in the objects (__FILE__,
  # debug info, assertion messages). Map every directory involved to a fixed
  # name, longest prefixes first.
  set(prefix_map
    # Clang on a Windows host joins include paths with backslashes and
    # -ffile-reproducible does not undo that, so __FILE__ (only used in
    # assertion and abort messages by the runtimes) becomes the bare file
    # name, which every host derives identically. glibc >= 2.44 assert.h
    # uses __builtin_FILE() in C++ instead, which this cannot intercept;
    # the runtimes are therefore built with assertions off (below).
    -Wno-builtin-macro-redefined "-D__FILE__=__FILE_NAME__"
    "-ffile-prefix-map=${build_root}=/hermetic-cpp/build"
    "-ffile-prefix-map=${tmp}=/hermetic-cpp/runtime-set"
    "-ffile-prefix-map=${llvm_src}=/hermetic-cpp/llvm-project"
    "-ffile-prefix-map=${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
    "-ffile-prefix-map=${HERMETIC_DIR}=/hermetic-cpp/repo")
  string(REPLACE ";" " " prefix_map_flags "${prefix_map}")
  set(bootstrap
    "HERMETIC_LLVM_BOOTSTRAP_BIN=${LLVM_ROOT}/bin"
    "HERMETIC_LLVM_BOOTSTRAP_TRIPLE=${triple}"
    "HERMETIC_LLVM_BOOTSTRAP_SYSTEM_NAME=Linux"
    "HERMETIC_LLVM_BOOTSTRAP_PROCESSOR=${tgt_SYSTEM_PROCESSOR}"
    "HERMETIC_LLVM_BOOTSTRAP_PREFIX_MAP=${prefix_map_flags}")

  # 1. libc: headers, crt objects and libraries into <set>/usr.
  if(family STREQUAL "musl")
    hermetic_fetch_musl_source(musl_src musl_version)
    string(JSON kernel_version GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "musl" "kernel")
    hermetic_fetch_kernel_headers("${kernel_version}" "${tgt_ARCH}" kernel_headers)
    set(musl_arch "${tgt_ARCH}")
    if(musl_arch STREQUAL "armv7")
      set(musl_arch arm)
    endif()
    hermetic_llvm_build_stage(NAME libc SOURCE "${HERMETIC_DIR}/runtimes/musl" BUILD "${build_root}/libc"
      INSTALL_PREFIX "${tmp}" LOG_DIR "${log_dir}" BOOTSTRAP ${bootstrap}
      ARGS "-DMUSL_SOURCE_DIR=${musl_src}" "-DMUSL_ARCH=${musl_arch}")
    file(COPY "${kernel_headers}/" DESTINATION "${tmp}/usr/include")
    set(libc_description "musl ${musl_version}")
  else()
    string(JSON kernel_version GET "${_HERMETIC_LLVM_RUNTIME_SOURCES}" "glibc" "${libc_version}" "kernel")
    hermetic_fetch_glibc_source("${libc_version}" glibc_src)
    hermetic_fetch_glibc_headers("${libc_version}" "${tgt_ARCH}" glibc_headers)
    hermetic_fetch_kernel_headers("${kernel_version}" "${tgt_ARCH}" kernel_headers)
    hermetic_fetch_extras(extras)
    hermetic_host_executable("${extras}/bin/glibc-stubs-generator" stubs_generator)
    hermetic_llvm_build_stage(NAME libc SOURCE "${HERMETIC_DIR}/runtimes/glibc" BUILD "${build_root}/libc"
      INSTALL_PREFIX "${tmp}" LOG_DIR "${log_dir}" BOOTSTRAP ${bootstrap}
      ARGS "-DGLIBC_SOURCE_DIR=${glibc_src}" "-DGLIBC_VERSION=${libc_version}" "-DGLIBC_ARCH=${tgt_ARCH}"
           "-DGLIBC_HEADERS_DIR=${glibc_headers}" "-DKERNEL_HEADERS_DIR=${kernel_headers}"
           "-DGLIBC_STUBS_GENERATOR=${stubs_generator}"
           "-DGLIBC_ABILISTS=${HERMETIC_DIR}/runtimes/glibc/abilists")
    set(libc_description "glibc ${libc_version}")
  endif()

  # 2. compiler-rt builtins and crtbegin/crtend into the resource directory,
  #    together with the compiler's own builtin headers.
  hermetic_llvm_resource_dir("${LLVM_ROOT}" compiler_resource_dir)
  file(COPY "${compiler_resource_dir}/include" DESTINATION "${tmp}/resource")
  if(IS_DIRECTORY "${compiler_resource_dir}/share")
    file(COPY "${compiler_resource_dir}/share" DESTINATION "${tmp}/resource")
  endif()
  set(sanitizers OFF)
  if("sanitizers" IN_LIST components)
    set(sanitizers ON)
  endif()
  hermetic_llvm_build_stage(NAME compiler-rt SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/compiler-rt"
    INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}"
    BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_SYSROOT=${tmp}"
    ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DLLVM_INCLUDE_TESTS=OFF
      -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=ON
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF
      -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF)

  # 3. libunwind, libc++abi and libc++ (static, libc++abi merged into libc++.a).
  set(musl_flag OFF)
  if(family STREQUAL "musl")
    set(musl_flag ON)
  endif()
  hermetic_llvm_build_stage(NAME libcxx SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/libcxx"
    INSTALL_PREFIX "${tmp}/usr" LOG_DIR "${log_dir}"
    BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_SYSROOT=${tmp}" "HERMETIC_LLVM_BOOTSTRAP_RESOURCE_DIR=${tmp}/resource"
      "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=-rtlib=compiler-rt --unwindlib=none"
    CACHE "LLVM_ENABLE_RUNTIMES=libunwind|libcxxabi|libcxx"
    ARGS "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF -DLLVM_INCLUDE_TESTS=OFF
      # Static archives that also work inside shared libraries.
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      # Release runtimes: assertions off. They default to on for libunwind and
      # libc++abi, and with glibc >= 2.44 assert() embeds the include path via
      # __builtin_FILE(), which differs between Windows and Unix build hosts.
      -DLIBUNWIND_ENABLE_ASSERTIONS=OFF -DLIBCXXABI_ENABLE_ASSERTIONS=OFF
      -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_INSTALL_HEADERS=ON
      -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON
      -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
      -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_USE_COMPILER_RT=ON "-DLIBCXX_HAS_MUSL_LIBC=${musl_flag}"
      -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
      -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF)

  # 4. Sanitizer, fuzzer and profile runtimes: a second compiler-rt pass that
  #    links against the builtins and libc built above.
  set(sanitizer_json "")
  if(sanitizers)
    hermetic_llvm_build_stage(NAME sanitizers SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/sanitizers"
      INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}"
      BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_SYSROOT=${tmp}" "HERMETIC_LLVM_BOOTSTRAP_RESOURCE_DIR=${tmp}/resource"
        "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=-rtlib=compiler-rt --unwindlib=none" "HERMETIC_LLVM_BOOTSTRAP_LINK_TESTS=ON"
        "HERMETIC_LLVM_BOOTSTRAP_EXTRA_CXX_FLAGS=-stdlib=libc++" "HERMETIC_LLVM_BOOTSTRAP_CXX_LIBS=-nostdlib++ -lc++ -lc++abi -lunwind -lpthread -ldl"
      ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DLLVM_INCLUDE_TESTS=OFF
        -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
        -DCOMPILER_RT_BUILD_SANITIZERS=ON -DCOMPILER_RT_BUILD_LIBFUZZER=ON -DCOMPILER_RT_BUILD_PROFILE=ON
        -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
        -DCOMPILER_RT_USE_LIBCXX=OFF -DSANITIZER_CXX_ABI=libc++ -DCOMPILER_RT_SANITIZERS_TO_BUILD=all)
    set(sanitizer_json ", \"sanitizers\"")
  endif()

  # 5. Manifest and stamp.
  string(TIMESTAMP now UTC)
  file(WRITE "${tmp}/runtime-set.json" "{
  \"id\": \"${id}\",
  \"llvm_version\": \"${LLVM_VERSION}\",
  \"target\": \"${TARGET}\",
  \"libc\": \"${LIBC}\",
  \"libc_description\": \"${libc_description}\",
  \"triple\": \"${triple}\",
  \"kernel_headers\": \"${kernel_version}\",
  \"components\": [\"builtins\", \"libcxx\"${sanitizer_json}],
  \"recipe_version\": ${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION},
  \"built\": \"${now}\"
}
")
  file(WRITE "${tmp}/.hermetic-cpp.stamp" "${stamp_content}\n")
  file(RENAME "${tmp}" "${set_dir}")
  if(NOT HERMETIC_KEEP_BUILD_DIRS)
    file(REMOVE_RECURSE "${build_root}")
  endif()
  hermetic_log("Runtime set ${id} ready at ${set_dir}")
  set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
endfunction()

# Builds (or reuses) the runtime set for a Windows (MSVC ABI) TARGET: libc++
# as a static library on the Microsoft ABI (vcruntime as the C++ ABI library,
# no libc++abi or libunwind, like hermetic-llvm's windows_msvc route), once
# per C runtime flavour (/MD /MDd /MT /MTd, the values of CMake's
# MSVC_RUNTIME_LIBRARY), and compiler-rt builtins, all built with clang-cl
# against the toolset and SDK in HERMETIC_RESOLVED_WINSDK. Sets ${OUT_DIR}.
function(hermetic_llvm_build_windows_runtime_set LLVM_ROOT LLVM_VERSION TARGET OUT_DIR)
  hermetic_target_info("${TARGET}" tgt)
  if(NOT tgt_OS STREQUAL "windows")
    hermetic_fatal("hermetic_llvm_build_windows_runtime_set: ${TARGET} is not a Windows target")
  endif()
  set(winsdk "${HERMETIC_RESOLVED_WINSDK}")
  list(GET winsdk 0 msvc_version)
  list(GET winsdk 4 sdk_version)
  set(triple "${tgt_TRIPLE}")
  set(id "${TARGET}-msvc.${msvc_version}")
  set(components builtins libcxx)
  if(HERMETIC_LLVM_RUNTIME_SANITIZERS)
    list(APPEND components sanitizers)
  endif()
  string(REPLACE ";" "," components_str "${components}")
  set(stamp_content "recipe=${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION};llvm=${LLVM_VERSION};components=${components_str}")

  set(set_dir "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}/${id}")
  set(stamp "${set_dir}/.hermetic-cpp.stamp")
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()
  file(MAKE_DIRECTORY "${HERMETIC_CACHE_DIR}/locks" "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}")
  file(LOCK "${HERMETIC_CACHE_DIR}/locks/runtimes-${LLVM_VERSION}-${id}.lock" GUARD FUNCTION TIMEOUT 7200)
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()

  hermetic_log("Building runtime set ${id} for LLVM ${LLVM_VERSION} (${triple}, libc++ on the Microsoft ABI); this takes a few minutes")
  hermetic_llvm_load_runtime_sources()
  hermetic_llvm_fetch_llvm_source("${LLVM_VERSION}" llvm_src)
  set(tmp "${set_dir}.tmp")
  set(build_root "${HERMETIC_CACHE_DIR}/build/${LLVM_VERSION}/${id}")
  set(log_dir "${HERMETIC_CACHE_DIR}/logs/${LLVM_VERSION}/${id}")
  file(REMOVE_RECURSE "${tmp}" "${set_dir}" "${build_root}")
  file(MAKE_DIRECTORY "${tmp}/include" "${tmp}/lib" "${tmp}/resource")

  # Same path neutralisation as the Linux sets (see hermetic_llvm_build_runtime_set),
  # spelled for clang-cl. CodeView additionally records the absolute path of
  # each object file (S_OBJNAME), which no prefix map covers; an empty name
  # leaves that record blank.
  set(prefix_map
    -Wno-builtin-macro-redefined "-D__FILE__=__FILE_NAME__"
    -Xclang -object-file-name=-
    "/clang:-ffile-prefix-map=${build_root}=/hermetic-cpp/build"
    "/clang:-ffile-prefix-map=${tmp}=/hermetic-cpp/runtime-set"
    "/clang:-ffile-prefix-map=${llvm_src}=/hermetic-cpp/llvm-project"
    "/clang:-ffile-prefix-map=${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
    "/clang:-ffile-prefix-map=${HERMETIC_DIR}=/hermetic-cpp/repo")
  string(REPLACE ";" " " prefix_map_flags "${prefix_map}")
  hermetic_windows_flags("${winsdk}" "${tgt_ARCH}" win_compile win_link)
  string(REPLACE ";" " " win_compile_flags "${win_compile}")
  string(REPLACE ";" " " win_link_flags "${win_link}")
  set(bootstrap
    "HERMETIC_LLVM_BOOTSTRAP_BIN=${LLVM_ROOT}/bin"
    "HERMETIC_LLVM_BOOTSTRAP_TRIPLE=${triple}"
    "HERMETIC_LLVM_BOOTSTRAP_SYSTEM_NAME=Windows"
    "HERMETIC_LLVM_BOOTSTRAP_PROCESSOR=${tgt_SYSTEM_PROCESSOR}"
    "HERMETIC_LLVM_BOOTSTRAP_PREFIX_MAP=${prefix_map_flags}"
    "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=${win_compile_flags}"
    "HERMETIC_LLVM_BOOTSTRAP_LINK_FLAGS=${win_link_flags}")

  # 1. compiler-rt builtins into the resource directory (lib/windows/
  #    clang_rt.builtins-<arch>.lib), with the compiler's own builtin headers.
  hermetic_llvm_resource_dir("${LLVM_ROOT}" compiler_resource_dir)
  file(COPY "${compiler_resource_dir}/include" DESTINATION "${tmp}/resource")
  if(IS_DIRECTORY "${compiler_resource_dir}/share")
    file(COPY "${compiler_resource_dir}/share" DESTINATION "${tmp}/resource")
  endif()
  hermetic_llvm_build_stage(NAME compiler-rt SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/compiler-rt"
    INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}" BOOTSTRAP ${bootstrap}
    ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF -DLLVM_INCLUDE_TESTS=OFF
      -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF
      -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF)

  # 2. libc++ (static, Microsoft ABI, vcruntime as the ABI library, win32
  #    threads), once per C runtime flavour: objects record the flavour they
  #    were compiled with and lld-link refuses to mix them, so a consumer's
  #    MSVC_RUNTIME_LIBRARY must find a matching archive. Headers (identical
  #    across flavours) go to <set>/include/c++/v1, archives to
  #    <set>/lib/libc++-<md|mdd|mt|mtd>.lib.
  set(crt_flavours "md=MultiThreadedDLL" "mdd=MultiThreadedDebugDLL" "mt=MultiThreaded" "mtd=MultiThreadedDebug")
  foreach(flavour IN LISTS crt_flavours)
    string(REGEX MATCH "^([a-z]+)=(.*)$" _ "${flavour}")
    set(short "${CMAKE_MATCH_1}")
    set(crt "${CMAKE_MATCH_2}")
    set(install "${build_root}/libcxx-${short}-install")
    hermetic_llvm_build_stage(NAME "libcxx-${short}" SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/libcxx-${short}"
      INSTALL_PREFIX "${install}" LOG_DIR "${log_dir}" BOOTSTRAP ${bootstrap}
      ARGS -DLLVM_ENABLE_RUNTIMES=libcxx "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF -DLLVM_INCLUDE_TESTS=OFF
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=${crt}"
        -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON
        -DLIBCXX_ABI_FORCE_MICROSOFT=ON -DLIBCXX_CXX_ABI=vcruntime -DLIBCXX_HAS_WIN32_THREAD_API=ON
        -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF
        -DLIBCXX_INSTALL_MODULES=OFF -DLIBCXX_USE_COMPILER_RT=ON
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF)
    if(NOT EXISTS "${install}/lib/libc++.lib")
      hermetic_fatal("libc++ (${crt}) build did not produce ${install}/lib/libc++.lib")
    endif()
    file(RENAME "${install}/lib/libc++.lib" "${tmp}/lib/libc++-${short}.lib")
    if(short STREQUAL "md")
      file(COPY "${install}/include/c++" DESTINATION "${tmp}/include")
    endif()
    file(REMOVE_RECURSE "${install}")
  endforeach()
  # Force-included into every C++ compile by the toolchain (with
  # _LIBCPP_NO_AUTO_LINK): names the archive for this translation unit's
  # flavour through a default-library directive, as the MSVC STL's
  # yvals_core.h does, so CMake's MSVC_RUNTIME_LIBRARY is honoured per target.
  file(WRITE "${tmp}/include/__hermetic_llvm_libcxx_link.h" [=[
// Generated by hermetic-cpp-cmake: selects the libc++ archive matching the
// C runtime flavour of this translation unit (/MD /MDd /MT /MTd).
#pragma once
#if defined(_DLL)
#  if defined(_DEBUG)
#    pragma comment(lib, "libc++-mdd.lib")
#  else
#    pragma comment(lib, "libc++-md.lib")
#  endif
#else
#  if defined(_DEBUG)
#    pragma comment(lib, "libc++-mtd.lib")
#  else
#    pragma comment(lib, "libc++-mt.lib")
#  endif
#endif
]=])

  # 3. Sanitizer (asan, ubsan), fuzzer and profile runtimes: what compiler-rt
  #    supports on Windows. A second compiler-rt pass, compiled against the
  #    set's libc++ headers (libFuzzer needs a C++ library; its libc++
  #    references are resolved by the consumer's own libc++ archive) and
  #    linked through the driver with the builtins above. compiler-rt
  #    compiles its static runtimes with the static CRT, whose default-library
  #    directive would drag libcmt into every /MD consumer; /Zl keeps all
  #    objects CRT-neutral (as compiler-rt already does for ASan), so the
  #    consumer's MSVC_RUNTIME_LIBRARY decides, and the ASan DLL is linked
  #    against the dynamic CRT explicitly.
  set(sanitizer_json "")
  if("sanitizers" IN_LIST components)
    hermetic_llvm_build_stage(NAME sanitizers SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/sanitizers"
      INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}"
      BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_LINK_TESTS=ON"
        "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=-resource-dir=${tmp}/resource -nobuiltininc /imsvc${tmp}/resource/include /D_CRT_STDIO_ISO_WIDE_SPECIFIERS /Zl ${win_compile_flags}"
        "HERMETIC_LLVM_BOOTSTRAP_CXX_FIRST_FLAGS=/imsvc${tmp}/include/c++/v1 /D_LIBCPP_NO_AUTO_LINK"
        "HERMETIC_LLVM_BOOTSTRAP_LINK_FLAGS=${win_link_flags} /LIBPATH:${tmp}/lib msvcrt.lib"
        # No PDB for the ASan DLL: compiler-rt links it with /DEBUG, and the
        # PDB's GUID (recorded in the DLL) would depend on the build host's
        # paths; placed last so it overrides compiler-rt's own flag.
        "HERMETIC_LLVM_BOOTSTRAP_LINK_TAIL=/DEBUG:NONE"
        # No debug info in the sanitizer runtimes: compiler-rt appends /Z7
        # for MSVC-style compilers after every flag a toolchain can set, and
        # on a Windows host clang joins the mapped include paths in the
        # CodeView records with backslashes, which made the archives depend
        # on the build host. Frames inside the runtime itself lose their
        # line numbers in sanitizer reports; user code is unaffected.
        "HERMETIC_LLVM_BOOTSTRAP_COMPILE_TAIL=/clang:-g0"
      ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF -DLLVM_INCLUDE_TESTS=OFF
        -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
        # ubsan is always built with the sanitizer common parts; asan is the
        # only other one compiler-rt supports on Windows.
        -DCOMPILER_RT_BUILD_SANITIZERS=ON -DCOMPILER_RT_SANITIZERS_TO_BUILD=asan
        -DCOMPILER_RT_BUILD_LIBFUZZER=ON -DCOMPILER_RT_BUILD_PROFILE=ON
        -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF
        -DCOMPILER_RT_BUILD_GWP_ASAN=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_USE_LIBCXX=OFF)
    set(sanitizer_json ", \"sanitizers\"")
  endif()

  # 4. Manifest and stamp.
  string(TIMESTAMP now UTC)
  file(WRITE "${tmp}/runtime-set.json" "{
  \"id\": \"${id}\",
  \"llvm_version\": \"${LLVM_VERSION}\",
  \"target\": \"${TARGET}\",
  \"cxx_stdlib\": \"libc++\",
  \"msvc_version\": \"${msvc_version}\",
  \"windows_sdk_version\": \"${sdk_version}\",
  \"triple\": \"${triple}\",
  \"components\": [\"builtins\", \"libcxx\"${sanitizer_json}],
  \"recipe_version\": ${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION},
  \"built\": \"${now}\"
}
")
  file(WRITE "${tmp}/.hermetic-cpp.stamp" "${stamp_content}\n")
  file(RENAME "${tmp}" "${set_dir}")
  if(NOT HERMETIC_KEEP_BUILD_DIRS)
    file(REMOVE_RECURSE "${build_root}")
  endif()
  hermetic_log("Runtime set ${id} ready at ${set_dir}")
  set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
endfunction()

# Builds (or reuses) the runtime set for a Windows TARGET on the GNU ABI
# (MinGW-w64, like hermetic-llvm's default Windows platforms): mingw-w64's
# headers, CRT (UCRT) and import libraries under <set>/<arch>-w64-mingw32
# (the directory clang's MinGW driver looks for under a sysroot), the
# compiler-rt builtins in <set>/resource, and static libunwind, libc++abi
# and libc++ (win32 threads). The set is identified by "<target>-mingw".
# Sets ${OUT_DIR}.
function(hermetic_llvm_build_mingw_runtime_set LLVM_ROOT LLVM_VERSION TARGET OUT_DIR)
  hermetic_target_info("${TARGET}" tgt)
  if(NOT tgt_OS STREQUAL "windows")
    hermetic_fatal("hermetic_llvm_build_mingw_runtime_set: ${TARGET} is not a Windows target")
  endif()
  hermetic_windows_gnu_triple("${tgt_ARCH}" triple)
  set(subdir "${tgt_ARCH}-w64-mingw32")
  set(id "${TARGET}-mingw")
  set(components builtins libcxx)
  string(REPLACE ";" "," components_str "${components}")
  set(stamp_content "recipe=${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION};llvm=${LLVM_VERSION};components=${components_str}")

  set(set_dir "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}/${id}")
  set(stamp "${set_dir}/.hermetic-cpp.stamp")
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()
  file(MAKE_DIRECTORY "${HERMETIC_CACHE_DIR}/locks" "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}")
  file(LOCK "${HERMETIC_CACHE_DIR}/locks/runtimes-${LLVM_VERSION}-${id}.lock" GUARD FUNCTION TIMEOUT 7200)
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()

  hermetic_log("Building runtime set ${id} for LLVM ${LLVM_VERSION} (${triple}, mingw-w64 with UCRT, libc++); this takes a few minutes")
  hermetic_llvm_load_runtime_sources()
  hermetic_llvm_fetch_llvm_source("${LLVM_VERSION}" llvm_src)
  hermetic_fetch_mingw_source(mingw_src mingw_version)
  set(tmp "${set_dir}.tmp")
  set(build_root "${HERMETIC_CACHE_DIR}/build/${LLVM_VERSION}/${id}")
  set(log_dir "${HERMETIC_CACHE_DIR}/logs/${LLVM_VERSION}/${id}")
  file(REMOVE_RECURSE "${tmp}" "${set_dir}" "${build_root}")
  file(MAKE_DIRECTORY "${tmp}/${subdir}" "${tmp}/resource")

  # COFF objects for the GNU environment get the current time as their
  # timestamp unless told otherwise (the MSVC route gets that from /Brepro).
  set(prefix_map
    -Wno-builtin-macro-redefined "-D__FILE__=__FILE_NAME__" -mno-incremental-linker-compatible
    "-ffile-prefix-map=${build_root}=/hermetic-cpp/build"
    "-ffile-prefix-map=${tmp}=/hermetic-cpp/runtime-set"
    "-ffile-prefix-map=${llvm_src}=/hermetic-cpp/llvm-project"
    "-ffile-prefix-map=${mingw_src}=/hermetic-cpp/mingw-w64"
    "-ffile-prefix-map=${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
    "-ffile-prefix-map=${HERMETIC_DIR}=/hermetic-cpp/repo")
  string(REPLACE ";" " " prefix_map_flags "${prefix_map}")
  set(bootstrap
    "HERMETIC_LLVM_BOOTSTRAP_BIN=${LLVM_ROOT}/bin"
    "HERMETIC_LLVM_BOOTSTRAP_TRIPLE=${triple}"
    "HERMETIC_LLVM_BOOTSTRAP_SYSTEM_NAME=Windows"
    "HERMETIC_LLVM_BOOTSTRAP_WINDOWS_ABI=gnu"
    "HERMETIC_LLVM_BOOTSTRAP_PROCESSOR=${tgt_SYSTEM_PROCESSOR}"
    "HERMETIC_LLVM_BOOTSTRAP_PREFIX_MAP=${prefix_map_flags}")

  # 1. mingw-w64: headers, CRT, start files, import libraries, winpthreads.
  hermetic_llvm_build_stage(NAME mingw-w64 SOURCE "${HERMETIC_DIR}/runtimes/mingw" BUILD "${build_root}/mingw-w64"
    INSTALL_PREFIX "${tmp}/${subdir}" LOG_DIR "${log_dir}" BOOTSTRAP ${bootstrap}
    ARGS "-DMINGW_SOURCE_DIR=${mingw_src}" "-DMINGW_ARCH=${tgt_ARCH}" "-DMINGW_TRIPLE=${triple}"
      "-DMINGW_LLVM_BIN=${LLVM_ROOT}/bin")

  # 2. compiler-rt builtins into the resource directory, with the compiler's
  #    builtin headers.
  hermetic_llvm_resource_dir("${LLVM_ROOT}" compiler_resource_dir)
  file(COPY "${compiler_resource_dir}/include" DESTINATION "${tmp}/resource")
  if(IS_DIRECTORY "${compiler_resource_dir}/share")
    file(COPY "${compiler_resource_dir}/share" DESTINATION "${tmp}/resource")
  endif()
  hermetic_llvm_build_stage(NAME compiler-rt SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/compiler-rt"
    INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}"
    BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_SYSROOT=${tmp}"
    ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DLLVM_INCLUDE_TESTS=OFF
      -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF
      -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF)

  # 3. libunwind, libc++abi and libc++, static, after llvm-mingw's recipe
  #    (win32 threads, so nothing depends on winpthreads).
  hermetic_llvm_build_stage(NAME libcxx SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/libcxx"
    INSTALL_PREFIX "${tmp}/${subdir}" LOG_DIR "${log_dir}"
    BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_SYSROOT=${tmp}" "HERMETIC_LLVM_BOOTSTRAP_RESOURCE_DIR=${tmp}/resource"
      "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=-rtlib=compiler-rt --unwindlib=none"
    CACHE "LLVM_ENABLE_RUNTIMES=libunwind|libcxxabi|libcxx"
    ARGS "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF -DLLVM_INCLUDE_TESTS=OFF
      -DLIBUNWIND_ENABLE_ASSERTIONS=OFF -DLIBCXXABI_ENABLE_ASSERTIONS=OFF
      -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON -DLIBUNWIND_USE_COMPILER_RT=ON
      -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON
      -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_LIBDIR_SUFFIX=
      -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON -DLIBCXX_USE_COMPILER_RT=ON
      -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=OFF
      -DLIBCXX_HAS_WIN32_THREAD_API=ON -DLIBCXX_LIBDIR_SUFFIX=
      -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF)

  string(TIMESTAMP now UTC)
  file(WRITE "${tmp}/runtime-set.json" "{
  \"id\": \"${id}\",
  \"llvm_version\": \"${LLVM_VERSION}\",
  \"target\": \"${TARGET}\",
  \"libc\": \"ucrt\",
  \"libc_description\": \"mingw-w64 ${mingw_version} (UCRT)\",
  \"triple\": \"${triple}\",
  \"components\": [\"builtins\", \"libcxx\"],
  \"recipe_version\": ${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION},
  \"built\": \"${now}\"
}
")
  file(WRITE "${tmp}/.hermetic-cpp.stamp" "${stamp_content}\n")
  file(RENAME "${tmp}" "${set_dir}")
  if(NOT HERMETIC_KEEP_BUILD_DIRS)
    file(REMOVE_RECURSE "${build_root}")
  endif()
  hermetic_log("Runtime set ${id} ready at ${set_dir}")
  set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
endfunction()

# Builds (or reuses) the runtime set for a freestanding WebAssembly TARGET
# (wasm32 or wasm64): the clang resource directory with the compiler-rt
# builtins for the target (lib/<triple>/libclang_rt.builtins.a) and the
# compiler's builtin headers. No libc, no C++ library: a freestanding module
# only has what it brings along, and the toolchain links with -nostdlib.
# The set is identified by "<target>-none". Sets ${OUT_DIR}.
function(hermetic_llvm_build_wasm_runtime_set LLVM_ROOT LLVM_VERSION TARGET OUT_DIR)
  hermetic_target_info("${TARGET}" tgt)
  if(NOT tgt_OS STREQUAL "wasm")
    hermetic_fatal("hermetic_llvm_build_wasm_runtime_set: ${TARGET} is not a WebAssembly target")
  endif()
  set(triple "${tgt_TRIPLE}")
  set(id "${TARGET}-none")
  set(components builtins)
  string(REPLACE ";" "," components_str "${components}")
  set(stamp_content "recipe=${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION};llvm=${LLVM_VERSION};components=${components_str}")

  set(set_dir "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}/${id}")
  set(stamp "${set_dir}/.hermetic-cpp.stamp")
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()
  file(MAKE_DIRECTORY "${HERMETIC_CACHE_DIR}/locks" "${HERMETIC_CACHE_DIR}/runtimes/${LLVM_VERSION}")
  file(LOCK "${HERMETIC_CACHE_DIR}/locks/runtimes-${LLVM_VERSION}-${id}.lock" GUARD FUNCTION TIMEOUT 7200)
  hermetic_llvm_runtime_set_satisfies("${stamp}" "${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION}" "${LLVM_VERSION}" "${components}" ok)
  if(ok)
    set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
    return()
  endif()

  hermetic_log("Building runtime set ${id} for LLVM ${LLVM_VERSION} (${triple}, compiler-rt builtins); this takes a minute")
  hermetic_llvm_load_runtime_sources()
  hermetic_llvm_fetch_llvm_source("${LLVM_VERSION}" llvm_src)
  set(tmp "${set_dir}.tmp")
  set(build_root "${HERMETIC_CACHE_DIR}/build/${LLVM_VERSION}/${id}")
  set(log_dir "${HERMETIC_CACHE_DIR}/logs/${LLVM_VERSION}/${id}")
  file(REMOVE_RECURSE "${tmp}" "${set_dir}" "${build_root}")
  file(MAKE_DIRECTORY "${tmp}/resource")

  set(prefix_map
    -Wno-builtin-macro-redefined "-D__FILE__=__FILE_NAME__"
    "-ffile-prefix-map=${build_root}=/hermetic-cpp/build"
    "-ffile-prefix-map=${tmp}=/hermetic-cpp/runtime-set"
    "-ffile-prefix-map=${llvm_src}=/hermetic-cpp/llvm-project"
    "-ffile-prefix-map=${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
    "-ffile-prefix-map=${HERMETIC_DIR}=/hermetic-cpp/repo")
  string(REPLACE ";" " " prefix_map_flags "${prefix_map}")
  set(bootstrap
    "HERMETIC_LLVM_BOOTSTRAP_BIN=${LLVM_ROOT}/bin"
    "HERMETIC_LLVM_BOOTSTRAP_TRIPLE=${triple}"
    "HERMETIC_LLVM_BOOTSTRAP_SYSTEM_NAME=Generic"
    "HERMETIC_LLVM_BOOTSTRAP_PROCESSOR=${tgt_SYSTEM_PROCESSOR}"
    "HERMETIC_LLVM_BOOTSTRAP_PREFIX_MAP=${prefix_map_flags}")

  hermetic_llvm_resource_dir("${LLVM_ROOT}" compiler_resource_dir)
  file(COPY "${compiler_resource_dir}/include" DESTINATION "${tmp}/resource")
  if(IS_DIRECTORY "${compiler_resource_dir}/share")
    file(COPY "${compiler_resource_dir}/share" DESTINATION "${tmp}/resource")
  endif()
  # Baremetal compiler-rt: builtins only, no crt objects, no sanitizers;
  # position-independent code is WebAssembly dynamic linking, not wanted in
  # the builtins of a static module.
  hermetic_llvm_build_stage(NAME compiler-rt SOURCE "${llvm_src}/runtimes" BUILD "${build_root}/compiler-rt"
    INSTALL_PREFIX "${tmp}/resource" LOG_DIR "${log_dir}"
    BOOTSTRAP ${bootstrap} "HERMETIC_LLVM_BOOTSTRAP_EXTRA_FLAGS=-nostdlib"
    ARGS -DLLVM_ENABLE_RUNTIMES=compiler-rt "-DLLVM_DEFAULT_TARGET_TRIPLE=${triple}"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DLLVM_INCLUDE_TESTS=OFF
      -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_HAS_FPIC_FLAG=OFF
      -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF
      -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF)
  if(NOT EXISTS "${tmp}/resource/lib/${triple}/libclang_rt.builtins.a")
    hermetic_fatal("compiler-rt did not produce lib/${triple}/libclang_rt.builtins.a under ${tmp}/resource")
  endif()

  string(TIMESTAMP now UTC)
  file(WRITE "${tmp}/runtime-set.json" "{
  \"id\": \"${id}\",
  \"llvm_version\": \"${LLVM_VERSION}\",
  \"target\": \"${TARGET}\",
  \"libc\": \"none\",
  \"libc_description\": \"freestanding\",
  \"triple\": \"${triple}\",
  \"components\": [\"builtins\"],
  \"recipe_version\": ${HERMETIC_LLVM_RUNTIME_RECIPE_VERSION},
  \"built\": \"${now}\"
}
")
  file(WRITE "${tmp}/.hermetic-cpp.stamp" "${stamp_content}\n")
  file(RENAME "${tmp}" "${set_dir}")
  if(NOT HERMETIC_KEEP_BUILD_DIRS)
    file(REMOVE_RECURSE "${build_root}")
  endif()
  hermetic_log("Runtime set ${id} ready at ${set_dir}")
  set(${OUT_DIR} "${set_dir}" PARENT_SCOPE)
endfunction()

# Packs a runtime set into <cache>/packages/runtimes-<llvm>-<id>.tar.zst and
# prints the index entry for cmake/distributions/runtime_sets.json.
function(hermetic_llvm_package_runtime_set SET_DIR OUT_ARCHIVE)
  hermetic_read_json("${SET_DIR}/runtime-set.json" manifest)
  string(JSON id GET "${manifest}" "id")
  string(JSON llvm GET "${manifest}" "llvm_version")
  set(dir "${HERMETIC_CACHE_DIR}/packages")
  file(MAKE_DIRECTORY "${dir}")
  set(archive "${dir}/runtimes-${llvm}-${id}.tar.zst")
  file(REMOVE "${archive}")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar cf "${archive}" --zstd -- .
    WORKING_DIRECTORY "${SET_DIR}" RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    hermetic_fatal("Packaging ${SET_DIR} failed")
  endif()
  file(SHA256 "${archive}" sha)
  hermetic_log("Packaged ${archive}")
  hermetic_log("Index entry: \"${llvm}\": { \"${id}\": { \"url\": \"<upload url>/runtimes-${llvm}-${id}.tar.zst\", \"sha256\": \"${sha}\" } }")
  set(${OUT_ARCHIVE} "${archive}" PARENT_SCOPE)
endfunction()
