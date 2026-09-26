// Copyright 2026 The hermetic-cpp-cmake Authors.
// SPDX-License-Identifier: Apache-2.0

#include <cstring>
#include <string>
#include <thread>

#ifdef HAVE_BOOST_CONTEXT
#include <boost/context/fiber.hpp>
#endif
#include <fmt/format.h>
#include <png.h>
#include <spdlog/spdlog.h>
#include <zlib.h>
#include <zstd.h>
#ifdef HAVE_FFI
#include <ffi.h>
#endif

#ifdef HAVE_FFI
static int add(int a, int b) { return a + b; }
#endif

int main() {
  const char *text = "hermetic vcpkg hermetic vcpkg hermetic vcpkg";
  bool ok = true;

  unsigned char deflated[256];
  uLongf deflated_size = sizeof deflated;
  ok = ok && compress(deflated, &deflated_size, reinterpret_cast<const Bytef *>(text), std::strlen(text)) == Z_OK;

  char zstd_buffer[256];
  size_t zstd_size = ZSTD_compress(zstd_buffer, sizeof zstd_buffer, text, std::strlen(text), 3);
  ok = ok && !ZSTD_isError(zstd_size);

  std::string ffi = "no libffi";
#ifdef HAVE_FFI
  ffi_cif cif;
  ffi_type *types[2] = {&ffi_type_sint, &ffi_type_sint};
  int a = 2, b = 3;
  void *values[2] = {&a, &b};
  ffi_arg result = 0;
  ok = ok && ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &ffi_type_sint, types) == FFI_OK;
  if (ok) {
    ffi_call(&cif, FFI_FN(add), &result, values);
    ok = static_cast<int>(result) == 5;
  }
  ffi = "libffi";
#endif

  // Boost.Context switches stacks in assembly of its own: ping-pong
  // between two contexts.
  int steps = 0;
#ifdef HAVE_BOOST_CONTEXT
  {
    namespace ctx = boost::context;
    ctx::fiber other{[&steps](ctx::fiber &&main) {
      for (int i = 0; i < 3; ++i) {
        ++steps;
        main = std::move(main).resume();
      }
      return std::move(main);
    }};
    for (int i = 0; i < 3; ++i) other = std::move(other).resume();
  }
  ok = ok && steps == 3;
#endif

  // spdlog keeps thread_local state: logging from another thread runs its
  // destructors when that thread exits.
  std::thread([] { spdlog::info("from a thread"); }).join();

  spdlog::info("{}: zlib {}, zstd {}, libpng {}, {}, {} context switches: {}", fmt::format("vcpkg"), zlibVersion(),
               ZSTD_versionString(), png_get_libpng_ver(nullptr), ffi, steps * 2, ok ? "OK" : "FAIL");
  return ok ? 0 : 1;
}
