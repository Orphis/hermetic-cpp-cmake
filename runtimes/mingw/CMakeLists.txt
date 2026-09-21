# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# mingw-w64 for a Windows (GNU ABI) target, built with the bootstrap
# toolchain like hermetic-llvm's runtimes/mingw: the headers, the CRT
# libraries and start files of mingw-w64-crt, winpthreads, and the import
# libraries of the system DLLs generated from mingw-w64's .def files with
# llvm-dlltool. UCRT is the C runtime (libmsvcrt.a is libucrt.a, as
# mingw-w64 arranges it with --with-default-msvcrt=ucrt). mingw-w64's own
# build is autotools, which Windows hosts have no shell for; the source
# lists (sources.cmake) follow mingw-w64-crt/Makefile.am.
#
#   MINGW_SOURCE_DIR   mingw-w64 source tree
#   MINGW_ARCH         x86_64 or aarch64
#   MINGW_TRIPLE       e.g. x86_64-w64-windows-gnu
#   MINGW_LLVM_BIN     the compiler's bin directory (llvm-dlltool, llvm-ar)
#
# Installs into <prefix>/include and <prefix>/lib (the <arch>-w64-mingw32
# directory clang looks for under a sysroot).
cmake_minimum_required(VERSION 3.19)
project(mingw_w64 C ASM)
include("${CMAKE_CURRENT_LIST_DIR}/sources.cmake")

set(crt "${MINGW_SOURCE_DIR}/mingw-w64-crt")
set(hdr "${MINGW_SOURCE_DIR}/mingw-w64-headers")
set(wpt "${MINGW_SOURCE_DIR}/mingw-w64-libraries/winpthreads")
set(gen "${CMAKE_BINARY_DIR}/generated")
set(exe "")
if(CMAKE_HOST_WIN32)
  set(exe ".exe")
endif()
set(dlltool "${MINGW_LLVM_BIN}/llvm-dlltool${exe}")
set(ar "${MINGW_LLVM_BIN}/llvm-ar${exe}")
if(MINGW_ARCH STREQUAL "x86_64")
  set(machine "i386:x86-64")
  set(arch_macro __x86_64__)
  set(def_dirs "${crt}/lib-common" "${crt}/lib64")
elseif(MINGW_ARCH STREQUAL "aarch64")
  set(machine arm64)
  set(arch_macro __aarch64__)
  # The arm64 definitions are generated from the templated lib-common ones.
  set(def_dirs "${crt}/lib-common")
else()
  message(FATAL_ERROR "MINGW_ARCH must be x86_64 or aarch64, not '${MINGW_ARCH}'")
endif()

# ---- Headers ------------------------------------------------------------------------
# _mingw.h: UCRT (0xE00) and Windows 10 (0xa00) as the defaults, like
# hermetic-llvm.
set(DEFAULT_WIN32_WINNT 0xa00)
set(DEFAULT_MSVCRT_VERSION 0xE00)
configure_file("${hdr}/crt/_mingw.h.in" "${gen}/crt/_mingw.h" @ONLY)
install(DIRECTORY "${hdr}/include/" DESTINATION include
  PATTERN "*.in" EXCLUDE PATTERN "*.idl" EXCLUDE PATTERN "Makefile*" EXCLUDE PATTERN "ChangeLog*" EXCLUDE)
install(DIRECTORY "${hdr}/crt/" DESTINATION include PATTERN "*.in" EXCLUDE PATTERN "Makefile*" EXCLUDE)
install(FILES "${gen}/crt/_mingw.h" DESTINATION include)
install(DIRECTORY "${wpt}/include/" DESTINATION include FILES_MATCHING PATTERN "*.h")

# Include order as mingw-w64's own build: winpthreads first, then the
# headers and the CRT headers (plus the generated _mingw.h).
set(sys_includes "${wpt}/include" "${hdr}/include" "${hdr}/crt" "${gen}/crt")

