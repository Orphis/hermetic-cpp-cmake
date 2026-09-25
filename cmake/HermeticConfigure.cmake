# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Turns the resolved compiler / runtime set / SDK into CMake toolchain
# variables and flags, mirroring hermetic-llvm's toolchain argument groups.
# Implemented as a macro so that it sets variables in the toolchain file's scope.

include_guard(GLOBAL)

# Finds the clang resource directory (lib/clang/<N>) under ROOT. Targets
# without a runtime set pass it explicitly: the driver would otherwise
# derive it from its own real path, which a remote execution wrapper cannot
# rewrite (an absolute, machine-specific path in debug info and depfiles).
function(hermetic_llvm_resource_dir ROOT OUT)
  file(GLOB dirs LIST_DIRECTORIES true "${ROOT}/lib/clang/*" "${ROOT}/lib64/clang/*")
  set(found "")
  foreach(dir IN LISTS dirs)
    if(IS_DIRECTORY "${dir}/include" OR IS_DIRECTORY "${dir}/lib")
      set(found "${dir}")
    endif()
  endforeach()
  if(NOT found)
    hermetic_fatal("No clang resource directory (lib/clang/<version>) under ${ROOT}")
  endif()
  set(${OUT} "${found}" PARENT_SCOPE)
endfunction()

# Debugger settings for a build directory. Reproducible builds record fixed
# or relative paths in debug info: the cache as /hermetic-cpp/cache, the
# compiler as /hermetic-cpp/llvm, the working directory as "." (and, when a
# remote execution wrapper made a compile's paths relative, the sources
# relative to the build directory). hermetic-cpp.gdb and hermetic-cpp.lldb
# in the build directory map them back for GDB (gdb -x <file>) and LLDB
# (lldb -s <file>); projects add the maps of their own -ffile-prefix-map
# options with hermetic_debugger_source_map.
function(hermetic_debugger_source_map FROM TO)
  set_property(GLOBAL APPEND PROPERTY HERMETIC_DEBUGGER_MAPS "${FROM}=${TO}")
  _hermetic_write_debugger_files()
endfunction()

function(_hermetic_write_debugger_files)
  get_property(dir GLOBAL PROPERTY HERMETIC_DEBUGGER_BUILD_DIR)
  if(NOT dir)
    return()
  endif()
  get_property(maps GLOBAL PROPERTY HERMETIC_DEBUGGER_MAPS)
  get_filename_component(parent "${dir}" DIRECTORY)
  set(gdb "# Written by the hermetic-cpp toolchain: where the sources of this build\n# directory's binaries are. gdb -x <this file> <program>\n")
  set(lldb "# Written by the hermetic-cpp toolchain: where the sources of this build\n# directory's binaries are. lldb -s <this file> <program>\n")
  foreach(map IN LISTS maps)
    string(FIND "${map}" "=" eq)
    string(SUBSTRING "${map}" 0 ${eq} from)
    math(EXPR eq "${eq} + 1")
    string(SUBSTRING "${map}" ${eq} -1 to)
    string(APPEND gdb "set substitute-path \"${from}\" \"${to}\"\n")
    string(APPEND lldb "settings append target.source-map \"${from}\" \"${to}\"\n")
  endforeach()
  # The working directory ("."), for paths relative to it.
  string(APPEND gdb "directory \"${dir}\"\n")
  string(APPEND lldb "settings append target.source-map .. \"${parent}\"\n")
  file(CONFIGURE OUTPUT "${dir}/hermetic-cpp.gdb" CONTENT "${gdb}" @ONLY)
  file(CONFIGURE OUTPUT "${dir}/hermetic-cpp.lldb" CONTENT "${lldb}" @ONLY)
endfunction()

