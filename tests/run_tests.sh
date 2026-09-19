#!/usr/bin/env bash
# End-to-end tests: native build + ctest, then cross builds whose binaries are
# checked with `file` and, when Docker is available, executed in a container
# for the target platform (Debian bullseye: glibc 2.31, so gnu.2.28 sets run;
# gnu.2.34 uses Debian bookworm; musl binaries are fully static).
#
#   tests/run_tests.sh                     # default presets
#   tests/run_tests.sh linux-aarch64-musl  # only the named presets
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${here}/hello"

presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=(host linux-x86_64 linux-x86_64-musl linux-aarch64 linux-aarch64-musl)
fi

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

run_in_docker() {
  local platform="$1" image="$2" dir="$3"
  echo "--- running in docker (${platform}, ${image})"
  docker run --rm --platform="${platform}" -v "${dir}:/build:ro" "${image}" \
    sh -ec '/build/hello_c; /build/hello_cxx; if [ -e /build/hello_shared ]; then LD_LIBRARY_PATH=/build /build/hello_shared; fi'
}

for preset in "${presets[@]}"; do
  echo "=== preset ${preset}"
  rm -rf "build/${preset}"
  cmake --preset "${preset}"
  cmake --build --preset "${preset}"
  dir="$(cd "build/${preset}" && pwd)"
  image=debian:bullseye-slim
  case "${preset}" in *gnu.2.3[4-9]*|*gnu.2.4*) image=debian:bookworm-slim ;; esac
  case "${preset}" in
    host*)
      ctest --preset "${preset}"
      ;;
    linux-x86_64*)
      file "${dir}/hello_cxx" | grep -q "ELF 64-bit LSB.*x86-64" || { file "${dir}/hello_cxx"; exit 1; }
      have_docker && run_in_docker linux/amd64 "${image}" "${dir}"
      ;;
    linux-aarch64*)
      file "${dir}/hello_cxx" | grep -q "ELF 64-bit LSB.*aarch64" || { file "${dir}/hello_cxx"; exit 1; }
      have_docker && run_in_docker linux/arm64 "${image}" "${dir}"
      ;;
    linux-armv7*)
      file "${dir}/hello_cxx" | grep -q "ELF 32-bit LSB.*ARM" || { file "${dir}/hello_cxx"; exit 1; }
      have_docker && run_in_docker linux/arm/v7 "${image}" "${dir}"
      ;;
    linux-riscv64*)
      file "${dir}/hello_cxx" | grep -q "RISC-V" || { file "${dir}/hello_cxx"; exit 1; }
      ;;
  esac
  case "${preset}" in
    *musl*) file "${dir}/hello_cxx" | grep -q "static" || { echo "expected a static musl binary"; file "${dir}/hello_cxx"; exit 1; } ;;
  esac
done
echo "all presets passed"
