/* A libFuzzer target, in C (libFuzzer carries its own C++ library): the
 * input "FUZZ" crashes it, which the fuzzer must find. */
#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size >= 4 && data[0] == 'F' && data[1] == 'U' && data[2] == 'Z' && data[3] == 'Z') {
    __builtin_trap();
  }
  return 0;
}
