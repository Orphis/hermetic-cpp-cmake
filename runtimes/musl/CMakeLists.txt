# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Builds musl libc with the hermetic Clang, following musl's Makefile and the
# recipe of hermeticbuild/hermetic-llvm (runtimes/musl, 3rd_party/libc/musl).
#
#   -DMUSL_SOURCE_DIR=<extracted musl-1.2.x>  -DMUSL_ARCH=<x86_64|aarch64|riscv64|s390x|arm>
#   -DCMAKE_INSTALL_PREFIX=<runtime set root>
#
# Installs headers to <prefix>/usr/include and libc.a, libc.so, crt objects
# and the empty companion archives (libm.a, libpthread.a, ...) to <prefix>/usr/lib.
# Must be configured with runtimes/bootstrap.toolchain.cmake and a resource
# directory that already contains compiler-rt builtins (libc.so needs them).

cmake_minimum_required(VERSION 3.19)
project(hermetic_llvm_musl C ASM)

set(MUSL_SOURCE_DIR "" CACHE PATH "musl source tree")
set(MUSL_ARCH "" CACHE STRING "musl architecture name")
if(NOT IS_DIRECTORY "${MUSL_SOURCE_DIR}/src" OR NOT MUSL_ARCH)
  message(FATAL_ERROR "MUSL_SOURCE_DIR and MUSL_ARCH are required")
endif()
file(READ "${MUSL_SOURCE_DIR}/VERSION" MUSL_VERSION)
string(STRIP "${MUSL_VERSION}" MUSL_VERSION)
set(gen "${CMAKE_BINARY_DIR}/obj")

# ---- Generated headers -------------------------------------------------------
# obj/include/bits/alltypes.h: port of tools/mkalltypes.sed.
function(musl_alltypes OUT)
  set(result "")
  foreach(input "${MUSL_SOURCE_DIR}/arch/${MUSL_ARCH}/bits/alltypes.h.in" "${MUSL_SOURCE_DIR}/include/alltypes.h.in")
    file(STRINGS "${input}" lines)
    foreach(line IN LISTS lines)
      if(line MATCHES "^TYPEDEF (.*) ([^ ]*);$")
        set(decl "${CMAKE_MATCH_1}")
        set(name "${CMAKE_MATCH_2}")
        string(APPEND result "#if defined(__NEED_${name}) && !defined(__DEFINED_${name})\ntypedef ${decl} ${name};\n#define __DEFINED_${name}\n#endif\n\n")
      elseif(line MATCHES "^STRUCT *([^ ]*) (.*);$")
        set(name "${CMAKE_MATCH_1}")
        set(body "${CMAKE_MATCH_2}")
        string(APPEND result "#if defined(__NEED_struct_${name}) && !defined(__DEFINED_struct_${name})\nstruct ${name} ${body};\n#define __DEFINED_struct_${name}\n#endif\n\n")
      elseif(line MATCHES "^UNION *([^ ]*) (.*);$")
        set(name "${CMAKE_MATCH_1}")
        set(body "${CMAKE_MATCH_2}")
        string(APPEND result "#if defined(__NEED_union_${name}) && !defined(__DEFINED_union_${name})\nunion ${name} ${body};\n#define __DEFINED_union_${name}\n#endif\n\n")
      else()
        string(APPEND result "${line}\n")
      endif()
    endforeach()
  endforeach()
  file(WRITE "${OUT}" "${result}")
endfunction()
musl_alltypes("${gen}/include/bits/alltypes.h")

# obj/include/bits/syscall.h: the .in file followed by its __NR_ lines as SYS_.
file(READ "${MUSL_SOURCE_DIR}/arch/${MUSL_ARCH}/bits/syscall.h.in" syscall_in)
file(STRINGS "${MUSL_SOURCE_DIR}/arch/${MUSL_ARCH}/bits/syscall.h.in" syscall_lines REGEX "__NR_")
set(syscall_aliases "")
foreach(line IN LISTS syscall_lines)
  string(REPLACE "__NR_" "SYS_" line "${line}")
  string(APPEND syscall_aliases "${line}\n")
