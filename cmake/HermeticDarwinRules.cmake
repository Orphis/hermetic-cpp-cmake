# Copyright 2026 The hermetic-cpp-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# CMAKE_USER_MAKE_RULES_OVERRIDE for macOS targets: loaded after CMake's
# platform rules.
#
# CMake before 4.1 derived the runtime path flag from the host's macOS
# version and left it empty when targeting macOS from another OS, which
# silently gave shared libraries their build directory as install name
# instead of @rpath (and executables no rpath at all). The generic platform
# setup resets the variable after the toolchain file runs, so it is set here.
if(NOT CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG)
  set(CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG "-Wl,-rpath,")
endif()

# On a Windows host, CMake's Ninja generator converts the install name
# directory for the Windows shell, so a shared library would be linked as
# "@rpath\name.dylib" and never found at run time; the rules use the
# default that directory stands for.
if(CMAKE_HOST_WIN32)
  foreach(lang C CXX OBJC OBJCXX)
    string(REPLACE "<TARGET_INSTALLNAME_DIR>" "@rpath/"
      CMAKE_${lang}_CREATE_SHARED_LIBRARY "${CMAKE_${lang}_CREATE_SHARED_LIBRARY}")
  endforeach()
endif()