# ---- CRT libraries ----------------------------------------------------------------
# mingw-w64-crt/Makefile.am's AM_CFLAGS and its per-library additions.
set(crt_defs _CRTBLD _WIN32_WINNT=0x0f00 __MSVCRT_VERSION__=0x600 __USE_MINGW_ANSI_STDIO=0)
set(crt_cflags -fno-builtin -std=gnu99 -Wno-typedef-redefinition -Wno-pragma-pack -Wno-missing-declarations)

function(mingw_paths OUT)
  set(paths "")
  foreach(f IN LISTS ARGN)
    list(APPEND paths "${crt}/${f}")
  endforeach()
  set(${OUT} "${paths}" PARENT_SCOPE)
endfunction()

# A CRT library or object set from mingw-w64-crt sources.
function(mingw_crt_library NAME KIND)
  cmake_parse_arguments(A "" "" "SOURCES;DEFINES;OPTIONS" ${ARGN})
  mingw_paths(sources ${A_SOURCES})
  add_library(${NAME} ${KIND} ${sources})
  target_include_directories(${NAME} PRIVATE "${crt}/include" "${crt}/crt")
  target_include_directories(${NAME} SYSTEM PRIVATE ${sys_includes})
  target_compile_definitions(${NAME} PRIVATE ${crt_defs} ${A_DEFINES})
  foreach(flag IN LISTS crt_cflags A_OPTIONS)
    target_compile_options(${NAME} PRIVATE "$<$<COMPILE_LANGUAGE:C>:${flag}>")
  endforeach()
  set_target_properties(${NAME} PROPERTIES PREFIX "lib" SUFFIX ".a")
endfunction()

set(mingw32_srcs ${MINGW_MINGW32_SRCS})
set(mingwex_srcs ${MINGW_MINGWEX_SRCS})
set(ucrt_srcs ${MINGW_UCRT_BASE_SRCS})
if(MINGW_ARCH STREQUAL "x86_64")
  list(APPEND mingw32_srcs ${MINGW_MINGW32_X86_EXTRA_SRCS})
  list(APPEND mingwex_srcs ${MINGW_MINGWEX_X86_SRCS})
  list(APPEND ucrt_srcs ${MINGW_UCRT_BASE_X86_64_ADDITIONAL_SRCS})
else()
  list(APPEND mingwex_srcs ${MINGW_MINGWEX_ARM64_SRCS})
endif()
mingw_crt_library(mingw32 STATIC SOURCES ${mingw32_srcs})
mingw_crt_library(mingwex STATIC SOURCES ${mingwex_srcs} OPTIONS -Wno-attribute-warning)
mingw_crt_library(uuid STATIC SOURCES ${MINGW_UUID_SRCS})
mingw_crt_library(ucrt_extra OBJECT SOURCES ${ucrt_srcs} DEFINES __LIBMSVCRT__)
mingw_crt_library(ws2_32_extra OBJECT SOURCES ${MINGW_WS2_32_SRCS})
mingw_crt_library(kernel32_extra OBJECT SOURCES intrincs/RtlSecureZeroMemory.c)
# libmoldname and libm: empty, as in hermetic-llvm (the driver links both;
# the old names live in the UCRT headers as inline forwarders).
file(WRITE "${gen}/empty.c" "static int __attribute__((unused)) __mingw_libm_dummy;\n")
add_library(moldname STATIC "${gen}/empty.c")
add_library(m STATIC "${gen}/empty.c")
set_target_properties(moldname m PROPERTIES PREFIX "lib" SUFFIX ".a")
install(TARGETS mingw32 mingwex uuid moldname m ARCHIVE DESTINATION lib)

