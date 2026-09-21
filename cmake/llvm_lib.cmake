# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs llvm-lib, or the "lib" subcommand of the multicall llvm driver, with
# every backslash in its arguments replaced by a forward slash.
#
# lib.exe (and llvm-lib) stores each member under the path it was given.
# On Windows hosts CMake's generators spell object paths with backslashes,
# so the same static library built there would differ from the one built
# on Linux or macOS by its member names alone. Rewriting the arguments
# makes the archive identical on every host. Only Windows hosts run through
# this script; the others call the driver directly.
#
# Usage:
#   cmake -DLIB=<llvm-lib or llvm> [-DSUBCOMMAND=lib] -P llvm_lib.cmake -- <lib.exe arguments>
#
# "@file" arguments (CMake's response files for long object lists) are
# expanded, and the rewritten command is written back to a response file
# when it would exceed the Windows command-line limit.
cmake_minimum_required(VERSION 3.25)

if(NOT LIB)
  message(FATAL_ERROR "llvm_lib.cmake: LIB (path to llvm-lib or llvm) not set")
endif()
if(NOT DEFINED HERMETIC_LLVM_LIB_MAX_COMMAND)
  set(HERMETIC_LLVM_LIB_MAX_COMMAND 30000)
endif()

set(_args "")
set(_after_separator FALSE)
math(EXPR _last "${CMAKE_ARGC} - 1")
foreach(_i RANGE 0 ${_last})
  set(_arg "${CMAKE_ARGV${_i}}")
  if(NOT _after_separator)
    if(_arg STREQUAL "--")
      set(_after_separator TRUE)
    endif()
    continue()
  endif()
  if(_arg MATCHES "^@(.+)$")
    file(STRINGS "${CMAKE_MATCH_1}" _lines)
    foreach(_line IN LISTS _lines)
      separate_arguments(_line_args WINDOWS_COMMAND "${_line}")
      list(APPEND _args ${_line_args})
    endforeach()
  else()
    list(APPEND _args "${_arg}")
  endif()
endforeach()

set(_slashed "")
set(_length 0)
foreach(_arg IN LISTS _args)
  string(REPLACE "\\" "/" _arg "${_arg}")
  list(APPEND _slashed "${_arg}")
  string(LENGTH "${_arg}" _n)
  math(EXPR _length "${_length} + ${_n} + 3")
endforeach()

set(_rsp "")
if(_length GREATER HERMETIC_LLVM_LIB_MAX_COMMAND)
  set(_out "")
  set(_kept "")
  foreach(_arg IN LISTS _slashed)
    if(_arg MATCHES "^[/-]out:(.*)$")
      set(_out "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  if(NOT _out)
    message(FATAL_ERROR "llvm_lib.cmake: no /out: argument")
  endif()
  set(_rsp "${_out}.rsp")
  set(_content "")
  foreach(_arg IN LISTS _slashed)
    if(_arg MATCHES "[ \t\"]")
      string(REPLACE "\"" "\\\"" _arg "${_arg}")
      set(_arg "\"${_arg}\"")
    endif()
    string(APPEND _content "${_arg}\n")
  endforeach()
  file(WRITE "${_rsp}" "${_content}")
  set(_slashed "@${_rsp}")
endif()

execute_process(
  COMMAND "${LIB}" ${SUBCOMMAND} ${_slashed}
  RESULT_VARIABLE _result
  )
if(_rsp)
  file(REMOVE "${_rsp}")
endif()
if(NOT _result EQUAL 0)
  message(FATAL_ERROR "llvm_lib.cmake: ${LIB} ${SUBCOMMAND} failed: ${_result}")
endif()
