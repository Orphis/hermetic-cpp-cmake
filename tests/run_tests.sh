#!/usr/bin/env bash
# End-to-end tests: native build + ctest, then cross builds whose binaries are
# checked with `file` and, when Docker is available, executed in a container
# for the target platform. Foreign architectures need QEMU registered with
# Docker (docker/setup-qemu-action in CI, Docker Desktop on macOS).
#
#   tests/run_tests.sh                     # default presets
#   tests/run_tests.sh linux-aarch64-musl  # only the named presets
#
# HERMETIC_TESTS_REQUIRE_DOCKER=1 fails instead of skipping when Docker is
# unavailable; HERMETIC_TESTS_SKIP_DOCKER=1 never executes the binaries.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${here}/hello"

presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=(host linux-x86_64 linux-x86_64-musl linux-aarch64 linux-aarch64-musl)
fi

have_docker() { [[ "${HERMETIC_TESTS_SKIP_DOCKER:-0}" != 1 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# Debian image whose glibc satisfies the preset's libc (bullseye 2.31,
# bookworm 2.36, trixie 2.41, sid newest); musl binaries run anywhere.
image_for() {
  case "$1" in
    *gnu.2.4[2-9]*) echo debian:sid-slim ;;
    *gnu.2.3[7-9]*|*gnu.2.4[01]*) echo debian:trixie-slim ;;
    *gnu.2.3[2-6]*) echo debian:bookworm-slim ;;
    *riscv64*|*s390x*) echo debian:trixie-slim ;;  # only trixie ships these architectures
    *) echo debian:bullseye-slim ;;
  esac
}

platform_for() {
  case "$1" in
    linux-x86_64*) echo linux/amd64 ;;
    linux-aarch64*) echo linux/arm64 ;;
    linux-armv7*) echo linux/arm/v7 ;;
    linux-riscv64*) echo linux/riscv64 ;;
    linux-s390x*) echo linux/s390x ;;
  esac
}

elf_pattern_for() {
  case "$1" in
    linux-x86_64*) echo "ELF 64-bit LSB.*x86-64" ;;
    linux-aarch64*) echo "ELF 64-bit LSB.*aarch64" ;;
    linux-armv7*) echo "ELF 32-bit LSB.*ARM" ;;
    linux-riscv64*) echo "RISC-V" ;;
    linux-s390x*) echo "ELF 64-bit MSB.*S/390" ;;
  esac
}

run_in_docker() {
  local platform="$1" image="$2" dir="$3"
  echo "--- running in docker (${platform}, ${image})"
  docker run --rm --platform="${platform}" -v "${dir}:/build:ro" "${image}" \
    sh -ec '/build/hello_c; /build/hello_cxx; if [ -e /build/hello_shared ]; then LD_LIBRARY_PATH=/build /build/hello_shared; fi'
}

# A binary linked against a newer glibc than the image provides must refuse
# to run: proves that the version pinning is real.
expect_glibc_mismatch() {
  local platform="$1" image="$2" dir="$3"
  echo "--- expecting a glibc version mismatch in docker (${platform}, ${image})"
  if docker run --rm --platform="${platform}" -v "${dir}:/build:ro" "${image}" /build/hello_c 2>/dev/null; then
    echo "binary unexpectedly ran on ${image}"; exit 1
  fi
}

for preset in "${presets[@]}"; do
  echo "=== preset ${preset}"
  rm -rf "build/${preset}"
  cmake --preset "${preset}"
  cmake --build --preset "${preset}"
  dir="$(cd "build/${preset}" && pwd)"
  case "${preset}" in
    host*|darwin-*|windows-*)
      if [[ "${preset}" == host* ]]; then ctest --preset "${preset}"; fi
      ;;
    wasm*)
      # Modules run under Node.js; wasm64 needs 24 or newer (memory64), which
      # the run stage of CI installs, so an older one only skips it here.
      bits=32; [[ "${preset}" == wasm64* ]] && bits=64
      node_major="$(command -v node >/dev/null 2>&1 && node --version | sed 's/^v\([0-9]*\).*/\1/' || echo 0)"
      if [[ "${node_major}" -ge 24 || ( "${bits}" == 32 && "${node_major}" -ge 16 ) ]]; then
        "${here}/run_wasm.sh" "${dir}/hello_wasm.wasm" "${bits}"
      else
        echo "--- node ${node_major:-missing} cannot run wasm${bits} modules, skipping the run"
      fi
      ;;
    linux-*)
      if command -v file >/dev/null 2>&1; then
        file "${dir}/hello_cxx" | grep -q "$(elf_pattern_for "${preset}")" || { file "${dir}/hello_cxx"; exit 1; }
        case "${preset}" in
          *musl*) file "${dir}/hello_cxx" | grep -q "static" || { echo "expected a static musl binary"; file "${dir}/hello_cxx"; exit 1; } ;;
        esac
      else
        echo "--- 'file' not available, skipping the ELF check"
      fi
      if have_docker; then
        run_in_docker "$(platform_for "${preset}")" "$(image_for "${preset}")" "${dir}"
        case "${preset}" in
          *gnu.2.4*) expect_glibc_mismatch "$(platform_for "${preset}")" debian:bullseye-slim "${dir}" ;;
        esac
      elif [[ "${HERMETIC_TESTS_REQUIRE_DOCKER:-0}" == 1 ]]; then
        echo "Docker is required but unavailable"; exit 1
      fi
      ;;
  esac
done
echo "all presets passed"
