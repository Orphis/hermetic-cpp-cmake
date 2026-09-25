#!/usr/bin/env bash
# Checks that builds are ready for remote build execution (RBE): the sample
# is built through the reference wrapper (scripts/rbe_wrapper.py, in strict
# mode, as the compiler and linker launcher) in this checkout and in a copy
# of it at another path, and the two must run the same compile and link
# actions (same commands once relativized, i.e. the same remote cache keys)
# and produce byte-identical outputs. Static libraries have no launcher:
# their archive commands are taken from the build files and checked by the
# wrapper without running them (--archives-of).
#
#   tests/run_rbe_check.sh                           # host preset
#   tests/run_rbe_check.sh linux-aarch64 windows-x86_64-libcxx-dbg
#
# The toolchain cache must be reachable from inside the workspace for the
# wrapper to rewrite it: by default it is <repo>/.hermetic-cpp. When
# HERMETIC_CACHE_DIR names a cache elsewhere (such as CI's), the
# checkout gets a link to it under that name, so the presets built there
# are reused. The copy links to the same cache; HERMETIC_RBE_CHECK_KEEP=1
# keeps it for inspection.
set -euo pipefail

windows=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows=1 ;; esac
# Paths as native programs (CMake, Python) take them.
native() { if [[ ${windows} == 1 ]]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
# Directory links: symbolic links, or junctions on Windows hosts (made and
# removed by Python: Git Bash would rewrite cmd's /J switch as a path).
link_dir() {  # link_dir <target> <link>
  if [[ ${windows} == 1 ]]; then
    "${python}" -c 'import _winapi, sys; _winapi.CreateJunction(sys.argv[1], sys.argv[2])' "$(native "$1")" "$(native "$2")"
  else
    ln -s "$1" "$2"
  fi
}
unlink_dir() {  # removes a directory link, never what it points to (rmdir cannot)
  if [[ ${windows} == 1 ]]; then
    "${python}" -c 'import os, sys; os.rmdir(sys.argv[1])' "$(native "$1")" 2> /dev/null || true
  else
    rm -f "$1"
  fi
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(native "$(cd "${here}/.." && pwd)")"
presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=(host)
fi
if [[ ${windows} == 1 ]]; then
  python="$(native "$(command -v python)")"
else
  python="$(command -v python3)"
fi

in_tree="${repo}/.hermetic-cpp"
cache="$(native "${HERMETIC_CACHE_DIR:-${in_tree}}")"
mkdir -p "${cache}"
case "${cache}/" in
  "${repo}/"*) ;;
  *)
    if [[ -e "${in_tree}" || -L "${in_tree}" ]]; then
      if [[ "$(cd "${in_tree}" && pwd -P)" != "$(cd "${cache}" && pwd -P)" ]]; then
        echo "${in_tree} exists and is not ${cache}; remove it or unset HERMETIC_CACHE_DIR"; exit 1
      fi
    else
      link_dir "${cache}" "${in_tree}"
    fi
    cache="${in_tree}"
    ;;
esac
cache_rel="${cache#"${repo}/"}"
cache_real="$(native "$(cd "${cache}" && pwd -P)")"

# The copy: the tracked files as they are in the work tree, the cache linked.
other="$(native "$(mktemp -d "${TMPDIR:-/tmp}/hl-rbe.XXXXXX")")"
cleanup() {
  if [[ "${HERMETIC_RBE_CHECK_KEEP:-0}" == 1 ]]; then echo "kept the copy: ${other}"; return; fi
  unlink_dir "${other}/${cache_rel}"
  rm -rf "${other}"
}
trap cleanup EXIT
(cd "${repo}" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf - 2> /dev/null) | tar -xf - -C "${other}"
mkdir -p "$(dirname "${other}/${cache_rel}")"
link_dir "${cache_real}" "${other}/${cache_rel}"

