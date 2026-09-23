#!/usr/bin/env bash
# Checks that builds are ready for remote build execution (RBE): the sample
# is built through the reference wrapper (scripts/rbe_wrapper.py, in strict
# mode, as the compiler and linker launcher) in this checkout and in a copy
# of it at another path, and the two must run the same compile and link
# actions (same commands once relativized, i.e. the same remote cache keys)
# and produce byte-identical outputs. Static libraries have no launcher: their
# archive commands are taken from the build files and checked by the wrapper
# without running them (--dry-run).
#
#   tests/run_rbe_check.sh                           # host preset
#   tests/run_rbe_check.sh linux-aarch64 windows-x86_64-libcxx-dbg
#
# The toolchain cache must be inside the workspace for the wrapper to
# rewrite it: HERMETIC_LLVM_CACHE_DIR defaults to <repo>/.hermetic-llvm
# here (the copy links to it). Filling it downloads the compiler and
# whatever the presets need, like any other cache directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
presets=("$@")
if [[ ${#presets[@]} -eq 0 ]]; then
  presets=(host)
fi
cache="${HERMETIC_LLVM_CACHE_DIR:-${repo}/.hermetic-llvm}"
mkdir -p "${cache}"
cache="$(cd "${cache}" && pwd)"
case "${cache}/" in
  "${repo}/"*) ;;
  *) echo "HERMETIC_LLVM_CACHE_DIR (${cache}) must be inside ${repo}"; exit 1 ;;
esac
cache_rel="${cache#"${repo}/"}"

# The copy: the tracked files as they are in the work tree, the cache linked.
other="$(mktemp -d "${TMPDIR:-/tmp}/hermetic-llvm-rbe-check.XXXXXX")"
trap 'rm -rf "${other}"' EXIT
(cd "${repo}" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "${other}"
mkdir -p "$(dirname "${other}/${cache_rel}")"
ln -s "${cache}" "${other}/${cache_rel}"

python="$(command -v python3 || command -v python)"

build() {  # build <checkout> <preset>
  local root="$1" preset="$2"
  local dir="${root}/tests/hello/build/rbe-${preset}"
  local launcher="${python};${root}/scripts/rbe_wrapper.py;--root=${root};--log=${dir}/rbe-actions.jsonl;--strict;--"
  local launchers=() lang
  for lang in C CXX OBJC OBJCXX ASM; do launchers+=("-DCMAKE_${lang}_COMPILER_LAUNCHER=${launcher}"); done
  for lang in C CXX OBJC OBJCXX; do launchers+=("-DCMAKE_${lang}_LINKER_LAUNCHER=${launcher}"); done
  rm -rf "${dir}"; mkdir -p "$(dirname "${dir}")"
  (cd "${root}/tests/hello" && cmake --preset "${preset}" -B "${dir}" \
      -DHERMETIC_LLVM_CACHE_DIR="${root}/${cache_rel}" "${launchers[@]}" > "${dir}.log" 2>&1) \
    || { echo "configure failed (${root}, ${preset}):"; tail -20 "${dir}.log"; return 1; }
  cmake --build "${dir}" >> "${dir}.log" 2>&1 \
    || { echo "build failed (${root}, ${preset}):"; grep -A3 'rbe_wrapper\|error' "${dir}.log" | head -30; return 1; }
}

outputs() {  # outputs <build dir>: the files a build produces
  (cd "$1" && find . \( -path ./CMakeFiles/CMakeScratch -o -path './CMakeFiles/[0-9]*' -o -path ./CMakeFiles/ShowIncludes -o -path ./hermetic-llvm \) -prune \
    -o -type f \( -name '*.o' -o -name '*.obj' -o -name '*.a' -o -name '*.lib' -o -name '*.so' -o -name '*.dylib' -o -name '*.dll' \
      -o -name '*.exe' -o -name '*.pdb' -o -name '*.wasm' -o -name 'hello_*' \) -print | sort)
}

keys() {  # keys <log>: the action keys, sorted
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if "argv" in r: print(r["key"], r["argv"][0].rsplit("/", 1)[-1], r["argv"][-1])' "$1" | sort
}

archive_keys() {  # archive_keys <checkout> <build dir>: archive commands, relativized and checked
  local root="$1" dir="$2" rc=0
  while IFS= read -r cmd; do
    [[ -n "${cmd}" ]] || continue
    eval "set -- ${cmd}"
    (cd "${dir}" && "${python}" "${root}/scripts/rbe_wrapper.py" "--root=${root}" --dry-run -- "$@") || rc=1
  done < <(ninja -C "${dir}" -t commands | awk '{gsub(/ && /, "\n"); print}' \
             | grep -E '/(llvm-ar|llvm-ranlib|llvm-lib)(\.exe)?"? ' || true)
  return ${rc}
}

status=0
for preset in "${presets[@]}"; do
  echo "=== ${preset}"
  build "${repo}" "${preset}" || { status=1; continue; }
  build "${other}" "${preset}" || { status=1; continue; }
  a="${repo}/tests/hello/build/rbe-${preset}"
  b="${other}/tests/hello/build/rbe-${preset}"
  if ! grep -q '"key"' "${a}/rbe-actions.jsonl" 2>/dev/null; then
    echo "no actions went through the wrapper"; status=1; continue
  fi
  if grep -q 'problems' "${a}/rbe-actions.jsonl" "${b}/rbe-actions.jsonl"; then
    echo "the wrapper reported problems:"; grep -h 'problems' "${a}/rbe-actions.jsonl" | head -5; status=1
  fi
  n=$(keys "${a}/rbe-actions.jsonl" | wc -l | tr -d ' ')
  if diff <(keys "${a}/rbe-actions.jsonl") <(keys "${b}/rbe-actions.jsonl") > "${a}.keys.diff"; then
    echo "${n} remote actions, the same in both checkouts"
  else
    echo "actions differ between the checkouts (${a}.keys.diff):"; head -10 "${a}.keys.diff"; status=1
  fi
  if ! archive_keys "${repo}" "${a}" > "${a}.archives" || ! archive_keys "${other}" "${b}" > "${b}.archives"; then
    echo "archive commands with absolute paths:"; grep -h problems "${a}.archives" "${b}.archives" | head -3; status=1
  elif ! diff <(python3 -c 'import json,sys; [print(json.loads(l)["key"]) for l in open(sys.argv[1])]' "${a}.archives" | sort) \
              <(python3 -c 'import json,sys; [print(json.loads(l)["key"]) for l in open(sys.argv[1])]' "${b}.archives" | sort) > /dev/null; then
    echo "archive commands differ between the checkouts"; status=1
  else
    echo "$(wc -l < "${a}.archives" | tr -d ' ') archive commands (not run through the wrapper), the same in both checkouts"
  fi
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
  fi
done
exit ${status}
