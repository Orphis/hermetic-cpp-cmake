// Freestanding WebAssembly: no libc, functions exported for the host runtime.
#include <stdint.h>

__attribute__((export_name("add")))
int32_t add(int32_t a, int32_t b) {
  return a + b;
}

__attribute__((export_name("pointer_bits")))
int32_t pointer_bits(void) {
  return (int32_t)(sizeof(void *) * 8);
}

// Needs the compiler-rt builtins (__multi3 on both wasm32 and wasm64).
__attribute__((export_name("mul_high")))
int64_t mul_high(int64_t a, int64_t b) {
  return (int64_t)(((__int128)a * b) >> 64);
}
