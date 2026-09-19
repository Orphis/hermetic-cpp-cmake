# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Turns the resolved compiler / runtime set / SDK into CMake toolchain
# variables and flags, mirroring hermetic-llvm's toolchain argument groups.
# Implemented as a macro so that it sets variables in the toolchain file's scope.

include_guard(GLOBAL)

# Finds the clang resource directory (lib/clang/<N>) under ROOT.
function(hermetic_llvm_resource_dir ROOT OUT)
  file(GLOB dirs LIST_DIRECTORIES true "${ROOT}/lib/clang/*" "${ROOT}/lib64/clang/*")
  set(found "")
  foreach(dir IN LISTS dirs)
    if(IS_DIRECTORY "${dir}/include" OR IS_DIRECTORY "${dir}/lib")
      set(found "${dir}")
    endif()
  endforeach()
  if(NOT found)
    hermetic_llvm_fatal("No clang resource directory (lib/clang/<version>) under ${ROOT}")
  endif()
  set(${OUT} "${found}" PARENT_SCOPE)
endfunction()

macro(hermetic_llvm_configure)
  set(_hl_root "${HERMETIC_LLVM_RESOLVED_ROOT}")
  set(_hl_set "${HERMETIC_LLVM_RESOLVED_RUNTIME_SET}")
  set(_hl_sysroot "${HERMETIC_LLVM_RESOLVED_SYSROOT}")
  set(_hl_bin "${_hl_root}/bin")
  set(_hl_exe "${HERMETIC_LLVM_HOST_EXE}")
  hermetic_llvm_target_info("${HERMETIC_LLVM_TARGET}" _hl_tgt)
  set(_hl_native FALSE)
  if("${_hl_tgt_OS}-${_hl_tgt_ARCH}" STREQUAL "${HERMETIC_LLVM_RESOLVED_HOST_OS}-${HERMETIC_LLVM_RESOLVED_HOST_ARCH}")
    set(_hl_native TRUE)
  endif()
  set(_hl_triple "${_hl_tgt_TRIPLE}")
  set(_hl_libc_family "")
  if(HERMETIC_LLVM_RESOLVED_LIBC)
    hermetic_llvm_parse_libc("${HERMETIC_LLVM_RESOLVED_LIBC}" _hl_libc_family _hl_libc_version)
    hermetic_llvm_libc_triple("${_hl_tgt_ARCH}" "${_hl_libc_family}" _hl_triple)
  endif()

  set(_hl_windows FALSE)
  if(_hl_tgt_OS STREQUAL "windows")
    set(_hl_windows TRUE)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 0 _hl_msvc_version)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 1 _hl_msvc_compat)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 2 _hl_msvc_include)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 3 _hl_msvc_lib)
    string(REPLACE "|" ";" _hl_msvc_lib "${_hl_msvc_lib}")
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 6 _hl_sdk_include)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 7 _hl_sdk_ucrt_lib)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 8 _hl_sdk_um_lib)
    list(GET HERMETIC_LLVM_RESOLVED_WINSDK 9 _hl_overlay)
  endif()

  # ---- Tools -------------------------------------------------------------
  if(_hl_windows)
    # MSVC ABI: clang-cl and lld-link, driven by CMake's MSVC-style rules.
    set(CMAKE_C_COMPILER "${_hl_bin}/clang-cl${_hl_exe}")
    set(CMAKE_CXX_COMPILER "${_hl_bin}/clang-cl${_hl_exe}")
    set(CMAKE_RC_COMPILER "${_hl_bin}/llvm-rc${_hl_exe}" CACHE FILEPATH "Resource compiler")
    set(CMAKE_MT "${_hl_bin}/llvm-mt${_hl_exe}" CACHE FILEPATH "Manifest tool")
    set(CMAKE_AR "${_hl_bin}/llvm-ar${_hl_exe}" CACHE FILEPATH "Archiver")
    set(CMAKE_USER_MAKE_RULES_OVERRIDE "${HERMETIC_LLVM_DIR}/cmake/HermeticLLVMWindowsRules.cmake")
  else()
    set(CMAKE_C_COMPILER "${_hl_bin}/clang${_hl_exe}")
    set(CMAKE_CXX_COMPILER "${_hl_bin}/clang++${_hl_exe}")
    set(CMAKE_AR "${_hl_bin}/llvm-ar${_hl_exe}" CACHE FILEPATH "Archiver")
  endif()
  set(CMAKE_ASM_COMPILER "${_hl_bin}/clang${_hl_exe}")
  set(CMAKE_OBJC_COMPILER "${_hl_bin}/clang${_hl_exe}")
  set(CMAKE_OBJCXX_COMPILER "${_hl_bin}/clang++${_hl_exe}")
  set(CMAKE_RANLIB "${_hl_bin}/llvm-ranlib${_hl_exe}" CACHE FILEPATH "Ranlib")
  set(CMAKE_NM "${_hl_bin}/llvm-nm${_hl_exe}" CACHE FILEPATH "nm")
  set(CMAKE_OBJCOPY "${_hl_bin}/llvm-objcopy${_hl_exe}" CACHE FILEPATH "objcopy")
  set(CMAKE_OBJDUMP "${_hl_bin}/llvm-objdump${_hl_exe}" CACHE FILEPATH "objdump")
  set(CMAKE_STRIP "${_hl_bin}/llvm-strip${_hl_exe}" CACHE FILEPATH "strip")
  set(CMAKE_READELF "${_hl_bin}/llvm-readelf${_hl_exe}" CACHE FILEPATH "readelf")
  set(CMAKE_ADDR2LINE "${_hl_bin}/llvm-addr2line${_hl_exe}" CACHE FILEPATH "addr2line")
  set(CMAKE_DLLTOOL "${_hl_bin}/llvm-dlltool${_hl_exe}" CACHE FILEPATH "dlltool")
  if(_hl_tgt_OS STREQUAL "darwin")
    set(CMAKE_LINKER "${_hl_bin}/ld64.lld${_hl_exe}" CACHE FILEPATH "Linker")
    set(CMAKE_INSTALL_NAME_TOOL "${_hl_bin}/llvm-install-name-tool${_hl_exe}" CACHE FILEPATH "install_name_tool")
  elseif(_hl_windows)
    set(CMAKE_LINKER "${_hl_bin}/lld-link${_hl_exe}" CACHE FILEPATH "Linker")
  else()
    set(CMAKE_LINKER "${_hl_bin}/ld.lld${_hl_exe}" CACHE FILEPATH "Linker")
  endif()
  set(CMAKE_C_COMPILER_AR "${CMAKE_AR}")
  set(CMAKE_CXX_COMPILER_AR "${CMAKE_AR}")
  set(CMAKE_C_COMPILER_RANLIB "${CMAKE_RANLIB}")
  set(CMAKE_CXX_COMPILER_RANLIB "${CMAKE_RANLIB}")

  # ---- Target platform ---------------------------------------------------
  if(NOT _hl_native)
    set(CMAKE_SYSTEM_NAME "${_hl_tgt_SYSTEM_NAME}")
    set(CMAKE_SYSTEM_PROCESSOR "${_hl_tgt_SYSTEM_PROCESSOR}")
  endif()
  foreach(_hl_lang C CXX ASM OBJC OBJCXX)
    set(CMAKE_${_hl_lang}_COMPILER_TARGET "${_hl_triple}")
  endforeach()

  if(_hl_tgt_OS STREQUAL "darwin")
    if(_hl_sysroot)
      set(CMAKE_OSX_SYSROOT "${_hl_sysroot}")
    endif()
    if(NOT _hl_native)
      set(CMAKE_OSX_ARCHITECTURES "${_hl_tgt_SYSTEM_PROCESSOR}")
    endif()
  elseif(_hl_set)
    set(CMAKE_SYSROOT "${_hl_set}")
  elseif(_hl_sysroot)
    set(CMAKE_SYSROOT "${_hl_sysroot}")
  endif()

  if(_hl_windows)
    # find_* may look inside the MSVC and SDK trees only.
    set(CMAKE_FIND_ROOT_PATH "${_hl_msvc_include}/.." ${_hl_msvc_lib} "${_hl_sdk_include}/.." "${_hl_sdk_ucrt_lib}/../.." "${_hl_sdk_um_lib}/../..")
  endif()
  # With a runtime set or the Windows SDK the target world is fully known,
  # even for a native build: never let find_* pick up host headers or libraries.
  if(NOT _hl_native OR _hl_set OR _hl_windows)
    if(NOT DEFINED CMAKE_FIND_ROOT_PATH_MODE_PROGRAM)
      set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    endif()
    foreach(_hl_mode LIBRARY INCLUDE PACKAGE)
      if(NOT DEFINED CMAKE_FIND_ROOT_PATH_MODE_${_hl_mode})
        set(CMAKE_FIND_ROOT_PATH_MODE_${_hl_mode} ONLY)
      endif()
    endforeach()
  endif()
  if(NOT _hl_native AND HERMETIC_LLVM_EMULATOR)
    set(CMAKE_CROSSCOMPILING_EMULATOR "${HERMETIC_LLVM_EMULATOR}")
  endif()

  # ---- Flags -------------------------------------------------------------
  set(_hl_c_flags "")
  set(_hl_cxx_flags "")
  set(_hl_link_flags "")
  set(_hl_exe_link_flags "")
  set(_hl_cxx_libs "")

  if(HERMETIC_LLVM_REPRODUCIBLE)
    # hermetic-llvm's deterministic_compile_flags.
    hermetic_llvm_append_flags(_hl_c_flags -Wno-builtin-macro-redefined "-D__DATE__=\\\"redacted\\\"" "-D__TIMESTAMP__=\\\"redacted\\\"" "-D__TIME__=\\\"redacted\\\"")
  endif()
  if(HERMETIC_LLVM_USE_LLD AND NOT _hl_windows)
    hermetic_llvm_append_flags(_hl_link_flags -fuse-ld=lld)
  endif()

  if(_hl_windows)
    # MSVC ABI, following hermetic-llvm's windows/msvc argument groups:
    # explicit MSVC and SDK include and library paths, a case-insensitive VFS
    # overlay for the SDK's mixed-case names, deterministic objects and links.
    hermetic_llvm_append_flags(_hl_c_flags
      "-fms-compatibility-version=${_hl_msvc_compat}"
      "/imsvc${_hl_msvc_include}" "/imsvc${_hl_sdk_include}/ucrt" "/imsvc${_hl_sdk_include}/shared"
      "/imsvc${_hl_sdk_include}/um" "/imsvc${_hl_sdk_include}/winrt"
      -Xclang -ivfsoverlay -Xclang "${_hl_overlay}"
      /Brepro /clang:-gno-codeview-command-line)
    foreach(_hl_dir IN LISTS _hl_msvc_lib)
      hermetic_llvm_append_flags(_hl_link_flags "/LIBPATH:${_hl_dir}")
    endforeach()
    hermetic_llvm_append_flags(_hl_link_flags
      "/LIBPATH:${_hl_sdk_ucrt_lib}" "/LIBPATH:${_hl_sdk_um_lib}"
      "/vfsoverlay:${_hl_overlay}" /Brepro /INCREMENTAL:NO /lldignoreenv
      # No manifest embedding: it would need llvm-mt, which the prebuilt
      # lacks libxml2 for; lld-link can embed one on request.
      /MANIFEST:NO)
    if(_hl_tgt_ARCH STREQUAL "aarch64")
      hermetic_llvm_append_flags(_hl_link_flags /MACHINE:ARM64)
    else()
      hermetic_llvm_append_flags(_hl_link_flags /MACHINE:X64)
    endif()
  elseif(_hl_set)
    # Linux with a runtime set: resource directory with compiler-rt, static
    # libc++ / libc++abi / libunwind, default libs, link mode.
    hermetic_llvm_append_flags(_hl_c_flags "-resource-dir=${_hl_set}/resource")
    # compiler-rt builtins and the static libunwind from the set are used for
    # C and C++ alike (sanitizer runtimes need the unwinder too).
    hermetic_llvm_append_flags(_hl_link_flags "-resource-dir=${_hl_set}/resource" -rtlib=compiler-rt --unwindlib=libunwind
      -Wl,-z,relro,-z,now)
    hermetic_llvm_append_flags(_hl_cxx_flags -stdlib=libc++)
    hermetic_llvm_append_flags(_hl_link_flags -nostdlib++)
    hermetic_llvm_append_flags(_hl_cxx_libs -lc++ -lc++abi)
    if(_hl_libc_family STREQUAL "musl")
      # Fully static, like hermetic-llvm: no dynamic loader at all.
      if(NOT DEFINED HERMETIC_LLVM_PIE OR HERMETIC_LLVM_PIE)
        hermetic_llvm_append_flags(_hl_exe_link_flags -static-pie)
      else()
        hermetic_llvm_append_flags(_hl_exe_link_flags -static)
      endif()
    else()
      hermetic_llvm_append_flags(_hl_cxx_libs -Wl,--push-state,--as-needed -lpthread -ldl -Wl,--pop-state)
      if(DEFINED HERMETIC_LLVM_PIE AND NOT HERMETIC_LLVM_PIE)
        hermetic_llvm_append_flags(_hl_exe_link_flags -no-pie)
      endif()
    endif()
  elseif(_hl_tgt_OS STREQUAL "darwin")
    # The SDK's libc++ (headers and dylib), for ABI compatibility with the
    # system libraries that link it dynamically.
    if(_hl_sysroot AND IS_DIRECTORY "${_hl_sysroot}/usr/include/c++/v1")
      hermetic_llvm_append_flags(_hl_cxx_flags -nostdinc++ "-isystem${_hl_sysroot}/usr/include/c++/v1")
    endif()
  endif()

  hermetic_llvm_append_flags(_hl_c_flags ${HERMETIC_LLVM_EXTRA_COMPILE_FLAGS})
  hermetic_llvm_append_flags(_hl_cxx_flags ${HERMETIC_LLVM_EXTRA_CXX_FLAGS})
  hermetic_llvm_append_flags(_hl_link_flags ${HERMETIC_LLVM_EXTRA_LINK_FLAGS})
  hermetic_llvm_append_flags(_hl_cxx_libs ${HERMETIC_LLVM_EXTRA_LINK_LIBS})

  foreach(_hl_lang C CXX ASM OBJC OBJCXX)
    hermetic_llvm_append_flags(CMAKE_${_hl_lang}_FLAGS_INIT ${_hl_c_flags})
  endforeach()
  if(_hl_windows)
    # The overlay and MSVC paths are compile-only; keep them off the RC flags.
    set(CMAKE_RC_FLAGS_INIT "/I${_hl_sdk_include}/um /I${_hl_sdk_include}/shared")
  endif()
  hermetic_llvm_append_flags(CMAKE_CXX_FLAGS_INIT ${_hl_cxx_flags})
  hermetic_llvm_append_flags(CMAKE_OBJCXX_FLAGS_INIT ${_hl_cxx_flags})
  foreach(_hl_kind EXE SHARED MODULE)
    hermetic_llvm_append_flags(CMAKE_${_hl_kind}_LINKER_FLAGS_INIT ${_hl_link_flags})
  endforeach()
  hermetic_llvm_append_flags(CMAKE_EXE_LINKER_FLAGS_INIT ${_hl_exe_link_flags})
  hermetic_llvm_append_flags(CMAKE_CXX_STANDARD_LIBRARIES_INIT ${_hl_cxx_libs})
  hermetic_llvm_append_flags(CMAKE_OBJCXX_STANDARD_LIBRARIES_INIT ${_hl_cxx_libs})

  # Exported for consumers (e.g. to find clang-tidy / clang-format).
  set(HERMETIC_LLVM_ROOT "${_hl_root}")
  set(HERMETIC_LLVM_BIN_DIR "${_hl_bin}")
  set(HERMETIC_LLVM_RUNTIME_SET "${_hl_set}")
  set(HERMETIC_LLVM_SYSROOT_PATH "${_hl_sysroot}")
  set(HERMETIC_LLVM_TARGET_TRIPLE "${_hl_triple}")
  set(HERMETIC_LLVM_EFFECTIVE_LIBC "${HERMETIC_LLVM_RESOLVED_LIBC}")
  if(_hl_native)
    set(HERMETIC_LLVM_CROSSCOMPILING FALSE)
  else()
    set(HERMETIC_LLVM_CROSSCOMPILING TRUE)
  endif()
endmacro()
