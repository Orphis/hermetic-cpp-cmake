cmake_minimum_required(VERSION 3.19)
project(hermetic_hello C CXX)

# No build-tree rpath: it would embed the absolute build directory, which
# differs per host and would defeat the cross-host reproducibility check.
set(CMAKE_SKIP_BUILD_RPATH ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Debug information with the source directory mapped to a fixed name, so
# that debug builds can take part in the cross-host identity check (the
# toolchain records the build directory as ".").
option(HERMETIC_TESTS_DEBUG_INFO "Build with debug info mapped to /src" OFF)
if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
  # Any link may write a PDB (sanitized links get /DEBUG from the driver);
  # /pdbsourcepath keeps the build directory out of it.
  add_link_options(/pdbsourcepath:/build)
endif()
if(HERMETIC_TESTS_DEBUG_INFO)
  # Tell the debugger settings the toolchain writes (hermetic-cpp.gdb,
  # hermetic-cpp.lldb in the build directory) about that map.
  if(COMMAND hermetic_debugger_source_map)
    hermetic_debugger_source_map(/src "${CMAKE_SOURCE_DIR}")
  endif()
  if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    add_compile_options(/Z7 "/clang:-ffile-prefix-map=${CMAKE_SOURCE_DIR}=/src")
    # A PDB per binary.
    add_link_options(/DEBUG)
  else()
    add_compile_options(-g "-ffile-prefix-map=${CMAKE_SOURCE_DIR}=/src")
    if(APPLE)
      # The linked binary references its object files (N_OSO) by absolute
      # path; strip the working directory (lld expands ".") from those.
      add_link_options("LINKER:-oso_prefix,.")
    endif()
  endif()
endif()

if(HERMETIC_TARGET MATCHES "^wasm")
  # Freestanding WebAssembly module: no libc, functions exported for the
  # host runtime (tests/run_artifacts.sh calls them under Node.js).
  add_executable(hello_wasm wasm_add.c wasm_mul.cpp)
else()
  include(hello_native.cmake)
endif()
# Consumed by tests/run_artifacts.sh to pick where a build's binaries can run
# (and, for macOS, to attribute differences to differing SDK versions), and
# by tests/stage_artifacts.sh to collect the runtime set's archives.
set(_sdk_version "")
if(APPLE AND EXISTS "${CMAKE_OSX_SYSROOT}/SDKSettings.json")
  file(READ "${CMAKE_OSX_SYSROOT}/SDKSettings.json" _sdk_settings)
  string(JSON _sdk_version ERROR_VARIABLE _ GET "${_sdk_settings}" "Version")
endif()
file(WRITE "${CMAKE_BINARY_DIR}/target.txt" "${HERMETIC_TARGET};${HERMETIC_EFFECTIVE_LIBC};${_sdk_version}\n")
file(WRITE "${CMAKE_BINARY_DIR}/runtime-set.txt" "${HERMETIC_LLVM_RUNTIME_SET}\n")

message(STATUS "hermetic-llvm: root=${HERMETIC_LLVM_ROOT} triple=${HERMETIC_TARGET_TRIPLE} libc=${HERMETIC_EFFECTIVE_LIBC} sysroot=${HERMETIC_SYSROOT_PATH} cross=${HERMETIC_CROSSCOMPILING}")
