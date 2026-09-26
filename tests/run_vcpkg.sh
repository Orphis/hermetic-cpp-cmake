#!/usr/bin/env bash
# vcpkg packages built with the toolchain's triplets (vcpkg/triplets): the
# consumer in tests/vcpkg installs its manifest for each triplet, builds, and
# checks the installed libraries (tests/check_vcpkg_packages.py); a triplet
# followed by ":run" also runs the program on this host.
#
#   tests/run_vcpkg.sh x64-linux-musl-hermetic:run x64-windows-static-hermetic
#
# vcpkg is HERMETIC_VCPKG_ROOT, or a checkout of the commit below cloned
# into the work directory, HERMETIC_VCPKG_WORK (tests/vcpkg/build by
# default; Windows hosts want a short one). Packages are always built (no
# binary cache).
set -euo pipefail

VCPKG_COMMIT=6df3b6ad25ac49dab7c8fbe927d5293198e75951  # 2026-09-25

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "${here}")"
work="${HERMETIC_VCPKG_WORK:-${here}/vcpkg/build}"
mkdir -p "${work}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) windows_host=1 ;;
  *) windows_host=0 ;;
esac
native() { if [[ ${windows_host} == 1 ]]; then cygpath -m "$1"; else echo "$1"; fi; }

VCPKG_ROOT="${HERMETIC_VCPKG_ROOT:-}"
if [[ -z "${VCPKG_ROOT}" ]]; then
  VCPKG_ROOT="${work}/vcpkg"
  if [[ "$(git -C "${VCPKG_ROOT}" rev-parse HEAD 2>/dev/null)" != "${VCPKG_COMMIT}" ]]; then
    rm -rf "${VCPKG_ROOT}"
    git init -q "${VCPKG_ROOT}"
    git -C "${VCPKG_ROOT}" fetch -q --depth 1 https://github.com/microsoft/vcpkg.git "${VCPKG_COMMIT}"
    git -C "${VCPKG_ROOT}" checkout -q FETCH_HEAD
  fi
fi
if [[ ! -x "${VCPKG_ROOT}/vcpkg" && ! -x "${VCPKG_ROOT}/vcpkg.exe" ]]; then
  if [[ ${windows_host} == 1 ]]; then
    (cd "${VCPKG_ROOT}" && cmd //c bootstrap-vcpkg.bat -disableMetrics)
  else
    "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
  fi
fi
export VCPKG_ROOT
export VCPKG_BINARY_SOURCES=clear VCPKG_DISABLE_METRICS=1

python="$(command -v python3 || command -v python)"
cache="${HERMETIC_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/hermetic-cpp}"
failed=()
for spec in "$@"; do
  triplet="${spec%%:*}"
  build="${work}/${triplet}"
  echo "=== vcpkg triplet ${triplet}"
  rm -rf "${build}"
  if ! cmake -G Ninja -S "$(native "${here}/vcpkg")" -B "$(native "${build}")" \
      -DCMAKE_BUILD_TYPE=Release \
      "-DCMAKE_TOOLCHAIN_FILE=$(native "${VCPKG_ROOT}")/scripts/buildsystems/vcpkg.cmake" \
      "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$(native "${repo}")/toolchain.cmake" \
      "-DVCPKG_OVERLAY_TRIPLETS=$(native "${repo}")/vcpkg/triplets" \
      "-DVCPKG_TARGET_TRIPLET=${triplet}" \
    || ! cmake --build "$(native "${build}")"; then
    for log in "${VCPKG_ROOT}"/buildtrees/*/*-err.log; do
      [[ -s "${log}" ]] && { echo "--- ${log}"; tail -n 40 "${log}"; }
    done
    failed+=("${triplet}")
    continue
  fi
  crt=-
  case "${triplet}" in
    *-windows-static-md-*) crt=dynamic ;;
    *-windows-static-*) crt=static ;;
  esac
  if ! "${python}" "$(native "${here}")/check_vcpkg_packages.py" "$(native "${build}")/vcpkg_installed/${triplet}" "${crt}" \
      "$(native "${VCPKG_ROOT}")" "$(native "${repo}")" "$(native "${cache}")"; then
    failed+=("${triplet}")
    continue
  fi
  if [[ "${spec}" == *:run ]]; then
    app="${build}/vcpkg_app"
    [[ -e "${app}.exe" ]] && app="${app}.exe"
    if ! "${app}"; then
      failed+=("${triplet}")
      continue
    fi
  fi
  echo "${triplet}: OK"
done

if [[ ${#failed[@]} -ne 0 ]]; then
  echo "failed triplets: ${failed[*]}"
  exit 1
fi
echo "all triplets passed"
