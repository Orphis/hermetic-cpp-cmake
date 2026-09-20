# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Windows (MSVC ABI) targets: the MSVC C runtime and STL headers and
# libraries come from the Visual Studio installer manifest (VSIX payloads),
# the Windows SDK from the public NuGet packages, exactly as
# hermeticbuild/windows_support does. Both are zip archives. A Clang VFS
# overlay with case-insensitive lookup makes the SDK's mixed-case file names
# resolve on case-sensitive filesystems.
#
# Using these files requires accepting Microsoft's licenses; set
# HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA=1 (variable or environment) to confirm.

include_guard(GLOBAL)

function(hermetic_llvm_check_microsoft_eula)
  set(value "${HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA}")
  if(NOT value AND DEFINED ENV{HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA})
    set(value "$ENV{HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA}")
  endif()
  string(TOLOWER "${value}" value)
  if(NOT value MATCHES "^(1|on|yes|y|true)$")
    hermetic_llvm_fatal("Building for Windows uses the Microsoft Visual C++ runtime and the Windows SDK, whose licenses you must be entitled to (https://visualstudio.microsoft.com/license-terms/ and the Windows SDK license). Set HERMETIC_LLVM_ACCEPT_MICROSOFT_EULA=1 to confirm and let the toolchain download them.")
  endif()
endfunction()

# Reads url and digest ("sha256" or "hash": "<ALGO>=<hex>") of a payload entry.
function(_hermetic_llvm_json_payload JSON OUT_URL OUT_HASH)
  string(JSON url GET "${JSON}" "url")
  string(JSON sha ERROR_VARIABLE err GET "${JSON}" "sha256")
  if(NOT err)
    set(hash "SHA256=${sha}")
  else()
    string(JSON hash GET "${JSON}" "hash")
  endif()
  set(${OUT_URL} "${url}" PARENT_SCOPE)
  set(${OUT_HASH} "${hash}" PARENT_SCOPE)
endfunction()

# Lists the member names of a JSON object.
function(_hermetic_llvm_json_members JSON OUT)
  string(JSON n LENGTH "${JSON}")
  set(names "")
  if(n GREATER 0)
    math(EXPR last "${n} - 1")
    foreach(i RANGE ${last})
      string(JSON name MEMBER "${JSON}" ${i})
      list(APPEND names "${name}")
    endforeach()
  endif()
  set(${OUT} "${names}" PARENT_SCOPE)
endfunction()

# Resolves SPEC against VERSIONS (dotted versions): exact, "latest", "default"
# (DEFAULT), or a prefix such as "10.0.22621" selecting its newest version.
function(hermetic_llvm_select_version WHAT SPEC DEFAULT VERSIONS OUT)
  if(NOT SPEC OR SPEC STREQUAL "default")
    set(SPEC "${DEFAULT}")
  endif()
  set(sorted "${VERSIONS}")
  list(SORT sorted COMPARE NATURAL ORDER DESCENDING)
  if(SPEC STREQUAL "latest")
    list(GET sorted 0 chosen)
  elseif(SPEC IN_LIST VERSIONS)
    set(chosen "${SPEC}")
  else()
    set(chosen "")
    foreach(v IN LISTS sorted)
      if(v MATCHES "^${SPEC}(\\.|$)")
        set(chosen "${v}")
        break()
      endif()
    endforeach()
    if(NOT chosen)
      string(REPLACE ";" ", " known "${sorted}")
      hermetic_llvm_fatal("Unknown ${WHAT} '${SPEC}'; known versions: ${known}")
    endif()
  endif()
  set(${OUT} "${chosen}" PARENT_SCOPE)
endfunction()

# Lists the MSVC toolset and Windows SDK versions in the table.
function(hermetic_llvm_windows_versions OUT_MSVC OUT_MSVC_DEFAULT OUT_SDK OUT_SDK_DEFAULT)
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/windows.json" json)
  string(JSON versions GET "${json}" "msvc" "versions")
  _hermetic_llvm_json_members("${versions}" msvc)
  string(JSON msvc_default GET "${json}" "msvc" "default")
  string(JSON versions GET "${json}" "windows_sdk" "versions")
  _hermetic_llvm_json_members("${versions}" sdk)
  string(JSON sdk_default GET "${json}" "windows_sdk" "default")
  set(${OUT_MSVC} "${msvc}" PARENT_SCOPE)
  set(${OUT_MSVC_DEFAULT} "${msvc_default}" PARENT_SCOPE)
  set(${OUT_SDK} "${sdk}" PARENT_SCOPE)
  set(${OUT_SDK_DEFAULT} "${sdk_default}" PARENT_SCOPE)
