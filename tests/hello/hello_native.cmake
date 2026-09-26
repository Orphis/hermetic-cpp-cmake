# The sample for targets with a libc: a static library, a shared library
# (where the target has them) and executables using both.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

add_library(greeter_static STATIC greeter.cpp)
target_compile_definitions(greeter_static PUBLIC GREETER_STATIC)
target_include_directories(greeter_static PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(hello_c hello.c)
add_executable(hello_cxx hello.cpp)
target_link_libraries(hello_cxx PRIVATE greeter_static Threads::Threads)
if(WIN32)
  enable_language(RC)
  target_sources(hello_c PRIVATE hello.rc)
endif()

# HERMETIC_MALLOC: the programs check where their blocks come from, unless a
# sanitizer brings its own allocator (the shim stands aside then).
if(HERMETIC_MALLOC_BACKEND AND NOT CMAKE_C_FLAGS MATCHES "fsanitize=[^ ]*(address|thread|memory)")
  add_compile_definitions(HELLO_MALLOC)
endif()

enable_testing()
add_test(NAME hello_c COMMAND hello_c)
add_test(NAME hello_cxx COMMAND hello_cxx)
set_tests_properties(hello_c hello_cxx PROPERTIES PASS_REGULAR_EXPRESSION "OK")

# musl targets are fully static (like hermetic-llvm), so no shared libraries.
if(NOT HERMETIC_EFFECTIVE_LIBC STREQUAL "musl")
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

# Windows hosts get the SDK tools; make sure the exported directory is real.
if(HERMETIC_WINDOWS_SDK_TOOLS_DIR)
  foreach(tool mt.exe rc.exe midl.exe mc.exe signtool.exe)
    if(NOT EXISTS "${HERMETIC_WINDOWS_SDK_TOOLS_DIR}/${tool}")
      message(FATAL_ERROR "SDK tool ${tool} missing from ${HERMETIC_WINDOWS_SDK_TOOLS_DIR}")
    endif()
  endforeach()
  message(STATUS "hermetic-llvm: Windows SDK tools at ${HERMETIC_WINDOWS_SDK_TOOLS_DIR}")
elseif(CMAKE_HOST_WIN32 AND WIN32 AND HERMETIC_EFFECTIVE_WINDOWS_ABI STREQUAL "msvc")
  message(FATAL_ERROR "HERMETIC_WINDOWS_SDK_TOOLS_DIR should be set on a Windows host")
endif()

# Windows ASan is a DLL runtime that must sit next to the executables.
if(WIN32 AND HERMETIC_LLVM_RUNTIME_SET AND CMAKE_CXX_FLAGS MATCHES "fsanitize=address")
  file(GLOB _asan_dll "${HERMETIC_LLVM_RUNTIME_SET}/resource/lib/windows/clang_rt.asan_dynamic-*.dll")
  file(COPY ${_asan_dll} DESTINATION "${CMAKE_BINARY_DIR}")
endif()

