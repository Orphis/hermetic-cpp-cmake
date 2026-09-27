#!/usr/bin/env bash
# vcpkg packages built with the toolchain: the consumer in tests/vcpkg
# installs its manifest, builds, and checks the installed libraries
# (tests/check_vcpkg_packages.py). Each argument is a triplet of
# vcpkg/triplets, used one of two ways:
#
#   <triplet>            vcpkg's toolchain file in front, chain-loading this
#                        one, with the shipped triplet
#   toolchain/<triplet>  this toolchain in front with HERMETIC_VCPKG=ON and
#                        the triplet's options on the command line; it writes
#                        a triplet of the same name for them
#
# and a ":run" suffix also runs the program on this host:
#
#   tests/run_vcpkg.sh toolchain/x64-linux-musl-hermetic:run x64-windows-static-hermetic
#
# vcpkg is the checkout HERMETIC_VCPKG=ON clones into the cache
# (cmake/distributions/vcpkg.json); build directories go to
# HERMETIC_VCPKG_WORK (tests/vcpkg/build by default; Windows hosts want a
# short one). Packages are always built (no binary cache).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "${here}")"
work="${HERMETIC_VCPKG_WORK:-${here}/vcpkg/build}"
mkdir -p "${work}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) windows_host=1 ;;
  *) windows_host=0 ;;
esac
native() { if [[ ${windows_host} == 1 ]]; then cygpath -m "$1"; else echo "$1"; fi; }

# The toolchain's own checkout, for both ways (the runner's VCPKG_ROOT, if
# any, is not the pinned one).
unset VCPKG_ROOT
vcpkg_root="$(cmake -P "$(native "${repo}")/scripts/vcpkg.cmake" 2>&1 | tail -n 1)"
[[ -e "${vcpkg_root}/.vcpkg-root" ]] || { echo "no vcpkg checkout: ${vcpkg_root}"; exit 1; }
export VCPKG_BINARY_SOURCES=clear VCPKG_DISABLE_METRICS=1

python="$(command -v python3 || command -v python)"
cache="${HERMETIC_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/hermetic-cpp}"
failed=()
for spec in "$@"; do
  name="${spec%%:*}"
  triplet="${name#toolchain/}"
  build="${work}/${name//\//-}"
  echo "=== vcpkg ${name}"
  rm -rf "${build}"
  args=(-G Ninja -S "$(native "${here}/vcpkg")" -B "$(native "${build}")" -DCMAKE_BUILD_TYPE=Release)
  if [[ "${name}" == toolchain/* ]]; then
    # The shipped triplet's settings as options: set(HERMETIC_X value).
    args+=("-DCMAKE_TOOLCHAIN_FILE=$(native "${repo}")/toolchain.cmake" -DHERMETIC_VCPKG=ON)
    while read -r var value; do
      if [[ "${var}" == VCPKG_CRT_LINKAGE && "${value}" == static ]]; then
        args+=("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded\$<\$<CONFIG:Debug>:Debug>")
      elif [[ "${var}" == HERMETIC_* ]]; then
        args+=("-D${var}=${value}")
      fi
    done < <(sed -n 's/^set(\([A-Z_]*\) \(.*\))$/\1 \2/p' "${repo}/vcpkg/triplets/${triplet}.cmake")
  else
    args+=("-DCMAKE_TOOLCHAIN_FILE=${vcpkg_root}/scripts/buildsystems/vcpkg.cmake"
      "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$(native "${repo}")/toolchain.cmake"
      "-DVCPKG_OVERLAY_TRIPLETS=$(native "${repo}")/vcpkg/triplets"
      "-DVCPKG_TARGET_TRIPLET=${triplet}")
  fi
  if ! cmake "${args[@]}" || ! cmake --build "$(native "${build}")"; then
    for log in "${vcpkg_root}"/buildtrees/*/*-err.log; do
      [[ -s "${log}" && "${log}" -nt "${build}" ]] && { echo "--- ${log}"; tail -n 40 "${log}"; }
    done
    failed+=("${name}")
    continue
  fi
  crt=-
  case "${triplet}" in
    *-windows-static-md-*) crt=dynamic ;;
    *-windows-static-*) crt=static ;;
  esac
  if ! "${python}" "$(native "${here}")/check_vcpkg_packages.py" "$(native "${build}")/vcpkg_installed/${triplet}" "${crt}" \
      "${vcpkg_root}" "$(native "${repo}")" "$(native "${cache}")"; then
    failed+=("${name}")
    continue
  fi
  if [[ "${spec}" == *:run ]]; then
    app="${build}/vcpkg_app"
    [[ -e "${app}.exe" ]] && app="${app}.exe"
    if ! "${app}"; then
      failed+=("${name}")
      continue
    fi
  fi
  echo "${name}: OK"
done

if [[ ${#failed[@]} -ne 0 ]]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
echo "all passed"
