# Copyright 2026 The hermetic-cpp-cmake Authors.
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
# HERMETIC_ACCEPT_MICROSOFT_EULA=1 (variable or environment) to confirm.

include_guard(GLOBAL)

function(hermetic_check_microsoft_eula)
  set(value "${HERMETIC_ACCEPT_MICROSOFT_EULA}")
  if(NOT value AND DEFINED ENV{HERMETIC_ACCEPT_MICROSOFT_EULA})
    set(value "$ENV{HERMETIC_ACCEPT_MICROSOFT_EULA}")
  endif()
  string(TOLOWER "${value}" value)
  if(NOT value MATCHES "^(1|on|yes|y|true)$")
    hermetic_fatal("Building for Windows uses the Microsoft Visual C++ runtime and the Windows SDK, whose licenses you must be entitled to (https://visualstudio.microsoft.com/license-terms/ and the Windows SDK license). Set HERMETIC_ACCEPT_MICROSOFT_EULA=1 to confirm and let the toolchain download them.")
  endif()
endfunction()

# Reads url and digest ("sha256" or "hash": "<ALGO>=<hex>") of a payload entry.
function(_hermetic_json_payload JSON OUT_URL OUT_HASH)
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
function(_hermetic_json_members JSON OUT)
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
      hermetic_fatal("Unknown ${WHAT} '${SPEC}'; known versions: ${known}")
    endif()
  endif()
  set(${OUT} "${chosen}" PARENT_SCOPE)
endfunction()

# Lists the MSVC toolset and Windows SDK versions in the table.
function(hermetic_windows_versions OUT_MSVC OUT_MSVC_DEFAULT OUT_SDK OUT_SDK_DEFAULT)
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/windows.json" json)
  string(JSON versions GET "${json}" "msvc" "versions")
  _hermetic_json_members("${versions}" msvc)
  string(JSON msvc_default GET "${json}" "msvc" "default")
  string(JSON versions GET "${json}" "windows_sdk" "versions")
  _hermetic_json_members("${versions}" sdk)
  string(JSON sdk_default GET "${json}" "windows_sdk" "default")
  set(${OUT_MSVC} "${msvc}" PARENT_SCOPE)
  set(${OUT_MSVC_DEFAULT} "${msvc_default}" PARENT_SCOPE)
  set(${OUT_SDK} "${sdk}" PARENT_SCOPE)
  set(${OUT_SDK_DEFAULT} "${sdk_default}" PARENT_SCOPE)
endfunction()

# Finds the single subdirectory of DIR (e.g. the versioned include dir).
function(_hermetic_single_subdir DIR OUT)
  file(GLOB entries LIST_DIRECTORIES true "${DIR}/*")
  set(dirs "")
  foreach(e IN LISTS entries)
    if(IS_DIRECTORY "${e}")
      list(APPEND dirs "${e}")
    endif()
  endforeach()
  list(LENGTH dirs n)
  if(NOT n EQUAL 1)
    hermetic_fatal("Expected exactly one directory under ${DIR}, found: ${dirs}")
  endif()
  set(${OUT} "${dirs}" PARENT_SCOPE)
endfunction()