endforeach()
file(WRITE "${gen}/include/bits/syscall.h" "${syscall_in}${syscall_aliases}")
file(WRITE "${gen}/src/internal/version.h" "#define VERSION \"${MUSL_VERSION}\"\n")

# ---- Sources ---------------------------------------------------------------
# Base sources, with arch-specific files replacing their generic counterpart.
set(src_dirs "")
file(GLOB subdirs LIST_DIRECTORIES true "${MUSL_SOURCE_DIR}/src/*")
foreach(d IN LISTS subdirs)
  if(IS_DIRECTORY "${d}")
    list(APPEND src_dirs "${d}")
  endif()
endforeach()
list(APPEND src_dirs "${MUSL_SOURCE_DIR}/src/malloc/mallocng" "${MUSL_SOURCE_DIR}/crt" "${MUSL_SOURCE_DIR}/ldso")

set(all_sources "")
foreach(d IN LISTS src_dirs)
  file(GLOB base "${d}/*.c")
  file(GLOB arch "${d}/${MUSL_ARCH}/*.c" "${d}/${MUSL_ARCH}/*.s" "${d}/${MUSL_ARCH}/*.S")
  set(replaced "")
  foreach(a IN LISTS arch)
    get_filename_component(stem "${a}" NAME_WE)
    list(APPEND replaced "${d}/${stem}.c")
  endforeach()
  foreach(b IN LISTS base)
    if(NOT b IN_LIST replaced)
      list(APPEND all_sources "${b}")
    endif()
  endforeach()
  list(APPEND all_sources ${arch})
endforeach()

set(libc_sources "")
set(crt_sources "")
set(ldso_sources "")
foreach(s IN LISTS all_sources)
  # Only the top-level crt/ and ldso/ directories are special; src/ldso/ is
  # part of libc (dladdr, dl_iterate_phdr, ...).
  if(s MATCHES "^${MUSL_SOURCE_DIR}/crt/")
    list(APPEND crt_sources "${s}")
  elseif(s MATCHES "^${MUSL_SOURCE_DIR}/ldso/")
    list(APPEND ldso_sources "${s}")
  else()
    list(APPEND libc_sources "${s}")
  endif()
endforeach()

set(musl_includes
  "${MUSL_SOURCE_DIR}/arch/${MUSL_ARCH}"
  "${MUSL_SOURCE_DIR}/arch/generic"
  "${gen}/src/internal"
  "${MUSL_SOURCE_DIR}/src/include"
  "${MUSL_SOURCE_DIR}/src/internal"
  "${gen}/include"
  "${MUSL_SOURCE_DIR}/include")

# From musl's configure for clang, and hermetic-llvm's CFLAGS_ALL.
set(musl_cflags
  -std=c99 -nostdinc -ffreestanding -fexcess-precision=standard -frounding-math
  -fno-strict-aliasing -Wa,--noexecstack -D_XOPEN_SOURCE=700
  -O2 -fno-align-functions -fomit-frame-pointer -fno-unwind-tables
  -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections
  -fno-stack-protector -w -Qunused-arguments)
# Overrides any -O from CMAKE_BUILD_TYPE.
set(CMAKE_C_FLAGS_RELEASE "")
set(CMAKE_C_FLAGS_MINSIZEREL "")
set(CMAKE_C_FLAGS_RELWITHDEBINFO "")
set(CMAKE_C_FLAGS_DEBUG "")
set(CMAKE_ASM_FLAGS_RELEASE "")

# Assemble .s files with the C driver (no preprocessing needed).
set_source_files_properties(${all_sources} PROPERTIES LANGUAGE C)

# libc objects, compiled once with -fPIC and used for both libc.a and libc.so.
add_library(musl_objs OBJECT ${libc_sources})
target_include_directories(musl_objs PRIVATE ${musl_includes})
target_compile_options(musl_objs PRIVATE ${musl_cflags} -fPIC)

add_library(c STATIC $<TARGET_OBJECTS:musl_objs>)
set_target_properties(c PROPERTIES OUTPUT_NAME c PREFIX lib SUFFIX .a)

