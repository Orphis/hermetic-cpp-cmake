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
  [[ -f "${src}/target.txt" ]] || { echo "no build for preset ${preset}"; exit 1; }
  mkdir -p "${out}/${preset}"
  cp "${src}/target.txt" "${out}/${preset}/"
  for f in hello_c hello_cxx hello_shared hello_c.exe hello_cxx.exe hello_shared.exe libgreeter.so libgreeter.dylib greeter.dll; do
    [[ -e "${src}/${f}" ]] && cp "${src}/${f}" "${out}/${preset}/"
  done
done
find "${out}" -type f | sort