# Writes a case-insensitive VFS overlay covering every directory in DIRS
# (used with clang's -ivfsoverlay and lld-link's /vfsoverlay:).
#
# By default the overlay names everything relative to its own directory
# ('root-relative' and 'overlay-relative'), so it holds no absolute path and
# works wherever the cache is and however it is reached (absolutely, through
# a build directory's link, or rewritten relative by a remote execution
# wrapper), provided the overlay and the directories it covers are named the
# same way. Files keep the name they were found by ('use-external-names'
# off), so that debug info and dependency output name them as the command
# line does, where the prefix maps (or a wrapper's rewrite) apply, rather
# than by the absolute path the overlay resolves them to. That suits clang;
# lld-link opens the files it finds by the name the overlay reports, so
# EXTERNAL_NAMES writes an overlay that reports their real (absolute) paths.
#
# With PREFIX_FROM and PREFIX_TO, the overlay instead names every path with
# that prefix replaced: a relative PREFIX_TO gives an overlay resolved
# against the working directory, whose real paths stay relative (what
# lld-link records in PDBs through a build directory's link).
function(hermetic_write_case_overlay OUT_FILE)
  cmake_parse_arguments(arg "EXTERNAL_NAMES" "PREFIX_FROM;PREFIX_TO" "" ${ARGN})
  set(dirs ${arg_UNPARSED_ARGUMENTS})
  get_filename_component(base "${OUT_FILE}" DIRECTORY)
  set(head "{\n  'version': 0,\n  'case-sensitive': 'false',\n")
  if(arg_PREFIX_FROM)
    # No absolute path here either: the file is an input of every link.
    string(REPLACE "${arg_PREFIX_FROM}" "${arg_PREFIX_TO}" rel_dirs "${dirs}")
    set(marker "# case overlay (from the working directory): ${rel_dirs}")
  else()
    set(rel_dirs "")
    foreach(dir IN LISTS dirs)
      file(RELATIVE_PATH rel "${base}" "${dir}")
      list(APPEND rel_dirs "${rel}")
    endforeach()
    string(APPEND head "  'root-relative': 'overlay-dir',\n  'overlay-relative': true,\n")
    if(arg_EXTERNAL_NAMES)
      set(marker "# case overlay (relative, external names): ${rel_dirs}")
    else()
      set(marker "# case overlay (relative, virtual names): ${rel_dirs}")
      string(APPEND head "  'use-external-names': false,\n")
    endif()
  endif()
  if(EXISTS "${OUT_FILE}")
    file(STRINGS "${OUT_FILE}" first LIMIT_COUNT 1)
    if(first STREQUAL marker)
      return()
    endif()
  endif()
  set(yaml "${marker}\n${head}  'roots': [\n")
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
      if(arg_PREFIX_FROM)
        string(REPLACE "${arg_PREFIX_FROM}" "${arg_PREFIX_TO}" root "${d}")
      else()
        file(RELATIVE_PATH root "${base}" "${d}")
      endif()
      string(APPEND yaml "    { 'name': '${root}', 'type': 'directory', 'contents': [\n")
      foreach(f IN LISTS files)
        get_filename_component(name "${f}" NAME)
        string(APPEND yaml "      { 'name': '${name}', 'type': 'file', 'external-contents': '${root}/${name}' },\n")
      endforeach()
      string(APPEND yaml "    ] },\n")
    endforeach()
  endforeach()
  string(APPEND yaml "  ]\n}\n")
  file(MAKE_DIRECTORY "${base}")
  file(WRITE "${OUT_FILE}" "${yaml}")
endfunction()

