# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# vcpkg ports. vcpkg configures every port with its own toolchain file
# (scripts/buildsystems/vcpkg.cmake), which chain-loads this one when the
# triplet names it (VCPKG_CHAINLOAD_TOOLCHAIN_FILE; vcpkg/hermetic-triplet.cmake
# does), and passes the triplet's settings as cache variables. vcpkg's own
# platform toolchains (scripts/toolchains/*.cmake) turn those into flags; a
# chain-loaded toolchain replaces them, so it reads them here:
#
# - VCPKG_CRT_LINKAGE: the C runtime of MSVC ABI targets. vcpkg's Windows
#   toolchain sets CMAKE_MSVC_RUNTIME_LIBRARY from it; without that, ports
#   were built against the DLL runtime whatever the triplet asked for.
# - VCPKG_C_FLAGS, VCPKG_CXX_FLAGS, VCPKG_LINKER_FLAGS (and their _DEBUG and
#   _RELEASE variants): the triplet's own flags.
# - Position-independent code for ELF targets, as vcpkg's Linux toolchain
#   does: static libraries of ports end up in shared libraries too.
# - Paths: debug info names the port's sources (<buildtrees>/<port>/src/...)
#   and its dependencies' headers (<installed>/<triplet>/include) where this
#   vcpkg checkout keeps them. They are mapped to /vcpkg/buildtrees and
#   /vcpkg/installed, so a binary cache serves the same bytes to every
#   machine.
#
# The consuming project (the one that uses vcpkg.cmake as its toolchain and
# installs a manifest) must be built for the same target, with the same C
# runtime: when VCPKG_TARGET_TRIPLET names a triplet made with
# vcpkg/hermetic-triplet.cmake, its HERMETIC_* options become the defaults,
# and on MSVC ABI targets its VCPKG_CRT_LINKAGE the default
# CMAKE_MSVC_RUNTIME_LIBRARY. The project maps its own paths,
# VCPKG_INSTALLED_DIR included (see README.md).

include_guard(GLOBAL)

list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
  VCPKG_CRT_LINKAGE VCPKG_TARGET_ARCHITECTURE
  VCPKG_C_FLAGS VCPKG_CXX_FLAGS VCPKG_C_FLAGS_DEBUG VCPKG_CXX_FLAGS_DEBUG
  VCPKG_C_FLAGS_RELEASE VCPKG_CXX_FLAGS_RELEASE
  VCPKG_LINKER_FLAGS VCPKG_LINKER_FLAGS_DEBUG VCPKG_LINKER_FLAGS_RELEASE)

function(_hermetic_vcpkg_port_build OUT)
  # vcpkg_cmake_configure passes both to every port (and so does
  # vcpkg_cmake_get_vars, which extracts the flags that autotools, Meson and
  # other ports build with); a project that merely uses vcpkg.cmake has
  # neither on its first configure.
  if(DEFINED VCPKG_CRT_LINKAGE AND DEFINED _VCPKG_INSTALLED_DIR)
    set(${OUT} TRUE PARENT_SCOPE)
  else()
    set(${OUT} FALSE PARENT_SCOPE)
  endif()
endfunction()

# The options of the triplet VCPKG_TARGET_TRIPLET names, found in the
# overlay directories or vcpkg/triplets, become defaults. Runs before the
# options get theirs; the command line's win.
function(hermetic_vcpkg_triplet_defaults)
  set(_HERMETIC_VCPKG_TRIPLET_CRT "" PARENT_SCOPE)
  if(NOT VCPKG_TARGET_TRIPLET)
    return()
  endif()
  _hermetic_vcpkg_port_build(port)
  if(port)
    return()  # vcpkg passes the triplet's options itself
  endif()
  set(dirs ${VCPKG_OVERLAY_TRIPLETS})
  if(DEFINED ENV{VCPKG_OVERLAY_TRIPLETS})
    if(CMAKE_HOST_WIN32)
      list(APPEND dirs "$ENV{VCPKG_OVERLAY_TRIPLETS}")
    else()
      string(REPLACE ":" ";" env_dirs "$ENV{VCPKG_OVERLAY_TRIPLETS}")
      list(APPEND dirs ${env_dirs})
    endif()
  endif()
  list(APPEND dirs "${HERMETIC_DIR}/vcpkg/triplets")
  set(file "")
  foreach(dir IN LISTS dirs)
    if(EXISTS "${dir}/${VCPKG_TARGET_TRIPLET}.cmake")
      set(file "${dir}/${VCPKG_TARGET_TRIPLET}.cmake")
      break()
    endif()
  endforeach()
  if(NOT file)
    return()
  endif()

  get_cmake_property(vars VARIABLES)
  set(before "")
  foreach(var IN LISTS vars)
    if(var MATCHES "^HERMETIC_")
      list(APPEND before "${var}")
      set(before_${var} "${${var}}")
    endif()
  endforeach()
  unset(VCPKG_CRT_LINKAGE)
  # hermetic-triplet.cmake returns once it has listed the options.
  set(_HERMETIC_VCPKG_READ_OPTIONS TRUE)
  include("${file}")
  if(NOT DEFINED _hermetic_vcpkg_options)
    return()  # a triplet of some other toolchain
  endif()
  hermetic_log("vcpkg triplet ${VCPKG_TARGET_TRIPLET}: ${file}")
  foreach(var IN LISTS _hermetic_vcpkg_options)
    if(NOT var IN_LIST before)
      set(${var} "${${var}}" PARENT_SCOPE)
    elseif(NOT "${before_${var}}" STREQUAL "${${var}}")
      message(WARNING "[hermetic-cpp] ${var}=${before_${var}} differs from the vcpkg triplet ${VCPKG_TARGET_TRIPLET} (${${var}}): the project and its vcpkg packages are built differently")
    endif()
  endforeach()
  set(_HERMETIC_VCPKG_TRIPLET_CRT "${VCPKG_CRT_LINKAGE}" PARENT_SCOPE)
