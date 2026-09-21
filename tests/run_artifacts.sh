#!/usr/bin/env bash
# Runs staged test binaries (see stage_artifacts.sh) that belong to the given
# execution environment, whatever host built them:
#
#   tests/run_artifacts.sh <environment> [artifacts dir]
#
# Environments:
#   linux-x86_64, linux-aarch64   Linux binaries for that architecture, run in a
#                                 Debian container matching the libc (native Docker);
#                                 linux-x86_64 also runs the WebAssembly modules under Node.js
#   linux-qemu                    Linux binaries for every other architecture, run
#                                 in Debian containers through QEMU
#   darwin-aarch64, darwin-x86_64 macOS binaries run directly
#   windows-x86_64, windows-aarch64  Windows binaries run directly (Git Bash)
#
# glibc binaries additionally get a negative check: one built against
# glibc 2.4x must be refused by Debian bullseye.
#
# Afterwards the SHA-256 of every binary is listed per target and preset, so
# that builds of the same target from different hosts can be compared.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_name="$1"
artifacts="${2:-${here}/../artifacts}"

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi
}

image_for_libc() {
  case "$1" in
    gnu.2.4[2-9]) echo debian:sid-slim ;;
    gnu.2.3[7-9]|gnu.2.4[01]) echo debian:trixie-slim ;;
    gnu.2.3[2-6]) echo debian:bookworm-slim ;;
    *) echo debian:bullseye-slim ;;
  esac
}
platform_for_target() {
  case "$1" in
    linux-x86_64) echo linux/amd64 ;;
    linux-aarch64) echo linux/arm64 ;;
    linux-armv7) echo linux/arm/v7 ;;
    linux-riscv64) echo linux/riscv64 ;;
    linux-s390x) echo linux/s390x ;;
  esac
}
# riscv64 and s390x Debian images exist for trixie only.
image_for() {
  local target="$1" libc="$2"
  case "${target}" in
    linux-riscv64|linux-s390x) case "${libc}" in gnu.2.4[2-9]) echo debian:sid-slim ;; *) echo debian:trixie-slim ;; esac ;;
    *) image_for_libc "${libc}" ;;
  esac
}
runs_here() {
  local target="$1"
  case "${env_name}" in
    linux-x86_64) [[ "${target}" == "${env_name}" || "${target}" == wasm* ]] ;;
    linux-aarch64) [[ "${target}" == "${env_name}" ]] ;;
    linux-qemu) [[ "${target}" == linux-* && "${target}" != linux-x86_64 && "${target}" != linux-aarch64 ]] ;;
    darwin-*|windows-*) [[ "${target}" == "${env_name}" ]] ;;
    *) echo "unknown environment ${env_name}"; exit 2 ;;
  esac
}

ran=0
for dir in "${artifacts}"/*/*/; do
  [[ -f "${dir}/target.txt" ]] || continue
  IFS=';' read -r target libc sdk < "${dir}/target.txt"
  target="${target%$'\r'}"; libc="${libc%$'\r'}"; sdk="${sdk%$'\r'}"  # CMake writes CRLF on Windows hosts
  runs_here "${target}" || continue
  host="$(basename "$(dirname "${dir}")")"
  preset="$(basename "${dir}")"
  echo "=== ${target} ${libc:-} (${preset} built on ${host})"
  chmod +x "${dir}"/hello_* 2>/dev/null || true
  if [[ "${target}" == wasm* ]]; then
    "${here}/run_wasm.sh" "${dir}/hello_wasm.wasm" "${target#wasm}"
  elif [[ "${target}" == linux-* ]]; then
    platform="$(platform_for_target "${target}")"
    image="$(image_for "${target}" "${libc}")"
    abs="$(cd "${dir}" && pwd)"
    echo "--- docker ${platform} ${image}"
    docker run --rm --platform="${platform}" -v "${abs}:/b:ro" "${image}" \
      sh -ec '/b/hello_c; /b/hello_cxx; if [ -e /b/hello_shared ]; then LD_LIBRARY_PATH=/b /b/hello_shared; fi'
    case "${libc}" in
      gnu.2.4*)
        echo "--- expecting a glibc mismatch on bullseye"
        if docker run --rm --platform="${platform}" -v "${abs}:/b:ro" debian:bullseye-slim /b/hello_c 2>/dev/null; then
          echo "binary unexpectedly ran on bullseye"; exit 1
        fi ;;
    esac
  elif [[ "${target}" == windows-* ]]; then
    (cd "${dir}" && ./hello_c.exe && ./hello_cxx.exe && { [[ ! -e hello_shared.exe ]] || ./hello_shared.exe; })
  else
    (cd "${dir}" && ./hello_c && ./hello_cxx && { [[ ! -e hello_shared ]] || DYLD_LIBRARY_PATH=. ./hello_shared; })
  fi
  ran=$((ran + 1))