macro(hermetic_configure)
  set(_hl_root "${HERMETIC_RESOLVED_LLVM_ROOT}")
  set(_hl_set "${HERMETIC_RESOLVED_LLVM_RUNTIME_SET}")
  set(_hl_sysroot "${HERMETIC_RESOLVED_SYSROOT}")
  set(_hl_bin "${_hl_root}/bin")
  set(_hl_exe "${HERMETIC_HOST_EXE}")
  hermetic_target_info("${HERMETIC_TARGET}" _hl_tgt)
  set(_hl_native FALSE)
  if("${_hl_tgt_OS}-${_hl_tgt_ARCH}" STREQUAL "${HERMETIC_RESOLVED_HOST_OS}-${HERMETIC_RESOLVED_HOST_ARCH}")
    set(_hl_native TRUE)
  endif()
  set(_hl_triple "${_hl_tgt_TRIPLE}")
  set(_hl_libc_family "")
  if(HERMETIC_RESOLVED_LIBC)
    hermetic_parse_libc("${HERMETIC_RESOLVED_LIBC}" _hl_libc_family _hl_libc_version)
    hermetic_libc_triple("${_hl_tgt_ARCH}" "${_hl_libc_family}" _hl_triple)
  endif()

  set(_hl_windows FALSE)
  set(_hl_mingw FALSE)
  set(_hl_msvc FALSE)  # cl.exe instead of clang-cl (HERMETIC_COMPILER=msvc)
  if(_hl_tgt_OS STREQUAL "windows" AND HERMETIC_RESOLVED_WINDOWS_ABI STREQUAL "gnu")
    # GNU ABI: the plain clang driver with MinGW-w64 from the runtime set.
    set(_hl_mingw TRUE)
    hermetic_windows_gnu_triple("${_hl_tgt_ARCH}" _hl_triple)
  elseif(_hl_tgt_OS STREQUAL "windows")
    set(_hl_windows TRUE)
    if(HERMETIC_RESOLVED_COMPILER STREQUAL "msvc")
      set(_hl_msvc TRUE)
    endif()
    list(GET HERMETIC_RESOLVED_WINSDK 0 _hl_msvc_version)
    list(GET HERMETIC_RESOLVED_WINSDK 2 _hl_msvc_include)
    list(GET HERMETIC_RESOLVED_WINSDK 3 _hl_msvc_lib)
    string(REPLACE "|" ";" _hl_msvc_lib "${_hl_msvc_lib}")
    list(GET HERMETIC_RESOLVED_WINSDK 6 _hl_sdk_include)
    list(GET HERMETIC_RESOLVED_WINSDK 7 _hl_sdk_ucrt_lib)
    list(GET HERMETIC_RESOLVED_WINSDK 8 _hl_sdk_um_lib)
    list(GET HERMETIC_RESOLVED_WINSDK 10 _hl_sdk_tools)
  endif()

  # ---- Tools -------------------------------------------------------------
  if(_hl_msvc)
    # MSVC's cl.exe from the toolset packages; lld-link, llvm-lib, llvm-rc
    # and llvm-mt from the LLVM prebuilt, driven by CMake's MSVC rules with
    # the linker named in HermeticMSVCRules.cmake.
    set(CMAKE_C_COMPILER "${HERMETIC_RESOLVED_MSVC_BIN}/cl.exe")
    set(CMAKE_CXX_COMPILER "${HERMETIC_RESOLVED_MSVC_BIN}/cl.exe")
    set(CMAKE_RC_COMPILER "${_hl_bin}/llvm-rc${_hl_exe}" CACHE FILEPATH "Resource compiler")
    set(CMAKE_MT "${_hl_bin}/llvm-mt${_hl_exe}" CACHE FILEPATH "Manifest tool")
    set(CMAKE_AR "${_hl_bin}/llvm-lib${_hl_exe}" CACHE FILEPATH "Archiver")
    if(NOT EXISTS "${CMAKE_AR}")
      hermetic_fatal("HERMETIC_COMPILER=msvc needs llvm-lib in the LLVM prebuilt (${CMAKE_AR}); use an LLVM release that ships it")
    endif()
    foreach(_hl_masm ml64.exe armasm64.exe)
      if(EXISTS "${HERMETIC_RESOLVED_MSVC_BIN}/${_hl_masm}")
        set(CMAKE_ASM_MASM_COMPILER "${HERMETIC_RESOLVED_MSVC_BIN}/${_hl_masm}")
      endif()
    endforeach()
    # Debug info in the objects (/Z7) rather than a compile PDB (/Zi): no
    # mspdbsrv, and objects that depend on their content only.
    if(NOT DEFINED CMAKE_MSVC_DEBUG_INFORMATION_FORMAT)
      set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<$<CONFIG:Debug,RelWithDebInfo>:Embedded>")
    endif()
    set(CMAKE_USER_MAKE_RULES_OVERRIDE "${HERMETIC_DIR}/cmake/HermeticMSVCRules.cmake")
  elseif(_hl_windows)
    # MSVC ABI: clang-cl and lld-link, driven by CMake's MSVC-style rules.
    set(CMAKE_C_COMPILER "${_hl_bin}/clang-cl${_hl_exe}")
    set(CMAKE_CXX_COMPILER "${_hl_bin}/clang-cl${_hl_exe}")
    set(CMAKE_RC_COMPILER "${_hl_bin}/llvm-rc${_hl_exe}" CACHE FILEPATH "Resource compiler")
    set(CMAKE_MT "${_hl_bin}/llvm-mt${_hl_exe}" CACHE FILEPATH "Manifest tool")
    set(CMAKE_AR "${_hl_bin}/llvm-ar${_hl_exe}" CACHE FILEPATH "Archiver")
    # clang-cl assembles .S files too; CMake applies MSVC-style flags to ASM
    # whenever the C compiler is MSVC-like, which plain clang would reject.
    set(CMAKE_ASM_COMPILER "${_hl_bin}/clang-cl${_hl_exe}")
    set(CMAKE_USER_MAKE_RULES_OVERRIDE "${HERMETIC_DIR}/cmake/HermeticWindowsRules.cmake")
  else()
    set(CMAKE_C_COMPILER "${_hl_bin}/clang${_hl_exe}")
    set(CMAKE_CXX_COMPILER "${_hl_bin}/clang++${_hl_exe}")
    set(CMAKE_AR "${_hl_bin}/llvm-ar${_hl_exe}" CACHE FILEPATH "Archiver")
    set(CMAKE_ASM_COMPILER "${_hl_bin}/clang${_hl_exe}")
    if(_hl_mingw)
      set(CMAKE_RC_COMPILER "${_hl_bin}/llvm-windres${_hl_exe}" CACHE FILEPATH "Resource compiler")
      set(CMAKE_RC_FLAGS_INIT "--target=${_hl_triple}")
    endif()
  endif()
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
  elseif(_hl_mingw)
    set(CMAKE_LINKER "${_hl_bin}/ld.lld${_hl_exe}" CACHE FILEPATH "Linker")
  elseif(_hl_tgt_OS STREQUAL "wasm")
    set(CMAKE_LINKER "${_hl_bin}/wasm-ld${_hl_exe}" CACHE FILEPATH "Linker")
    # Modules are named *.wasm (see the file).
    set(CMAKE_USER_MAKE_RULES_OVERRIDE "${HERMETIC_DIR}/cmake/HermeticWasmRules.cmake")
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
    # Makes every host behave alike for shared libraries (see the file).
    set(CMAKE_USER_MAKE_RULES_OVERRIDE "${HERMETIC_DIR}/cmake/HermeticDarwinRules.cmake")
  elseif(_hl_set AND NOT _hl_windows AND NOT _hl_tgt_OS STREQUAL "wasm")
    set(CMAKE_SYSROOT "${_hl_set}")
  elseif(_hl_sysroot)
    set(CMAKE_SYSROOT "${_hl_sysroot}")
  endif()

  if(_hl_windows)
    # try_compile projects build the Debug configuration by default, i.e.
    # with the debug CRT, which clang-cl refuses to combine with
    # -fsanitize=address; check with the release CRT instead.
    if(NOT DEFINED CMAKE_TRY_COMPILE_CONFIGURATION)
      set(CMAKE_TRY_COMPILE_CONFIGURATION Release)
    endif()
    # find_* may look inside the MSVC and SDK trees only.
    set(CMAKE_FIND_ROOT_PATH "${_hl_msvc_include}/.." ${_hl_msvc_lib} "${_hl_sdk_include}/.." "${_hl_sdk_ucrt_lib}/../.." "${_hl_sdk_um_lib}/../..")
    if(_hl_set)
      list(APPEND CMAKE_FIND_ROOT_PATH "${_hl_set}")
    endif()
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
  if(NOT _hl_native AND HERMETIC_EMULATOR)
    set(CMAKE_CROSSCOMPILING_EMULATOR "${HERMETIC_EMULATOR}")
  endif()

  # ---- Flags -------------------------------------------------------------
  set(_hl_c_flags "")
  set(_hl_cxx_first_flags "")  # C++ only, ahead of the common flags (include order)
  set(_hl_cxx_flags "")
  set(_hl_link_flags "")
  set(_hl_exe_link_flags "")
  set(_hl_cxx_libs "")

  if(HERMETIC_REPRODUCIBLE AND _hl_msvc)
    # cl.exe: /Brepro zeroes the object timestamp, /experimental:deterministic
    # (toolset 14.40, Visual Studio 17.10, and newer) removes the remaining
    # host-dependent content, and /pathmap replaces the cache directory in
    # the paths CodeView records, as the prefix maps do for clang.
    hermetic_append_flags(_hl_c_flags /Brepro)
    if(_hl_msvc_version VERSION_GREATER_EQUAL 14.40)
      # Each object also records its own absolute path (the CodeView
      # object-name record, which clang-cl leaves blank), so the build
      # directory is mapped too; that record is only matched when <from> is
      # spelled with backslashes, as cl.exe writes it.
      string(REPLACE "/" "\\" _hl_build_native "${CMAKE_BINARY_DIR}")
      hermetic_append_flags(_hl_c_flags /experimental:deterministic
        "/pathmap:${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
        "/pathmap:${_hl_build_native}=/hermetic-cpp/build")
    else()
      message(WARNING "[hermetic-cpp] MSVC toolset ${_hl_msvc_version} has no /experimental:deterministic or /pathmap (14.40 and newer): objects will record host paths")
    endif()
  elseif(HERMETIC_REPRODUCIBLE)
    # hermetic-llvm's deterministic_compile_flags.
    hermetic_append_flags(_hl_c_flags -Wno-builtin-macro-redefined "-D__DATE__=\\\"redacted\\\"" "-D__TIMESTAMP__=\\\"redacted\\\"" "-D__TIME__=\\\"redacted\\\"")
    # Debug info and assertion strings name the runtime set, toolset and SDK
    # headers, which live in the cache directory: map it to a fixed name as
    # the runtime set builds do, so debug builds do not depend on the machine.
    # The compiler's own directory is named after the host (its builtin
    # headers appear in the debug info of targets without a runtime set,
    # such as macOS); its map comes second, since the last matching map wins.
    # Debug info also records the working directory (DW_AT_comp_dir,
    # CodeView's build info), which differs from checkout to checkout:
    # record "." instead, leaving relative paths relative to the build
    # directory.
    set(_hl_prefix_maps "-ffile-compilation-dir=."
      "-ffile-prefix-map=${HERMETIC_CACHE_DIR}=/hermetic-cpp/cache"
      "-ffile-prefix-map=${_hl_root}=/hermetic-cpp/llvm")
    if(_hl_windows)
      # CodeView also records each object file's absolute path (S_OBJNAME),
      # which no prefix map covers; an empty name leaves that record blank.
      foreach(_hl_map IN LISTS _hl_prefix_maps)
        hermetic_append_flags(_hl_c_flags "/clang:${_hl_map}")
      endforeach()
      hermetic_append_flags(_hl_c_flags -Xclang -object-file-name=-)
    else()
      hermetic_append_flags(_hl_c_flags ${_hl_prefix_maps})
    endif()
    if(_hl_mingw)
      # COFF objects for the GNU environment carry the current time as their
      # timestamp unless told otherwise (clang-cl's /Brepro does the same).
      hermetic_append_flags(_hl_c_flags -mno-incremental-linker-compatible)
    endif()
  endif()
  if(HERMETIC_USE_LLD AND NOT _hl_windows AND NOT _hl_tgt_OS STREQUAL "wasm")
    hermetic_append_flags(_hl_link_flags -fuse-ld=lld)
  endif()
  if(_hl_mingw AND HERMETIC_REPRODUCIBLE)
    # lld stamps PE headers with the current time unless told otherwise.
    hermetic_append_flags(_hl_link_flags -Wl,--no-insert-timestamp)
  endif()

  set(HERMETIC_WINDOWS_LINK_DRIVER_FLAGS "")
  if(_hl_windows)
    # MSVC ABI: the toolset and SDK environment (see hermetic_windows_flags).
    #
    # Reproducible links address everything in the cache through a link to
    # it in the build directory (and the compiler through a host-neutral
    # name), so that what lld-link records in the PDB (its own path, the
    # libraries it resolved, its command line) is relative to the build
    # directory: with /pdbsourcepath the PDB, and the executable holding its
    # GUID, then come out the same on every machine. Compilation keeps the
    # absolute paths (prefix maps cover them, and the compiler identification
    # step runs where no link exists).
    set(_hl_link_root "")
    if(HERMETIC_REPRODUCIBLE)
      hermetic_link_directory("${HERMETIC_CACHE_DIR}"
        "${CMAKE_BINARY_DIR}/${HERMETIC_CACHE_LINK_NAME}" _hl_link_ok)
      hermetic_link_directory("${_hl_root}"
        "${HERMETIC_CACHE_DIR}/llvm/${HERMETIC_RESOLVED_LLVM_VERSION}" _hl_llvm_link_ok)
      if(_hl_link_ok AND _hl_llvm_link_ok)
        set(_hl_link_root "${HERMETIC_CACHE_LINK_NAME}")
      else()
        message(WARNING "[hermetic-cpp] Linking without the build directory link: PDBs will depend on the cache directory")
      endif()
    endif()
    set(_hl_link_set "${_hl_set}")
    # Executables and DLLs embed a manifest when the prebuilt can merge
    # them; compiler checks do without.
    set(_hl_win_manifest "")
    get_property(_hl_in_try_compile GLOBAL PROPERTY IN_TRY_COMPILE)
    if(NOT _hl_in_try_compile)
      hermetic_manifest_merging_works("${CMAKE_MT}" "${CMAKE_BINARY_DIR}/CMakeFiles/hermetic-cpp" _hl_mt_ok)
      if(_hl_mt_ok)
        set(_hl_win_manifest EMBED_MANIFEST)
      endif()
    endif()
    # cl.exe: lld-link named through the build directory link in the rules
    # (HermeticMSVCRules.cmake), so the PDB records a relative path.
    set(HERMETIC_MSVC_LINKER "${_hl_bin}/lld-link${_hl_exe}")
    if(_hl_link_root)
      # As cmd.exe wants a relative program: ".\dir\lld-link.exe" (a
      # forward slash would end the command name).
      string(REPLACE "/" "\\" HERMETIC_MSVC_LINKER ".\\${_hl_link_root}/llvm/${HERMETIC_RESOLVED_LLVM_VERSION}/bin/lld-link${_hl_exe}")
      hermetic_windows_flags("${HERMETIC_RESOLVED_WINSDK}" "${_hl_tgt_ARCH}" _hl_win_compile _hl_win_link ${_hl_win_manifest}
        RELATIVE_ROOT "${_hl_link_root}" OUT_LINK_DRIVER HERMETIC_WINDOWS_LINK_DRIVER_FLAGS)
      # lld-link found through a prefix directory keeps the relative path it
      # was found by as its own name (--ld-path is not a clang-cl option).
      list(APPEND HERMETIC_WINDOWS_LINK_DRIVER_FLAGS "/clang:-B${_hl_link_root}/llvm/${HERMETIC_RESOLVED_LLVM_VERSION}/bin/")
      string(REPLACE "${HERMETIC_CACHE_DIR}" "${_hl_link_root}" _hl_link_set "${_hl_link_set}")
      if(_hl_set AND NOT _hl_link_set STREQUAL _hl_set)
        list(APPEND HERMETIC_WINDOWS_LINK_DRIVER_FLAGS "-resource-dir=${_hl_link_set}/resource")
      endif()
      string(REPLACE ";" " " HERMETIC_WINDOWS_LINK_DRIVER_FLAGS "${HERMETIC_WINDOWS_LINK_DRIVER_FLAGS}")
    else()
      hermetic_windows_flags("${HERMETIC_RESOLVED_WINSDK}" "${_hl_tgt_ARCH}" _hl_win_compile _hl_win_link ${_hl_win_manifest})
    endif()
    if(_hl_msvc)
      # cl.exe takes the toolset and SDK headers as plain include directories,
      # and /X keeps the INCLUDE environment of the host out of the build.
      set(_hl_win_compile /X "/I${_hl_msvc_include}"
        "/I${_hl_sdk_include}/ucrt" "/I${_hl_sdk_include}/um" "/I${_hl_sdk_include}/shared"
        "/I${_hl_sdk_include}/winrt" "/I${_hl_sdk_include}/cppwinrt")
    elseif(_hl_set)
      # Runtime set (libc++ and/or sanitizers). Its resource directory gives
      # the driver the compiler-rt runtimes (builtins, sanitizers, profile)
      # for the link step. The set holds one libc++ archive per C runtime
      # flavour; a force-included header names the one matching each
      # translation unit's flavour (CMake's MSVC_RUNTIME_LIBRARY, per target
      # and per config) through a default-library directive. It is used with
      # the MSVC STL too, since libFuzzer is built against libc++.
      # The set's runtimes are built with the ISO wide printf/scanf
      # conversions, and the UCRT headers make the linker reject objects that
      # disagree; hermetic-llvm defines this for every MSVC consumer too.
      hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_set}/resource" /D_CRT_STDIO_ISO_WIDE_SPECIFIERS)
      hermetic_append_flags(_hl_cxx_first_flags
        "/FI${_hl_set}/include/__hermetic_llvm_libcxx_link.h" /D_LIBCPP_NO_AUTO_LINK)
      if(HERMETIC_RESOLVED_CXX_STDLIB STREQUAL "libc++")
        # libc++ instead of the MSVC STL. clang-cl searches its builtin
        # headers before any /imsvc directory, which would shadow libc++'s
        # <stddef.h> and friends; so the builtin directory is dropped and the
        # order is spelled out as on Linux: libc++, compiler builtins, then
        # the toolset and SDK (added by the driver).
        hermetic_append_flags(_hl_cxx_first_flags "/imsvc${_hl_set}/include/c++/v1")
        hermetic_append_flags(_hl_c_flags -nobuiltininc "/imsvc${_hl_set}/resource/include")
      else()
        # Under ASan the MSVC STL annotates std::string and std::vector and
        # links stl_asan.lib, which only ships in Visual Studio's own ASan
        # package; opt out as Microsoft documents (container overflow checks
        # inside those two types are lost, everything else is checked).
        hermetic_append_flags(_hl_cxx_first_flags /D_DISABLE_STL_ANNOTATION)
      endif()
    else()
      # The compiler's own resource directory (builtin headers), named
      # explicitly (see hermetic_llvm_resource_dir).
      hermetic_llvm_resource_dir("${_hl_root}" _hl_resource)
      hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_resource}")
    endif()
    hermetic_append_flags(_hl_c_flags ${_hl_win_compile})
    hermetic_append_flags(_hl_link_flags ${_hl_win_link})
    if(_hl_set)
      if(_hl_tgt_ARCH STREQUAL "aarch64")
        set(_hl_builtins "clang_rt.builtins-aarch64.lib")
      else()
        set(_hl_builtins "clang_rt.builtins-x86_64.lib")
      endif()
      hermetic_append_flags(_hl_link_flags "/LIBPATH:${_hl_link_set}/lib" "/LIBPATH:${_hl_link_set}/resource/lib/windows"
        "${_hl_builtins}")
    endif()
  elseif(_hl_mingw)
    # MinGW-w64 from the set (the sysroot: clang finds <set>/<arch>-w64-mingw32),
    # compiler-rt builtins and libunwind from its resource directory, static
    # libc++; CMake's GNU-style Windows rules do the rest (lld's MinGW
    # driver, .dll.a import libraries, llvm-windres).
    hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_set}/resource")
    hermetic_append_flags(_hl_link_flags "-resource-dir=${_hl_set}/resource" -rtlib=compiler-rt --unwindlib=libunwind)
    hermetic_append_flags(_hl_cxx_flags -stdlib=libc++)
  elseif(_hl_tgt_OS STREQUAL "wasm")
    # Freestanding WebAssembly: the driver would otherwise ask for a libc
    # and an entry point (_start), which a module exporting functions has
    # neither of; the builtins come from the set. Exported functions are
    # marked with __attribute__((export_name("..."))) or named with
    # -Wl,--export=...; imports need -Wl,--allow-undefined.
    hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_set}/resource")
    hermetic_append_flags(_hl_link_flags -nostdlib -Wl,--no-entry)
    hermetic_append_flags(_hl_cxx_libs "${_hl_set}/resource/lib/${_hl_triple}/libclang_rt.builtins.a")
    hermetic_append_flags(CMAKE_C_STANDARD_LIBRARIES_INIT "${_hl_set}/resource/lib/${_hl_triple}/libclang_rt.builtins.a")
  elseif(_hl_set)
    # Linux with a runtime set: resource directory with compiler-rt, static
    # libc++ / libc++abi / libunwind, default libs, link mode.
    hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_set}/resource")
    # compiler-rt builtins and the static libunwind from the set are used for
    # C and C++ alike (sanitizer runtimes need the unwinder too).
    hermetic_append_flags(_hl_link_flags "-resource-dir=${_hl_set}/resource" -rtlib=compiler-rt --unwindlib=libunwind
      -Wl,-z,relro,-z,now)
    hermetic_append_flags(_hl_cxx_flags -stdlib=libc++)
    hermetic_append_flags(_hl_link_flags -nostdlib++)
    hermetic_append_flags(_hl_cxx_libs -lc++ -lc++abi)
    if(_hl_libc_family STREQUAL "musl")
      # Fully static, like hermetic-llvm: no dynamic loader at all.
      if(NOT DEFINED HERMETIC_PIE OR HERMETIC_PIE)
        hermetic_append_flags(_hl_exe_link_flags -static-pie)
      else()
        hermetic_append_flags(_hl_exe_link_flags -static)
      endif()
    else()
      hermetic_append_flags(_hl_cxx_libs -Wl,--push-state,--as-needed -lpthread -ldl -Wl,--pop-state)
      if(DEFINED HERMETIC_PIE AND NOT HERMETIC_PIE)
        hermetic_append_flags(_hl_exe_link_flags -no-pie)
      endif()
    endif()
  elseif(_hl_tgt_OS STREQUAL "darwin")
    # The SDK's libc++ (headers and dylib), for ABI compatibility with the
    # system libraries that link it dynamically.
    if(_hl_sysroot AND IS_DIRECTORY "${_hl_sysroot}/usr/include/c++/v1")
      hermetic_append_flags(_hl_cxx_flags -nostdinc++ "-isystem${_hl_sysroot}/usr/include/c++/v1")
    endif()
    # The compiler's own resource directory (builtin headers, compiler-rt),
    # named explicitly (see hermetic_llvm_resource_dir).
    hermetic_llvm_resource_dir("${_hl_root}" _hl_resource)
    hermetic_append_flags(_hl_c_flags "-resource-dir=${_hl_resource}")
    hermetic_append_flags(_hl_link_flags "-resource-dir=${_hl_resource}")
  endif()

  hermetic_append_flags(_hl_c_flags ${HERMETIC_EXTRA_COMPILE_FLAGS})
  hermetic_append_flags(_hl_cxx_flags ${HERMETIC_EXTRA_CXX_FLAGS})
  hermetic_append_flags(_hl_link_flags ${HERMETIC_EXTRA_LINK_FLAGS})
  hermetic_append_flags(_hl_cxx_libs ${HERMETIC_EXTRA_LINK_LIBS})

  foreach(_hl_lang C CXX ASM OBJC OBJCXX)
    hermetic_append_flags(CMAKE_${_hl_lang}_FLAGS_INIT ${_hl_c_flags})
  endforeach()
  if(_hl_windows)
    # The overlay and MSVC paths are compile-only; keep them off the RC flags.
    set(CMAKE_RC_FLAGS_INIT "/I${_hl_sdk_include}/um /I${_hl_sdk_include}/shared")
  endif()
  if(_hl_cxx_first_flags)
    set(CMAKE_CXX_FLAGS_INIT "")
    set(CMAKE_OBJCXX_FLAGS_INIT "")
    hermetic_append_flags(CMAKE_CXX_FLAGS_INIT ${_hl_cxx_first_flags} ${_hl_c_flags})
    hermetic_append_flags(CMAKE_OBJCXX_FLAGS_INIT ${_hl_cxx_first_flags} ${_hl_c_flags})
  endif()
  hermetic_append_flags(CMAKE_CXX_FLAGS_INIT ${_hl_cxx_flags})
  hermetic_append_flags(CMAKE_OBJCXX_FLAGS_INIT ${_hl_cxx_flags})
  foreach(_hl_kind EXE SHARED MODULE)
    hermetic_append_flags(CMAKE_${_hl_kind}_LINKER_FLAGS_INIT ${_hl_link_flags})
  endforeach()
  hermetic_append_flags(CMAKE_EXE_LINKER_FLAGS_INIT ${_hl_exe_link_flags})
  hermetic_append_flags(CMAKE_CXX_STANDARD_LIBRARIES_INIT ${_hl_cxx_libs})
  hermetic_append_flags(CMAKE_OBJCXX_STANDARD_LIBRARIES_INIT ${_hl_cxx_libs})

  # Exported for consumers (e.g. to find clang-tidy / clang-format).
  if(HERMETIC_REPRODUCIBLE)
    get_property(_hl_in_try_compile GLOBAL PROPERTY IN_TRY_COMPILE)
    if(NOT _hl_in_try_compile)
      set_property(GLOBAL PROPERTY HERMETIC_DEBUGGER_BUILD_DIR "${CMAKE_BINARY_DIR}")
      set_property(GLOBAL PROPERTY HERMETIC_DEBUGGER_MAPS
        "/hermetic-cpp/cache=${HERMETIC_CACHE_DIR}" "/hermetic-cpp/llvm=${_hl_root}")
      if(_hl_msvc)
        set_property(GLOBAL APPEND PROPERTY HERMETIC_DEBUGGER_MAPS "/hermetic-cpp/build=${CMAKE_BINARY_DIR}")
      endif()
      _hermetic_write_debugger_files()
    endif()
  endif()

  set(HERMETIC_LLVM_ROOT "${_hl_root}")
  set(HERMETIC_LLVM_BIN_DIR "${_hl_bin}")
  set(HERMETIC_LLVM_RUNTIME_SET "${_hl_set}")
  set(HERMETIC_SYSROOT_PATH "${_hl_sysroot}")
  set(HERMETIC_TARGET_TRIPLE "${_hl_triple}")
  set(HERMETIC_EFFECTIVE_LIBC "${HERMETIC_RESOLVED_LIBC}")
  if(_hl_mingw)
    set(HERMETIC_EFFECTIVE_LIBC "ucrt")
  endif()
  set(HERMETIC_EFFECTIVE_WINDOWS_ABI "${HERMETIC_RESOLVED_WINDOWS_ABI}")
  set(HERMETIC_EFFECTIVE_CXX_STDLIB "${HERMETIC_RESOLVED_CXX_STDLIB}")
  # Windows hosts building Windows targets: the SDK's own tools (midl, mc,
  # signtool, makeappx, dxc, ...) for custom commands; empty elsewhere.
  set(HERMETIC_WINDOWS_SDK_TOOLS_DIR "")
  if(_hl_windows)
    set(HERMETIC_WINDOWS_SDK_TOOLS_DIR "${_hl_sdk_tools}")
  endif()
  if(_hl_native)
    set(HERMETIC_CROSSCOMPILING FALSE)
  else()
    set(HERMETIC_CROSSCOMPILING TRUE)
  endif()
endmacro()
