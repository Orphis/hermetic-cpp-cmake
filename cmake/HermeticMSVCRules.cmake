# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# CMAKE_USER_MAKE_RULES_OVERRIDE for Windows targets built with cl.exe
# (HERMETIC_COMPILER=msvc): loaded after CMake's MSVC platform rules.
#
# The link rules are CMake's, with lld-link named as HERMETIC_MSVC_LINKER:
# through the build directory's link to the cache when reproducible, so
# that the path the PDB records for the linker is relative. Static
# libraries use CMake's lib.exe rule with CMAKE_AR pointing at llvm-lib.
if(HERMETIC_MSVC_LINKER)
  set(_hl_linker "${HERMETIC_MSVC_LINKER}")
else()
  set(_hl_linker "<CMAKE_LINKER>")
endif()
foreach(lang C CXX)
  set(CMAKE_${lang}_LINK_EXECUTABLE
    "${_hl_linker} /nologo <OBJECTS> /out:<TARGET> /implib:<TARGET_IMPLIB> /pdb:<TARGET_PDB> /version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR> <CMAKE_${lang}_LINK_FLAGS> <LINK_FLAGS> <LINK_LIBRARIES>")
  set(CMAKE_${lang}_CREATE_SHARED_LIBRARY
    "${_hl_linker} /nologo <OBJECTS> /out:<TARGET> /implib:<TARGET_IMPLIB> /pdb:<TARGET_PDB> /dll /version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR> <LINK_FLAGS> <LINK_LIBRARIES>")
  set(CMAKE_${lang}_CREATE_SHARED_MODULE "${CMAKE_${lang}_CREATE_SHARED_LIBRARY}")
  # Debug info in the objects (/Z7), for projects on policy CMP0141 OLD, where
  # CMAKE_MSVC_DEBUG_INFORMATION_FORMAT does not apply.
  foreach(config DEBUG RELWITHDEBINFO)
    string(REPLACE "/Zi" "/Z7" CMAKE_${lang}_FLAGS_${config}_INIT "${CMAKE_${lang}_FLAGS_${config}_INIT}")
  endforeach()
endforeach()
unset(_hl_linker)