done
[[ ${ran} -gt 0 ]] || { echo "no artifacts for environment ${env_name}"; exit 1; }
echo "ran ${ran} artifact set(s)"

# Reproducibility: the same preset built on different hosts must produce
# identical binaries. Reported always; enforced with
# HERMETIC_TESTS_ENFORCE_REPRODUCIBLE=1.
echo "=== SHA-256 per target/preset across hosts"
table="$(for dir in "${artifacts}"/*/*/; do
  [[ -f "${dir}/target.txt" ]] || continue
  IFS=';' read -r target libc sdk < "${dir}/target.txt"
  target="${target%$'\r'}"; libc="${libc%$'\r'}"; sdk="${sdk%$'\r'}"  # CMake writes CRLF on Windows hosts
  runs_here "${target}" || continue
  host="$(basename "$(dirname "${dir}")")"; preset="$(basename "${dir}")"
  for f in "${dir}"/hello_c "${dir}"/hello_cxx "${dir}"/hello_shared "${dir}"/libgreeter.so "${dir}"/libgreeter_static.a "${dir}"/hello_c.exe "${dir}"/hello_cxx.exe "${dir}"/hello_shared.exe "${dir}"/greeter.dll "${dir}"/libgreeter.dll "${dir}"/greeter_static.lib "${dir}"/hello_wasm.wasm "${dir}"/clang_rt.asan_dynamic-*.dll "${dir}"/*.pdb "${dir}"/set/*; do
    [[ -f "$f" ]] || continue
    [[ "$f" != *.exe && -f "$f.exe" ]] && continue  # Git Bash resolves hello_c to hello_c.exe
    name="$(basename "$f")"; [[ "$f" == */set/* ]] && name="set/${name}"
    printf '%s %s %s %s %s\n' "${preset}" "${name}" "$(sha256 "$f" | cut -c1-16)" "${host}" "${sdk:--}"
  done
done | sort; true)"
echo "${table}" | awk '{printf "%-28s %-34s %s  %-24s %s\n", $1, $2, $3, $4, ($5=="-" ? "" : "sdk " $5)}'
# Expected differences, reported but not enforced:
# - sanitized program binaries: ASan records each module's source path and
#   UBSan its check locations, which no prefix map covers;
# - macOS binaries built against different SDK versions (the SDK is the
#   host's, not a hermetic input);
# - debug info built on a Windows host, where clang joins include paths with
#   backslashes after the mapped prefix; only the Windows-host builds may
#   deviate, every other host must still agree.
classified="$(echo "${table}" | awk '
  { k=$1" "$2; hosts[k]=hosts[k]" "$4; hash[k" "$4]=$3; sdk[k" "$4]=$5; if (!(k in seen)) { seen[k]=1; order[++n]=k } }
  END {
    for (i=1; i<=n; i++) {
      k=order[i]; m=split(hosts[k], hs, " "); delete all; delete unix; delete sdks; na=0; nu=0; ns=0
      for (j=1; j<=m; j++) { if (hs[j]=="") continue; h=hash[k" "hs[j]]; s=sdk[k" "hs[j]]
        if (!(h in all)) { all[h]=1; na++ }
        if (hs[j] !~ /^windows-/ && !(h in unix)) { unix[h]=1; nu++ }
        if (!(s in sdks)) { sdks[s]=1; ns++ } }
      if (na <= 1) continue
      split(k, kk, " "); preset=kk[1]; file=kk[2]
      if (preset ~ /-(asan|ubsan|msan|tsan)($|-)/ && file !~ /^(clang_rt\.|set\/)/) print "expected", k
      else if (preset ~ /^darwin-/ && ns > 1) print "expected", k
      else if (preset ~ /-dbg($|-)/ && nu <= 1) print "expected", k
      else print "unexpected", k
    }
  }' | sort)"
expected="$(echo "${classified}" | awk '$1=="expected" {print $2, $3}' || true)"
unexpected="$(echo "${classified}" | awk '$1=="unexpected" {print $2, $3}' || true)"
if [[ -n "${expected}" ]]; then
  echo "--- differ across hosts as expected (sanitized, differing macOS SDKs, or Windows-host debug info):"; echo "${expected}" | sed 's/^/    /'
fi
if [[ -n "${unexpected}" ]]; then
  echo "--- NOT reproducible across hosts:"; echo "${unexpected}" | sed 's/^/    /'
  if [[ "${HERMETIC_TESTS_ENFORCE_REPRODUCIBLE:-0}" == 1 ]]; then exit 1; fi
elif [[ -z "${expected}" ]]; then
  echo "--- all binaries identical across hosts"
else
  echo "--- all other binaries identical across hosts"
fi
