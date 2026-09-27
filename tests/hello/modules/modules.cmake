# The C++ modules sample (HERMETIC_TESTS_CXX_MODULES, the *-modules presets):
# import std through the metadata the toolchain names
# (CMAKE_CXX_STDLIB_MODULES_JSON), {fmt} built as a named module that imports
# std itself, a module of the sample's own importing both, and a program.
if(NOT CMAKE_CXX_COMPILER_IMPORT_STD)
  message(FATAL_ERROR "import std is not available: ${CMAKE_CXX_COMPILER_IMPORT_STD_ERROR_MESSAGE}")
endif()
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)
# Sources that import modules without being in a CXX_MODULES file set are
# only scanned by default under policy CMP0155 (CMake 3.28), newer than the
# sample's minimum.
set(CMAKE_CXX_SCAN_FOR_MODULES ON)

include(FetchContent)
FetchContent_Declare(fmt
  URL https://github.com/fmtlib/fmt/releases/download/12.2.0/fmt-12.2.0.zip
  URL_HASH SHA256=a2f4a8d51178f954e4c339007f77edd76ba0cb2e36f87a48e5a5403d9be5878f
  EXCLUDE_FROM_ALL)
set(FMT_MODULE ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(fmt)
target_compile_definitions(fmt-module PRIVATE FMT_IMPORT_STD)

add_library(greet STATIC)
target_sources(greet PUBLIC FILE_SET CXX_MODULES FILES modules/greet.cppm)
target_link_libraries(greet PUBLIC fmt-module)

add_executable(hello_modules modules/main.cpp)
target_link_libraries(hello_modules PRIVATE greet)
add_test(NAME hello_modules COMMAND hello_modules)
set_tests_properties(hello_modules PROPERTIES PASS_REGULAR_EXPRESSION "OK")
