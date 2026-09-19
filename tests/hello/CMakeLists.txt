cmake_minimum_required(VERSION 3.19)
project(hermetic_llvm_hello C CXX)

# No build-tree rpath: it would embed the absolute build directory, which
# differs per host and would defeat the cross-host reproducibility check.
set(CMAKE_SKIP_BUILD_RPATH ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

add_library(greeter_static STATIC greeter.cpp)
target_compile_definitions(greeter_static PUBLIC GREETER_STATIC)
target_include_directories(greeter_static PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(hello_c hello.c)
add_executable(hello_cxx hello.cpp)
target_link_libraries(hello_cxx PRIVATE greeter_static Threads::Threads)

enable_testing()
add_test(NAME hello_c COMMAND hello_c)
add_test(NAME hello_cxx COMMAND hello_cxx)
set_tests_properties(hello_c hello_cxx PROPERTIES PASS_REGULAR_EXPRESSION "OK")

# musl targets are fully static (like hermetic-llvm), so no shared libraries.
if(NOT HERMETIC_LLVM_EFFECTIVE_LIBC STREQUAL "musl")
  # Exports are explicit (GREETER_BUILDING + greeter.h): WINDOWS_EXPORT_ALL_SYMBOLS
  # picks the exported set from the CMake version doing the build, which made
  # greeter.dll differ between hosts running different CMake releases.
  add_library(greeter SHARED greeter.cpp)
  target_compile_definitions(greeter PRIVATE GREETER_BUILDING)
  target_include_directories(greeter PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  add_executable(hello_shared hello.cpp)
  target_link_libraries(hello_shared PRIVATE greeter Threads::Threads)
  add_test(NAME hello_shared COMMAND hello_shared)
  # Without a build rpath the library is located through the environment.
  set_tests_properties(hello_shared PROPERTIES PASS_REGULAR_EXPRESSION "OK"
    ENVIRONMENT "LD_LIBRARY_PATH=${CMAKE_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_BINARY_DIR}")
endif()

# Consumed by tests/run_artifacts.sh to pick where a build's binaries can run.
file(WRITE "${CMAKE_BINARY_DIR}/target.txt" "${HERMETIC_LLVM_TARGET};${HERMETIC_LLVM_EFFECTIVE_LIBC}\n")

message(STATUS "hermetic-llvm: root=${HERMETIC_LLVM_ROOT} triple=${HERMETIC_LLVM_TARGET_TRIPLE} libc=${HERMETIC_LLVM_EFFECTIVE_LIBC} sysroot=${HERMETIC_LLVM_SYSROOT_PATH} cross=${HERMETIC_LLVM_CROSSCOMPILING}")