build() {  # build <checkout> <preset>
  local root="$1" preset="$2"
  local dir="${root}/tests/hello/build/rbe-${preset}"
  local launcher="${python};${root}/scripts/rbe_wrapper.py;--root=${root};--log=${dir}/rbe-actions.jsonl;--strict;--"
  local launchers=() lang
  for lang in C CXX OBJC OBJCXX ASM; do launchers+=("-DCMAKE_${lang}_COMPILER_LAUNCHER=${launcher}"); done
  for lang in C CXX OBJC OBJCXX; do launchers+=("-DCMAKE_${lang}_LINKER_LAUNCHER=${launcher}"); done
  rm -rf "${dir}"; mkdir -p "$(dirname "${dir}")"
  (cd "${root}/tests/hello" && cmake --preset "${preset}" -B "${dir}" \
      -DHERMETIC_CACHE_DIR="${root}/${cache_rel}" "${launchers[@]}" > "${dir}.log" 2>&1) \
    || { echo "configure failed (${root}, ${preset}):"; tail -20 "${dir}.log"; return 1; }
  cmake --build "${dir}" >> "${dir}.log" 2>&1 \
    || { echo "build failed (${root}, ${preset}):"; grep -A3 'rbe_wrapper\|error' "${dir}.log" | head -30; return 1; }
  "${python}" "${root}/scripts/rbe_wrapper.py" "--root=${root}" "--archives-of=${dir}" > "${dir}.archives" \
    || { echo "archive commands with absolute paths (${root}, ${preset}):"; grep problems "${dir}.archives" | head -3; return 1; }
}

outputs() {  # outputs <build dir>: the files a build produces
  (cd "$1" && find . \( -path ./CMakeFiles/CMakeScratch -o -path './CMakeFiles/[0-9]*' -o -path ./CMakeFiles/ShowIncludes -o -path ./hermetic-cpp \) -prune \
    -o -type f \( -name '*.o' -o -name '*.obj' -o -name '*.a' -o -name '*.lib' -o -name '*.so' -o -name '*.dylib' -o -name '*.dll' \
      -o -name '*.exe' -o -name '*.pdb' -o -name '*.wasm' -o -name 'hello_*' \) -print | sort)
}

keys() {  # keys <log>: the action keys, sorted
  "${python}" -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if "argv" in r: print(r["key"], r["argv"][0].rsplit("/", 1)[-1], r["argv"][-1])' "$1" | sort
}

compare_keys() {  # compare_keys <label> <log a> <log b>
  local n
  n=$(keys "$2" | wc -l | tr -d ' ')
  if diff <(keys "$2") <(keys "$3") > "$2.diff"; then
    echo "${n} $1, the same in both checkouts"
  else
    echo "$1 differ between the checkouts ($2.diff):"; head -10 "$2.diff"; return 1
  fi
}

status=0
for preset in "${presets[@]}"; do
  echo "=== ${preset}"
  build "${repo}" "${preset}" || { status=1; continue; }
  build "${other}" "${preset}" || { status=1; continue; }
  a="${repo}/tests/hello/build/rbe-${preset}"
  b="${other}/tests/hello/build/rbe-${preset}"
  if ! grep -q '"key"' "${a}/rbe-actions.jsonl" 2> /dev/null; then
    echo "no actions went through the wrapper"; status=1; continue
  fi
  if grep -q 'problems' "${a}/rbe-actions.jsonl" "${b}/rbe-actions.jsonl"; then
    echo "the wrapper reported problems:"; grep -h 'problems' "${a}/rbe-actions.jsonl" | head -5; status=1
  fi
  compare_keys "remote actions" "${a}/rbe-actions.jsonl" "${b}/rbe-actions.jsonl" || status=1
  compare_keys "archive commands" "${a}.archives" "${b}.archives" || status=1
  files=$(outputs "${a}")
  if [[ "${files}" != "$(outputs "${b}")" ]]; then
    echo "the checkouts produced different sets of files"; status=1; continue
  fi
  differing=()
  for f in ${files}; do
    cmp -s "${a}/${f}" "${b}/${f}" || differing+=("${f#./}")
  done
  if [[ ${#differing[@]} -eq 0 ]]; then
    echo "$(echo "${files}" | wc -l | tr -d ' ') outputs, byte-identical in both checkouts"
  else
    echo "outputs differ between the checkouts: ${differing[*]}"; status=1
    # What differs, for the first few: the printable strings only one side
    # has (paths, command lines), which is what usually leaks.
    for f in "${differing[@]:0:3}"; do
      echo "--- strings only in one checkout's ${f} (a: ${a##*/}, b: ${b##*/}):"
      python3 - "${a}/${f}" "${b}/${f}" <<'PY'
import re, sys
def strings(path):
    return set(m.decode("ascii") for m in re.findall(rb"[ -~]{6,}", open(path, "rb").read()))
sa, sb = strings(sys.argv[1]), strings(sys.argv[2])
for label, only in (("a", sorted(sa - sb)), ("b", sorted(sb - sa))):
    for s in only[:8]:
        print(f"    {label}: {s[:200]}")
    if len(only) > 8:
        print(f"    {label}: ... {len(only) - 8} more")
if sa == sb:
    print("    no difference in printable strings (binary content differs)")
PY
    done
  fi
done
exit ${status}
