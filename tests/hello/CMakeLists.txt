cmake_minimum_required(VERSION 3.19)
project(hermetic_llvm_hello C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

add_library(greeter_static STATIC greeter.cpp)
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
  add_library(greeter SHARED greeter.cpp)
  target_include_directories(greeter PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  add_executable(hello_shared hello.cpp)
  target_link_libraries(hello_shared PRIVATE greeter Threads::Threads)
  add_test(NAME hello_shared COMMAND hello_shared)
  set_tests_properties(hello_shared PROPERTIES PASS_REGULAR_EXPRESSION "OK")
endif()

message(STATUS "hermetic-llvm: root=${HERMETIC_LLVM_ROOT} triple=${HERMETIC_LLVM_TARGET_TRIPLE} libc=${HERMETIC_LLVM_EFFECTIVE_LIBC} sysroot=${HERMETIC_LLVM_SYSROOT_PATH} cross=${HERMETIC_LLVM_CROSSCOMPILING}")