endfunction()

# Finds the single subdirectory of DIR (e.g. the versioned include dir).
function(_hermetic_llvm_single_subdir DIR OUT)
  file(GLOB entries LIST_DIRECTORIES true "${DIR}/*")
  set(dirs "")
  foreach(e IN LISTS entries)
    if(IS_DIRECTORY "${e}")
      list(APPEND dirs "${e}")
    endif()
  endforeach()
  list(LENGTH dirs n)
  if(NOT n EQUAL 1)
    hermetic_llvm_fatal("Expected exactly one directory under ${DIR}, found: ${dirs}")
  endif()
  set(${OUT} "${dirs}" PARENT_SCOPE)
endfunction()

# Writes a case-insensitive VFS overlay covering every directory in DIRS
# (used with clang's -ivfsoverlay and lld-link's /vfsoverlay:).
function(hermetic_llvm_write_case_overlay OUT_FILE)
  set(dirs ${ARGN})
  set(marker "# roots: ${dirs}")
  if(EXISTS "${OUT_FILE}")
    file(STRINGS "${OUT_FILE}" first LIMIT_COUNT 1)
    if(first STREQUAL marker)
      return()
    endif()
  endif()
  set(yaml "${marker}\n{\n  'version': 0,\n  'case-sensitive': 'false',\n  'roots': [\n")
  foreach(dir IN LISTS dirs)
    file(GLOB_RECURSE subdirs LIST_DIRECTORIES true "${dir}/*")
    set(all_dirs "${dir}")
    foreach(s IN LISTS subdirs)
      if(IS_DIRECTORY "${s}")
        list(APPEND all_dirs "${s}")
      endif()
    endforeach()
    foreach(d IN LISTS all_dirs)
      file(GLOB files LIST_DIRECTORIES false "${d}/*")
      if(NOT files)
        continue()
      endif()
      string(APPEND yaml "    { 'name': '${d}', 'type': 'directory', 'contents': [\n")
      foreach(f IN LISTS files)
        get_filename_component(name "${f}" NAME)
        string(APPEND yaml "      { 'name': '${name}', 'type': 'file', 'external-contents': '${f}' },\n")
      endforeach()
      string(APPEND yaml "    ] },\n")
    endforeach()
  endforeach()
  string(APPEND yaml "  ]\n}\n")
  get_filename_component(parent "${OUT_FILE}" DIRECTORY)
  file(MAKE_DIRECTORY "${parent}")
  file(WRITE "${OUT_FILE}" "${yaml}")
endfunction()

