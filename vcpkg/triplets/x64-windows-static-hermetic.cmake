# Static libraries (static C runtime) built by hermetic-cpp-cmake; see ../hermetic-triplet.cmake.
set(HERMETIC_TARGET windows-x86_64)
set(VCPKG_CRT_LINKAGE static)
include("${CMAKE_CURRENT_LIST_DIR}/../hermetic-triplet.cmake")