endfunction()

# Run after hermetic_configure, whose _hl_* variables it reads.
macro(hermetic_vcpkg_setup)
  _hermetic_vcpkg_port_build(HERMETIC_VCPKG_PORT_BUILD)
  if(HERMETIC_VCPKG_PORT_BUILD)
    _hermetic_vcpkg_port_setup()
  elseif(_HERMETIC_VCPKG_TRIPLET_CRT AND _hl_windows)
    _hermetic_vcpkg_msvc_runtime("${_HERMETIC_VCPKG_TRIPLET_CRT}")
  endif()
endmacro()

# The triplet's C runtime, as vcpkg's Windows toolchain sets it, unless the
# project chose one.
macro(_hermetic_vcpkg_msvc_runtime LINKAGE)
  if(NOT "${LINKAGE}" MATCHES "^(static|dynamic)$")
    hermetic_fatal("VCPKG_CRT_LINKAGE must be static or dynamic, not \"${LINKAGE}\"")
  endif()
  set(_hv_runtime "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  if("${LINKAGE}" STREQUAL "dynamic")
    string(APPEND _hv_runtime "DLL")
  endif()
  set(CMAKE_MSVC_RUNTIME_LIBRARY "${_hv_runtime}" CACHE STRING "")
endmacro()

macro(_hermetic_vcpkg_port_setup)
  if(_hl_windows)
    # Ports that still ask for CMake before 3.15 only follow it with
    # CMP0091, which cmake_minimum_required sets before this file runs:
    # hermetic-triplet.cmake sets it on the command line.
    _hermetic_vcpkg_msvc_runtime("${VCPKG_CRT_LINKAGE}")
  elseif(NOT _hl_mingw AND NOT _hl_tgt_OS STREQUAL "wasm")
    foreach(_hv_lang C CXX)
      hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT -fPIC)
    endforeach()
  endif()

  if(HERMETIC_REPRODUCIBLE)
    set(_hv_maps "")
    # The port's build directories are <buildtrees>/<port>/<triplet>-rel and
    # -dbg, its sources <buildtrees>/<port>/src/<ref>.
    get_filename_component(_hv_build_name "${CMAKE_BINARY_DIR}" NAME)
    if(DEFINED VCPKG_TARGET_TRIPLET AND _hv_build_name MATCHES "^${VCPKG_TARGET_TRIPLET}-(rel|dbg)$")
      get_filename_component(_hv_buildtrees "${CMAKE_BINARY_DIR}/../.." ABSOLUTE)
      list(APPEND _hv_maps "${_hv_buildtrees}=/vcpkg/buildtrees")
    endif()
    list(APPEND _hv_maps "${_VCPKG_INSTALLED_DIR}=/vcpkg/installed")
    foreach(_hv_map IN LISTS _hv_maps)
      if(_hl_msvc)
        set(_hv_flag "/pathmap:${_hv_map}")
      elseif(_hl_windows)
        set(_hv_flag "/clang:-ffile-prefix-map=${_hv_map}")
      else()
        set(_hv_flag "-ffile-prefix-map=${_hv_map}")
      endif()
      foreach(_hv_lang C CXX ASM OBJC OBJCXX)
        hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT "${_hv_flag}")
      endforeach()
    endforeach()
  endif()

  foreach(_hv_lang C CXX)
    hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_INIT ${VCPKG_${_hv_lang}_FLAGS})
    foreach(_hv_config DEBUG RELEASE)
      hermetic_append_flags(CMAKE_${_hv_lang}_FLAGS_${_hv_config}_INIT ${VCPKG_${_hv_lang}_FLAGS_${_hv_config}})
    endforeach()
  endforeach()
  foreach(_hv_kind EXE SHARED MODULE)
    hermetic_append_flags(CMAKE_${_hv_kind}_LINKER_FLAGS_INIT ${VCPKG_LINKER_FLAGS})
    foreach(_hv_config DEBUG RELEASE)
      hermetic_append_flags(CMAKE_${_hv_kind}_LINKER_FLAGS_${_hv_config}_INIT ${VCPKG_LINKER_FLAGS_${_hv_config}})
    endforeach()
  endforeach()
endmacro()