# Provides the MSVC runtime and Windows SDK for ARCH (x86_64 or aarch64).
# Sets ${OUT}_MSVC_VERSION, _MSVC_COMPAT_VERSION, _MSVC_INCLUDE, _MSVC_LIB (a
# list of directories, "|" separated),
# _SDK_VERSION, _SDK_INCLUDE_VERSION, _SDK_INCLUDE (…/Include/<ver>),
# _SDK_UCRT_LIB, _SDK_UM_LIB, _OVERLAY.
function(hermetic_llvm_provide_windows_sdk ARCH OUT)
  hermetic_llvm_check_microsoft_eula()
  hermetic_llvm_read_json("${HERMETIC_LLVM_DIR}/cmake/distributions/windows.json" json)
  if(ARCH STREQUAL "x86_64")
    set(ms_arch x64)
  elseif(ARCH STREQUAL "aarch64")
    set(ms_arch arm64)
  else()
    hermetic_llvm_fatal("No MSVC runtime for architecture ${ARCH}")
  endif()

  hermetic_llvm_windows_versions(msvc_versions msvc_default sdk_versions sdk_default)
  hermetic_llvm_select_version("MSVC toolset (HERMETIC_LLVM_MSVC_VERSION)" "${HERMETIC_LLVM_MSVC_VERSION}" "${msvc_default}" "${msvc_versions}" msvc_version)
  hermetic_llvm_select_version("Windows SDK (HERMETIC_LLVM_WINDOWS_SDK_VERSION)" "${HERMETIC_LLVM_WINDOWS_SDK_VERSION}" "${sdk_default}" "${sdk_versions}" sdk_version)
  string(JSON toolset GET "${json}" "msvc" "versions" "${msvc_version}")
  string(JSON compat GET "${toolset}" "compatibility_version")
  string(JSON headers GET "${toolset}" "headers")
  _hermetic_llvm_json_payload("${headers}" url hash)
  hermetic_llvm_fetch_archive(NAME "msvc-${msvc_version}-headers" KIND msvc HASH "${hash}" URLS "${url}"
    STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR headers_dir)
  _hermetic_llvm_single_subdir("${headers_dir}/Contents/VC/Tools/MSVC" toolset_dir)
  get_filename_component(toolset_dir_name "${toolset_dir}" NAME)
  if(NOT toolset_dir_name STREQUAL msvc_version)
    hermetic_llvm_fatal("MSVC headers package contains toolset ${toolset_dir_name}, expected ${msvc_version}; regenerate cmake/distributions/windows.json")
  endif()
  set(msvc_include "${toolset_dir}/include")
  if(NOT IS_DIRECTORY "${msvc_include}")
    hermetic_llvm_fatal("MSVC headers package did not contain ${msvc_include}")
  endif()
  # Static (Desktop) and dynamic (Store) CRT libraries come as separate
  # payloads; each is kept in its own directory and both are library paths.
  string(JSON libs ERROR_VARIABLE err GET "${toolset}" "libs" "${ARCH}")
  if(err)
    hermetic_llvm_fatal("MSVC toolset ${msvc_version} has no ${ms_arch} libraries in the manifest")
  endif()
  string(JSON nlibs LENGTH "${libs}")
  set(msvc_lib "")
  math(EXPR last "${nlibs} - 1")
  foreach(i RANGE ${last})
    string(JSON entry GET "${libs}" ${i})
    string(JSON package GET "${entry}" "package")
    _hermetic_llvm_json_payload("${entry}" url hash)
    string(TOLOWER "${package}" package_lower)
    string(REGEX REPLACE ".*\\.crt\\." "" kind "${package_lower}")
    string(REPLACE "." "-" kind "${kind}")
    hermetic_llvm_fetch_archive(NAME "msvc-${msvc_version}-${kind}" KIND msvc HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR libs_dir)
    set(dir "${libs_dir}/Contents/VC/Tools/MSVC/${msvc_version}/lib/${ms_arch}")
    if(NOT IS_DIRECTORY "${dir}")
      hermetic_llvm_fatal("MSVC package ${package} did not contain ${dir}")
    endif()
    list(APPEND msvc_lib "${dir}")
  endforeach()

  string(JSON sdk GET "${json}" "windows_sdk" "versions" "${sdk_version}")
  string(JSON pkg GET "${sdk}" "packages" "Microsoft.Windows.SDK.CPP")
  _hermetic_llvm_json_payload("${pkg}" url hash)
  hermetic_llvm_fetch_archive(NAME "winsdk-${sdk_version}-headers" KIND winsdk HASH "${hash}" URLS "${url}"
    STRIP_COMPONENTS 0 PATTERNS "c/Include" OUT_DIR sdk_dir)
  _hermetic_llvm_single_subdir("${sdk_dir}/c/Include" sdk_include)
  get_filename_component(sdk_include_version "${sdk_include}" NAME)
  string(JSON pkg GET "${sdk}" "packages" "Microsoft.Windows.SDK.CPP.${ms_arch}")
  _hermetic_llvm_json_payload("${pkg}" url hash)
  hermetic_llvm_fetch_archive(NAME "winsdk-${sdk_version}-${ms_arch}" KIND winsdk HASH "${hash}" URLS "${url}"
    STRIP_COMPONENTS 0 PATTERNS "c/ucrt/" "c/um/" OUT_DIR sdk_arch_dir)
  set(sdk_ucrt_lib "${sdk_arch_dir}/c/ucrt/${ms_arch}")
  set(sdk_um_lib "${sdk_arch_dir}/c/um/${ms_arch}")
  foreach(d "${sdk_ucrt_lib}" "${sdk_um_lib}")
    if(NOT IS_DIRECTORY "${d}")
      hermetic_llvm_fatal("Windows SDK ${ms_arch} package did not contain ${d}")
    endif()
  endforeach()

  set(overlay "${HERMETIC_LLVM_CACHE_DIR}/winsdk/overlays/msvc-${msvc_version}-sdk-${sdk_version}-${ms_arch}.yaml")
  hermetic_llvm_write_case_overlay("${overlay}" "${msvc_include}" ${msvc_lib} "${sdk_include}" "${sdk_ucrt_lib}" "${sdk_um_lib}")

  set(${OUT}_MSVC_VERSION "${msvc_version}" PARENT_SCOPE)
  set(${OUT}_MSVC_COMPAT_VERSION "${compat}" PARENT_SCOPE)
  set(${OUT}_MSVC_INCLUDE "${msvc_include}" PARENT_SCOPE)
  string(REPLACE ";" "|" msvc_lib "${msvc_lib}")
  set(${OUT}_MSVC_LIB "${msvc_lib}" PARENT_SCOPE)
  set(${OUT}_SDK_VERSION "${sdk_version}" PARENT_SCOPE)
  set(${OUT}_SDK_INCLUDE_VERSION "${sdk_include_version}" PARENT_SCOPE)
  set(${OUT}_SDK_INCLUDE "${sdk_include}" PARENT_SCOPE)
  set(${OUT}_SDK_UCRT_LIB "${sdk_ucrt_lib}" PARENT_SCOPE)
  set(${OUT}_SDK_UM_LIB "${sdk_um_lib}" PARENT_SCOPE)
  set(${OUT}_OVERLAY "${overlay}" PARENT_SCOPE)
