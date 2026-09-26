#!/usr/bin/env bash
# Collects the test binaries of every built preset into
# artifacts/<host label>/<preset>/ for upload, next to target.txt.
#
#   tests/stage_artifacts.sh <host label> [preset...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label="$1"; shift
out="${here}/../artifacts/${label}"
rm -rf "${out}"
presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=($(cd "${here}/hello/build" && ls -d */ | tr -d /))
fi
for preset in "${presets[@]}"; do
  src="${here}/hello/build/${preset}"
  # Presets that did not build (or failed, see run_tests.sh) are left out,
  # so that the run stage still checks the others.
  [[ -f "${src}/target.txt" ]] || { echo "no build for preset ${preset}, skipping"; continue; }
  [[ -e "${src}/.failed" ]] && { echo "preset ${preset} failed to build, skipping"; continue; }
  mkdir -p "${out}/${preset}"
  cp "${src}/target.txt" "${out}/${preset}/"
  for f in hello_c hello_cxx hello_shared hello_modules hello_c.exe hello_cxx.exe hello_shared.exe hello_modules.exe libgreeter.so libgreeter.dylib greeter.dll libgreeter.dll hello_wasm.wasm \
      clang_rt.asan_dynamic-x86_64.dll clang_rt.asan_dynamic-aarch64.dll \
      hello_c.pdb hello_cxx.pdb hello_shared.pdb greeter.pdb libgreeter_static.a greeter_static.lib \
      mimalloc.dll mimalloc-redirect.dll mimalloc-redirect-arm64.dll; do
    [[ -e "${src}/${f}" ]] && cp "${src}/${f}" "${out}/${preset}/"
  done
  # The runtime set's archives, so the set itself is part of the identity check.
  set_dir=""; [[ -f "${src}/runtime-set.txt" ]] && set_dir="$(head -1 "${src}/runtime-set.txt" | tr -d '\r')"
  if [[ -n "${set_dir}" && -d "${set_dir}" ]]; then
    mkdir -p "${out}/${preset}/set"
    for f in "${set_dir}"/usr/lib/libc++.a "${set_dir}"/usr/lib/libc++abi.a "${set_dir}"/usr/lib/libunwind.a \
        "${set_dir}"/usr/lib/libc.a "${set_dir}"/usr/lib/libc_nonshared.a "${set_dir}"/usr/lib/libc.so.6 \
        "${set_dir}"/resource/lib/*/libclang_rt.builtins*.a "${set_dir}"/resource/lib/*/clang_rt.crt*.o \
        "${set_dir}"/resource/lib/*/libclang_rt.{asan,ubsan_standalone,fuzzer,profile}*.a \
        "${set_dir}"/lib/libc++-*.lib "${set_dir}"/resource/lib/windows/clang_rt.*.lib \
        "${set_dir}"/*-w64-mingw32/lib/libc++.a "${set_dir}"/*-w64-mingw32/lib/libunwind.a \
        "${set_dir}"/*-w64-mingw32/lib/libmingw32.a "${set_dir}"/*-w64-mingw32/lib/libmingwex.a \
        "${set_dir}"/*-w64-mingw32/lib/libucrt.a "${set_dir}"/*-w64-mingw32/lib/libkernel32.a \
        "${set_dir}"/*-w64-mingw32/lib/libwinpthread.a "${set_dir}"/*-w64-mingw32/lib/crt2.o; do
      [[ -e "${f}" ]] && cp "${f}" "${out}/${preset}/set/"
    done
  fi
done
find "${out}" -type f | sort