# Provides the MSVC runtime and Windows SDK for ARCH (x86_64 or aarch64).
# Sets ${OUT}_MSVC_VERSION, _MSVC_COMPAT_VERSION, _MSVC_INCLUDE, _MSVC_BIN
# (cl.exe's directory with HERMETIC_COMPILER=msvc, else empty), _MSVC_LIB (a
# list of directories, "|" separated),
# _SDK_VERSION, _SDK_INCLUDE_VERSION, _SDK_INCLUDE (…/Include/<ver>),
# _SDK_UCRT_LIB, _SDK_UM_LIB, _OVERLAY.
function(hermetic_provide_windows_sdk ARCH OUT)
  hermetic_check_microsoft_eula()
  hermetic_read_json("${HERMETIC_DIR}/cmake/distributions/windows.json" json)
  if(ARCH STREQUAL "x86_64")
    set(ms_arch x64)
  elseif(ARCH STREQUAL "aarch64")
    set(ms_arch arm64)
  else()
    hermetic_fatal("No MSVC runtime for architecture ${ARCH}")
  endif()

  hermetic_windows_versions(msvc_versions msvc_default sdk_versions sdk_default)
  hermetic_llvm_select_version("MSVC toolset (HERMETIC_MSVC_TOOLSET_VERSION)" "${HERMETIC_MSVC_TOOLSET_VERSION}" "${msvc_default}" "${msvc_versions}" msvc_version)
  hermetic_llvm_select_version("Windows SDK (HERMETIC_WINDOWS_SDK_VERSION)" "${HERMETIC_WINDOWS_SDK_VERSION}" "${sdk_default}" "${sdk_versions}" sdk_version)
  string(JSON toolset GET "${json}" "msvc" "versions" "${msvc_version}")
  string(JSON compat GET "${toolset}" "compatibility_version")
  string(JSON headers GET "${toolset}" "headers")
  _hermetic_json_payload("${headers}" url hash)
  hermetic_fetch_archive(NAME "msvc-${msvc_version}-headers" KIND msvc HASH "${hash}" URLS "${url}"
    STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR headers_dir)
  _hermetic_single_subdir("${headers_dir}/Contents/VC/Tools/MSVC" toolset_dir)
  get_filename_component(toolset_dir_name "${toolset_dir}" NAME)
  if(NOT toolset_dir_name STREQUAL msvc_version)
    hermetic_fatal("MSVC headers package contains toolset ${toolset_dir_name}, expected ${msvc_version}; regenerate cmake/distributions/windows.json")
  endif()
  set(msvc_include "${toolset_dir}/include")
  if(NOT IS_DIRECTORY "${msvc_include}")
    hermetic_fatal("MSVC headers package did not contain ${msvc_include}")
  endif()
  # Static (Desktop) and dynamic (Store) CRT libraries come as separate
  # payloads; each is kept in its own directory and both are library paths.
  string(JSON libs ERROR_VARIABLE err GET "${toolset}" "libs" "${ARCH}")
  if(err)
    hermetic_fatal("MSVC toolset ${msvc_version} has no ${ms_arch} libraries in the manifest")
  endif()
  string(JSON nlibs LENGTH "${libs}")
  set(msvc_lib "")
  math(EXPR last "${nlibs} - 1")
  foreach(i RANGE ${last})
    string(JSON entry GET "${libs}" ${i})
    string(JSON package GET "${entry}" "package")
    _hermetic_json_payload("${entry}" url hash)
    string(TOLOWER "${package}" package_lower)
    string(REGEX REPLACE ".*\\.crt\\." "" kind "${package_lower}")
    string(REPLACE "." "-" kind "${kind}")
    hermetic_fetch_archive(NAME "msvc-${msvc_version}-${kind}" KIND msvc HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR libs_dir)
    set(dir "${libs_dir}/Contents/VC/Tools/MSVC/${msvc_version}/lib/${ms_arch}")
    if(NOT IS_DIRECTORY "${dir}")
      hermetic_fatal("MSVC package ${package} did not contain ${dir}")
    endif()
    list(APPEND msvc_lib "${dir}")
  endforeach()

  # HERMETIC_COMPILER=msvc: the compilers for this host and target
  # architecture (cl, c1, c2, link, lib and their DLLs) from the same
  # manifest, with cl.exe's English message resources (1033/clui.dll) copied
  # next to it, since cl.exe refuses to run without them.
  set(msvc_bin "")
  if(HERMETIC_COMPILER STREQUAL "msvc")
    hermetic_detect_host(tools_host_os tools_host_arch)
    string(JSON tools ERROR_VARIABLE err GET "${toolset}" "tools" "${tools_host_arch}" "${ARCH}")
    if(err)
      hermetic_fatal("MSVC toolset ${msvc_version} has no compilers for a ${tools_host_arch} host targeting ${ARCH} in the manifest")
    endif()
    string(JSON entry GET "${tools}" 0)
    _hermetic_json_payload("${entry}" url hash)
    hermetic_fetch_archive(NAME "msvc-${msvc_version}-tools-${tools_host_arch}-${ms_arch}" KIND msvc HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR tools_dir)
    file(GLOB cl_exe "${tools_dir}/Contents/VC/Tools/MSVC/${msvc_version}/bin/Host*/${ms_arch}/cl.exe")
    list(LENGTH cl_exe n_cl)
    if(NOT n_cl EQUAL 1)
      hermetic_fatal("MSVC compiler package did not contain one bin/Host*/${ms_arch}/cl.exe (found: '${cl_exe}')")
    endif()
    get_filename_component(msvc_bin "${cl_exe}" DIRECTORY)
    string(JSON entry GET "${tools}" 1)
    _hermetic_json_payload("${entry}" url hash)
    hermetic_fetch_archive(NAME "msvc-${msvc_version}-tools-${tools_host_arch}-${ms_arch}-res" KIND msvc HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "Contents/VC" OUT_DIR res_dir)
    file(GLOB clui "${res_dir}/Contents/VC/Tools/MSVC/${msvc_version}/bin/Host*/${ms_arch}/1033/clui.dll")
    if(NOT clui)
      hermetic_fatal("MSVC compiler resource package did not contain 1033/clui.dll")
    endif()
    if(NOT EXISTS "${msvc_bin}/1033/clui.dll")
      file(COPY ${clui} DESTINATION "${msvc_bin}/1033")
    endif()
  endif()

  string(JSON sdk GET "${json}" "windows_sdk" "versions" "${sdk_version}")
  string(JSON pkg GET "${sdk}" "packages" "Microsoft.Windows.SDK.CPP")
  _hermetic_json_payload("${pkg}" url hash)
  # The same package carries the SDK's tools (rc, mt, midl, mc, signtool,
  # makeappx, dxc, ...), Windows executables: on a Windows host the ones for
  # its architecture are extracted alongside the headers and their directory
  # exported as HERMETIC_WINDOWS_SDK_TOOLS_DIR.
  hermetic_detect_host(host_os host_arch)
  set(tools "")
  if(host_os STREQUAL "windows")
    if(host_arch STREQUAL "aarch64")
      set(host_ms_arch arm64)
    else()
      set(host_ms_arch x64)
    endif()
    # (The glob also matches a few legacy GenXBF.dll directories for older
    # SDK versions; the tools directory is the one matching the headers.)
    hermetic_fetch_archive(NAME "winsdk-${sdk_version}-headers-tools-${host_ms_arch}" KIND winsdk HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "c/Include" "c/bin/*/${host_ms_arch}/*" OUT_DIR sdk_dir)
  else()
    hermetic_fetch_archive(NAME "winsdk-${sdk_version}-headers" KIND winsdk HASH "${hash}" URLS "${url}"
      STRIP_COMPONENTS 0 PATTERNS "c/Include" OUT_DIR sdk_dir)
  endif()
  _hermetic_single_subdir("${sdk_dir}/c/Include" sdk_include)
  get_filename_component(sdk_include_version "${sdk_include}" NAME)
  if(host_os STREQUAL "windows")
    set(tools "${sdk_dir}/c/bin/${sdk_include_version}/${host_ms_arch}")
    if(NOT EXISTS "${tools}/mt.exe")
      hermetic_fatal("Windows SDK package did not contain the ${host_ms_arch} tools under ${tools}")
    endif()
  endif()
  string(JSON pkg GET "${sdk}" "packages" "Microsoft.Windows.SDK.CPP.${ms_arch}")
  _hermetic_json_payload("${pkg}" url hash)
  hermetic_fetch_archive(NAME "winsdk-${sdk_version}-${ms_arch}" KIND winsdk HASH "${hash}" URLS "${url}"
    STRIP_COMPONENTS 0 PATTERNS "c/ucrt/" "c/um/" OUT_DIR sdk_arch_dir)
  set(sdk_ucrt_lib "${sdk_arch_dir}/c/ucrt/${ms_arch}")
  set(sdk_um_lib "${sdk_arch_dir}/c/um/${ms_arch}")
  foreach(d "${sdk_ucrt_lib}" "${sdk_um_lib}")
    if(NOT IS_DIRECTORY "${d}")
      hermetic_fatal("Windows SDK ${ms_arch} package did not contain ${d}")
    endif()
  endforeach()

  set(overlay "${HERMETIC_CACHE_DIR}/winsdk/overlays/msvc-${msvc_version}-sdk-${sdk_version}-${ms_arch}.yaml")
  # For compilation, and for links: through a build directory's link to the
  # cache (hermetic_windows_flags RELATIVE_ROOT), so that the library
  # paths lld-link resolves stay relative, or from anywhere.
  hermetic_write_case_overlay("${overlay}" "${msvc_include}" ${msvc_lib} "${sdk_include}" "${sdk_ucrt_lib}" "${sdk_um_lib}")
  hermetic_write_case_overlay("${overlay}.link.yaml"
    PREFIX_FROM "${HERMETIC_CACHE_DIR}" PREFIX_TO "${HERMETIC_CACHE_LINK_NAME}"
    ${msvc_lib} "${sdk_ucrt_lib}" "${sdk_um_lib}")
  hermetic_write_case_overlay("${overlay}.lib.yaml" EXTERNAL_NAMES ${msvc_lib} "${sdk_ucrt_lib}" "${sdk_um_lib}")

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
  set(${OUT}_MSVC_BIN "${msvc_bin}" PARENT_SCOPE)
  set(${OUT}_TOOLS "${tools}" PARENT_SCOPE)