endfunction()

# Compile and link flags for the MSVC ABI environment described by a
# HERMETIC_LLVM_RESOLVED_WINSDK list (see hermetic_llvm_resolve), following
# hermetic-llvm's windows/msvc argument groups: explicit MSVC and SDK include
# and library paths, a case-insensitive VFS overlay for the SDK's mixed-case
# names, deterministic objects and links. Used by the consumer toolchain and
# by the runtime set build alike.
function(hermetic_llvm_windows_flags WINSDK ARCH OUT_COMPILE OUT_LINK)
  list(GET WINSDK 1 compat)
  list(GET WINSDK 2 msvc_include)
  list(GET WINSDK 3 msvc_lib)
  string(REPLACE "|" ";" msvc_lib "${msvc_lib}")
  list(GET WINSDK 5 sdk_include_version)
  list(GET WINSDK 6 sdk_include)
  list(GET WINSDK 7 sdk_ucrt_lib)
  list(GET WINSDK 8 sdk_um_lib)
  list(GET WINSDK 9 overlay)
  get_filename_component(toolset_dir "${msvc_include}" DIRECTORY)
  get_filename_component(sdk_root "${sdk_include}/../.." ABSOLUTE)
  # The toolset and SDK are named through clang's own options rather than
  # /imsvc: the driver then adds the include directories itself (in the
  # same order) and stops looking for a Visual Studio installation or the
  # INCLUDE/LIB environment on Windows hosts. The SDK libraries are not laid
  # out as the driver expects, so those stay explicit /LIBPATH entries.
  set(compile
    "-fms-compatibility-version=${compat}"
    "/vctoolsdir${toolset_dir}" "/winsdkdir${sdk_root}" "/winsdkversion${sdk_include_version}"
    -Xclang -ivfsoverlay -Xclang "${overlay}"
    /Brepro /clang:-gno-codeview-command-line)
  set(link "")
  foreach(dir IN LISTS msvc_lib)
    list(APPEND link "/LIBPATH:${dir}")
  endforeach()
  list(APPEND link
    "/LIBPATH:${sdk_ucrt_lib}" "/LIBPATH:${sdk_um_lib}"
    "/vfsoverlay:${overlay}" /Brepro /INCREMENTAL:NO /lldignoreenv
    # Sanitized links get /DEBUG from the driver; keep the PDB path out of
    # the executable so it stays identical across hosts.
    "/pdbaltpath:%_PDB%"
    # No manifest embedding: it would need llvm-mt, which the prebuilt
    # lacks libxml2 for; lld-link can embed one on request.
    /MANIFEST:NO)
  if(ARCH STREQUAL "aarch64")
    list(APPEND link /MACHINE:ARM64)
  else()
    list(APPEND link /MACHINE:X64)
  endif()
  set(${OUT_COMPILE} "${compile}" PARENT_SCOPE)
  set(${OUT_LINK} "${link}" PARENT_SCOPE)
endfunction()
