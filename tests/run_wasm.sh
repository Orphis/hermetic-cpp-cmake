#!/usr/bin/env bash
# Instantiates a freestanding module built from tests/hello under Node.js
# and calls its exports: tests/run_wasm.sh <module.wasm> <32|64>
set -euo pipefail
module="$1"; bits="$2"
node -e '
const fs = require("fs");
const [file, bits] = process.argv.slice(1);
const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file)), {});
const e = instance.exports;
const checks = [
  ["add(7, 5)", e.add(7, 5), 12],
  ["mul(7, 5)", e.mul(7, 5), 35],
  ["pointer_bits()", e.pointer_bits(), Number(bits)],
  ["mul_high(1n << 40n, 1n << 40n)", e.mul_high(1n << 40n, 1n << 40n), 1n << 16n],
];
for (const [what, got, want] of checks) {
  if (got !== want) { console.error(`${what} = ${got}, expected ${want}`); process.exit(1); }
}
console.log(`wasm${bits} module: OK`);
' "${module}" "${bits}"
