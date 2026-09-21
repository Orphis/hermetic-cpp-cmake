# Copyright 2026 The hermetic-llvm-cmake Authors.
# SPDX-License-Identifier: Apache-2.0
#
# CMAKE_USER_MAKE_RULES_OVERRIDE for WebAssembly targets: loaded after
# CMake's platform rules. Executables are WebAssembly modules, named *.wasm
# (the generic platform setup resets the suffix after the toolchain file).
set(CMAKE_EXECUTABLE_SUFFIX ".wasm")