add_library(ldso_objs OBJECT ${ldso_sources})
target_include_directories(ldso_objs PRIVATE ${musl_includes})
target_compile_options(ldso_objs PRIVATE ${musl_cflags} -fPIC)

# libc.so (also the dynamic loader, entry point _dlstart). Off by default:
# like hermetic-llvm, musl targets are linked statically; the shared library
# additionally needs compiler-rt builtins in the resource directory.
option(MUSL_BUILD_SHARED "Build libc.so" OFF)
if(MUSL_BUILD_SHARED)
  add_library(c_shared SHARED $<TARGET_OBJECTS:musl_objs> $<TARGET_OBJECTS:ldso_objs>)
  set_target_properties(c_shared PROPERTIES OUTPUT_NAME c PREFIX lib SUFFIX .so NO_SONAME ON)
  target_link_options(c_shared PRIVATE -nostdlib -rtlib=compiler-rt -Wl,-e,_dlstart -Wl,-z,now -Wl,-soname,libc.so -Wl,--gc-sections)
  install(TARGETS c_shared LIBRARY DESTINATION usr/lib)
  set(loader "ld-musl-${MUSL_ARCH}.so.1")
  if(MUSL_ARCH STREQUAL "arm")
    set(loader "ld-musl-armhf.so.1")
  endif()
  install(CODE "file(CREATE_LINK libc.so \"\${CMAKE_INSTALL_PREFIX}/usr/lib/${loader}\" SYMBOLIC)")
endif()

# crt objects: crt1.o, Scrt1.o (-pie), rcrt1.o (-static-pie), crti.o, crtn.o.
set(crt_objects "")
foreach(src IN LISTS crt_sources)
  get_filename_component(stem "${src}" NAME_WE)
  add_library(crt_${stem} OBJECT "${src}")
  target_include_directories(crt_${stem} PRIVATE ${musl_includes})
  target_compile_options(crt_${stem} PRIVATE ${musl_cflags} -DCRT -fno-addrsig)
  if(stem MATCHES "^(Scrt1|rcrt1)$")
    target_compile_options(crt_${stem} PRIVATE -fPIC)
  endif()
  add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/lib/${stem}.o"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/lib"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_OBJECTS:crt_${stem}>" "${CMAKE_BINARY_DIR}/lib/${stem}.o"
    DEPENDS crt_${stem} COMMAND_EXPAND_LISTS)
  list(APPEND crt_objects "${CMAKE_BINARY_DIR}/lib/${stem}.o")
endforeach()

# Empty companion archives so -lm, -lpthread, ... resolve.
set(empty_libs "")
foreach(lib m rt pthread crypt util xnet resolv dl)
  add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/lib/lib${lib}.a"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/lib"
    COMMAND ${CMAKE_COMMAND} -E rm -f "${CMAKE_BINARY_DIR}/lib/lib${lib}.a"
    COMMAND "${CMAKE_AR}" rc "${CMAKE_BINARY_DIR}/lib/lib${lib}.a")
  list(APPEND empty_libs "${CMAKE_BINARY_DIR}/lib/lib${lib}.a")
endforeach()
add_custom_target(musl_extra ALL DEPENDS ${crt_objects} ${empty_libs})

# ---- Install ------------------------------------------------------------------
install(TARGETS c ARCHIVE DESTINATION usr/lib)
install(FILES ${crt_objects} ${empty_libs} DESTINATION usr/lib)
install(DIRECTORY "${MUSL_SOURCE_DIR}/include/" DESTINATION usr/include FILES_MATCHING PATTERN "*.h")
install(DIRECTORY "${MUSL_SOURCE_DIR}/arch/generic/bits/" DESTINATION usr/include/bits FILES_MATCHING PATTERN "*.h")
install(DIRECTORY "${MUSL_SOURCE_DIR}/arch/${MUSL_ARCH}/bits/" DESTINATION usr/include/bits FILES_MATCHING PATTERN "*.h")
install(FILES "${gen}/include/bits/alltypes.h" "${gen}/include/bits/syscall.h" DESTINATION usr/include/bits)