endfunction()

# Sets ${OUT} to TRUE when the manifest tool MT (the prebuilt's llvm-mt)
# merges manifests: only prebuilts whose LLVM is built with libxml2 do, and
# lld-link embeds manifests with the same library (older prebuilts would
# have it run mt.exe from the PATH instead). The check merges a minimal
# manifest in WORK_DIR.
function(hermetic_manifest_merging_works MT WORK_DIR OUT)
  set(${OUT} FALSE PARENT_SCOPE)
  if(NOT EXISTS "${MT}")
    return()
  endif()
  file(WRITE "${WORK_DIR}/probe.manifest"
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\"/>\n")
  file(REMOVE "${WORK_DIR}/merged.manifest")
  execute_process(COMMAND "${MT}" /nologo /manifest "${WORK_DIR}/probe.manifest" "/out:${WORK_DIR}/merged.manifest"
    RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
  if(rc EQUAL 0 AND EXISTS "${WORK_DIR}/merged.manifest")
    set(${OUT} TRUE PARENT_SCOPE)
  endif()
endfunction()

# Compile and link flags for the MSVC ABI environment described by a
# HERMETIC_RESOLVED_WINSDK list (see hermetic_resolve), following
# hermetic-llvm's windows/msvc argument groups: explicit MSVC and SDK include
# and library paths, a case-insensitive VFS overlay for the SDK's mixed-case
# names, deterministic objects and links. Used by the consumer toolchain and
# by the runtime set build alike.
#
# With EMBED_MANIFEST, links embed a manifest (see
# hermetic_manifest_merging_works); without it they get none.
#
# With RELATIVE_ROOT <name>, the link step addresses the toolset and SDK
# through <name> in place of the cache directory (a link to it in the build
# directory, see hermetic_configure): the library paths, the overlay
# and the paths clang-cl derives for lld-link (OUT_LINK_DRIVER, driver
# options for the link command, which override the compile-time ones) are
# then relative, and lld-link records them under /pdbsourcepath rather than
# under the cache directory, whose location differs from machine to machine.
function(hermetic_windows_flags WINSDK ARCH OUT_COMPILE OUT_LINK)
  cmake_parse_arguments(arg "EMBED_MANIFEST" "RELATIVE_ROOT;OUT_LINK_DRIVER" "" ${ARGN})
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
  set(link_driver "")
  set(link_overlay "${overlay}.lib.yaml")
  if(arg_RELATIVE_ROOT)
    set(link_overlay "${overlay}.link.yaml")
    foreach(var toolset_dir sdk_root msvc_lib sdk_ucrt_lib sdk_um_lib link_overlay)
      string(REPLACE "${HERMETIC_CACHE_DIR}" "${arg_RELATIVE_ROOT}" ${var} "${${var}}")
    endforeach()
    set(link_driver "/vctoolsdir${toolset_dir}" "/winsdkdir${sdk_root}")
  endif()
  set(link "")
  foreach(dir IN LISTS msvc_lib)
    list(APPEND link "/LIBPATH:${dir}")
  endforeach()
  list(APPEND link
    "/LIBPATH:${sdk_ucrt_lib}" "/LIBPATH:${sdk_um_lib}"
    "/vfsoverlay:${link_overlay}" /Brepro /INCREMENTAL:NO /lldignoreenv
    # Sanitized links get /DEBUG from the driver; keep the PDB path out of
    # the executable so it stays identical across hosts.
    "/pdbaltpath:%_PDB%")
  if(arg_EMBED_MANIFEST)
    # As link.exe does for CMake's MSVC rules: the default manifest (UAC
    # level asInvoker) as a resource, merged with any /MANIFESTINPUT: file.
    list(APPEND link /MANIFEST:EMBED)
  else()
    list(APPEND link /MANIFEST:NO)
  endif()
  if(ARCH STREQUAL "aarch64")
    list(APPEND link /MACHINE:ARM64)
  else()
    list(APPEND link /MACHINE:X64)
  endif()
  set(${OUT_COMPILE} "${compile}" PARENT_SCOPE)
  set(${OUT_LINK} "${link}" PARENT_SCOPE)
  if(arg_OUT_LINK_DRIVER)
    set(${arg_OUT_LINK_DRIVER} "${link_driver}" PARENT_SCOPE)
  endif()
endfunction()