# Start files, compiled as system CRT objects.
foreach(obj crt2=crt/crtexe.c crt2u=crt/ucrtexe.c dllcrt2=crt/crtdll.c crtbegin=crt/crtbegin.c crtend=crt/crtend.c CRT_fp8=crt/CRT_fp8.c)
  string(REGEX MATCH "^([^=]+)=(.*)$" _ "${obj}")
  set(name "${CMAKE_MATCH_1}")
  mingw_crt_library(obj_${name} OBJECT SOURCES "${CMAKE_MATCH_2}" DEFINES _SYSCRT=1)
  install(FILES $<TARGET_OBJECTS:obj_${name}> DESTINATION lib RENAME "${name}.o")
endforeach()

# winpthreads, static (WINPTHREAD_API stays empty in its headers).
file(GLOB winpthread_srcs "${wpt}/src/*.c")
add_library(winpthread STATIC ${winpthread_srcs})
target_include_directories(winpthread PRIVATE "${wpt}/src")
target_include_directories(winpthread SYSTEM PRIVATE ${sys_includes})
target_compile_definitions(winpthread PRIVATE _WIN32_WINNT=0x0f00 __USE_MINGW_ANSI_STDIO=0 IN_WINPTHREAD)
target_compile_options(winpthread PRIVATE -std=gnu99)
set_target_properties(winpthread PROPERTIES PREFIX "lib" SUFFIX ".a")
install(TARGETS winpthread ARCHIVE DESTINATION lib)
install(FILES $<TARGET_FILE:winpthread> DESTINATION lib RENAME libpthread.a)

# ---- Import libraries ---------------------------------------------------------------
# One per .def; the templated .def.in files are preprocessed with clang
# first (their @N stdcall decorations, meaningful on i386 only, become
# comments, as in hermetic-llvm). A few archives get extra objects merged in
# the way mingw-w64's .mri scripts do (llvm-ar L adds an archive's members).
set(lib_dir "${CMAKE_BINARY_DIR}/lib")
set(import_dir "${gen}/import")
file(MAKE_DIRECTORY "${lib_dir}" "${import_dir}" "${gen}/defs")
set(merged ucrtbase ucrtbased ws2_32 kernel32)
set(installed_libs "")
set(all_outputs "")
file(GLOB def_includes "${crt}/def-include/*")
foreach(dir IN LISTS def_dirs)
  file(GLOB defs "${dir}/*.def")
  file(GLOB def_ins "${dir}/*.def.in")
  set(inputs "")
  foreach(def IN LISTS defs)
    get_filename_component(name "${def}" NAME)
    string(REGEX REPLACE "\\.def$" "" name "${name}")
    list(APPEND inputs "${name}=${def}")
  endforeach()
  foreach(def_in IN LISTS def_ins)
    get_filename_component(name "${def_in}" NAME)
    string(REGEX REPLACE "\\.def\\.in$" "" name "${name}")
    if(name MATCHES "-common$")
      continue()
    endif()
    file(READ "${def_in}" content)
    string(REPLACE "@" ";" content "${content}")
    file(WRITE "${gen}/defs/${name}.def.in" "${content}")
    set(def "${gen}/defs/${name}.def")
    add_custom_command(OUTPUT "${def}"
      COMMAND "${CMAKE_C_COMPILER}" --target=${MINGW_TRIPLE} -E -P -xc "-D${arch_macro}=1"
        -I "${crt}/def-include" -I "${dir}" -Wno-invalid-pp-token -o "${def}" "${gen}/defs/${name}.def.in"
      DEPENDS "${def_in}" ${def_ins} ${def_includes} VERBATIM)
    list(APPEND inputs "${name}=${def}")
  endforeach()
  foreach(entry IN LISTS inputs)
    string(REGEX MATCH "^([^=]+)=(.*)$" _ "${entry}")
    set(name "${CMAKE_MATCH_1}")
    set(def "${CMAKE_MATCH_2}")
    if(name IN_LIST merged)
      set(out "${import_dir}/lib${name}.a")
    elseif(name STREQUAL "msvcrt")
      # msvcrt.dll's own import library; libmsvcrt.a is the UCRT (below).
      set(out "${lib_dir}/libmsvcrt-os.a")
      list(APPEND installed_libs "${out}")
    else()
      set(out "${lib_dir}/lib${name}.a")
      list(APPEND installed_libs "${out}")
    endif()
    add_custom_command(OUTPUT "${out}"
      COMMAND "${dlltool}" -m ${machine} -d "${def}" -l "${out}" DEPENDS "${def}" VERBATIM)
    list(APPEND all_outputs "${out}")
  endforeach()
endforeach()

# ucrtbase / ucrtbased: the DLL's import library plus the UCRT extras.
foreach(name ucrtbase ucrtbased)
  add_custom_command(OUTPUT "${lib_dir}/lib${name}.a"
    COMMAND "${ar}" qcsDL "${lib_dir}/lib${name}.a" "${import_dir}/lib${name}.a" $<TARGET_OBJECTS:ucrt_extra>
    DEPENDS "${import_dir}/lib${name}.a" ucrt_extra $<TARGET_OBJECTS:ucrt_extra> VERBATIM COMMAND_EXPAND_LISTS)
  list(APPEND installed_libs "${lib_dir}/lib${name}.a")
endforeach()
# ucrt: the api-ms-win-crt-* forwarders plus the extras (lib-common/ucrt.mri);
# msvcrt: what the driver links by default, the UCRT here.
set(ucrt_parts "")
foreach(part conio convert environment filesystem heap locale math multibyte private process runtime stdio string time utility)
  list(APPEND ucrt_parts "${lib_dir}/libapi-ms-win-crt-${part}-l1-1-0.a")
endforeach()
add_custom_command(OUTPUT "${lib_dir}/libucrt.a"
  COMMAND "${ar}" qcsDL "${lib_dir}/libucrt.a" ${ucrt_parts} $<TARGET_OBJECTS:ucrt_extra>
  DEPENDS ${ucrt_parts} ucrt_extra $<TARGET_OBJECTS:ucrt_extra> VERBATIM COMMAND_EXPAND_LISTS)
add_custom_command(OUTPUT "${lib_dir}/libmsvcrt.a"
  COMMAND "${CMAKE_COMMAND}" -E copy "${lib_dir}/libucrt.a" "${lib_dir}/libmsvcrt.a"
  DEPENDS "${lib_dir}/libucrt.a" VERBATIM)
add_custom_command(OUTPUT "${lib_dir}/libkernel32.a"
  COMMAND "${ar}" qcsDL "${lib_dir}/libkernel32.a" "${import_dir}/libkernel32.a" $<TARGET_OBJECTS:kernel32_extra>
  DEPENDS "${import_dir}/libkernel32.a" kernel32_extra $<TARGET_OBJECTS:kernel32_extra> VERBATIM COMMAND_EXPAND_LISTS)
add_custom_command(OUTPUT "${lib_dir}/libws2_32.a"
  COMMAND "${ar}" qcsDL "${lib_dir}/libws2_32.a" "${import_dir}/libws2_32.a" $<TARGET_OBJECTS:ws2_32_extra>
  DEPENDS "${import_dir}/libws2_32.a" ws2_32_extra $<TARGET_OBJECTS:ws2_32_extra> VERBATIM COMMAND_EXPAND_LISTS)
add_custom_command(OUTPUT "${lib_dir}/libsynchronization.a"
  COMMAND "${CMAKE_COMMAND}" -E copy "${lib_dir}/libapi-ms-win-core-synch-l1-2-0.a" "${lib_dir}/libsynchronization.a"
  DEPENDS "${lib_dir}/libapi-ms-win-core-synch-l1-2-0.a" VERBATIM)
list(APPEND installed_libs "${lib_dir}/libucrt.a" "${lib_dir}/libmsvcrt.a" "${lib_dir}/libkernel32.a"
  "${lib_dir}/libws2_32.a" "${lib_dir}/libsynchronization.a")
add_custom_target(import_libraries ALL DEPENDS ${all_outputs} ${installed_libs})
install(FILES ${installed_libs} DESTINATION lib)
