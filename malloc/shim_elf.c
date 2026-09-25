/* Copyright 2026 The hermetic-cpp-cmake Authors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HERMETIC_MALLOC for Linux targets: the executable defines the whole malloc
 * family and forwards it to the backend.
 *
 * - glibc: the executable's definitions interpose libc.so.6's through the
 *   dynamic symbol table (lld exports them because the libc stubs define
 *   them too), so libc's own allocations (strdup, stdio buffers, ...) and any
 *   shared library use the backend as well, as glibc's manual describes for
 *   replacing malloc.
 * - musl: everything is linked statically and these definitions come first.
 *   musl allocates a few internal objects (locales, atexit, time zones) on
 *   its own heap through __libc_malloc and frees them there, which is
 *   harmless; everything handed to the program comes from the backend. Every
 *   aligned entry point is defined here, since musl's own would hand out
 *   blocks of its heap that the backend's free would then receive.
 */
/* The project's warning flags (-Werror included) are not this file's concern. */
#if defined(__clang__)
#pragma clang diagnostic ignored "-Weverything"
#elif defined(_MSC_VER)
#pragma warning(push, 0)
#endif

#include "hermetic_malloc.h"

#include <errno.h>
#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

#if !defined(__linux__)
#error "shim_elf.c is for Linux targets"
#endif

#if !HERMETIC_MALLOC_SANITIZED

/* Default visibility even when the project builds with -fvisibility=hidden:
 * glibc's libc.so.6 must see these. */
#define SHIM_API __attribute__((visibility("default"), used))
#define MIN_ALIGN alignof(max_align_t)

static int is_power_of_two(size_t n) { return n && !(n & (n - 1)); }

static void *enomem(void *p) {
  if (!p) errno = ENOMEM;
  return p;
}

static size_t page_size(void) {
  static size_t cached;
  if (!cached) cached = (size_t)sysconf(_SC_PAGESIZE);
  return cached;
}

static void *aligned(size_t alignment, size_t size) {
  if (alignment <= MIN_ALIGN) return enomem(hermetic_malloc_backend_malloc(size));
  return enomem(hermetic_malloc_backend_aligned(alignment, size));
}

SHIM_API void *malloc(size_t size) { return enomem(hermetic_malloc_backend_malloc(size)); }

SHIM_API void free(void *ptr) {
  if (ptr) hermetic_malloc_backend_free(ptr);
}

SHIM_API void *calloc(size_t count, size_t size) {
  return enomem(hermetic_malloc_backend_calloc(count, size));
}

SHIM_API void *realloc(void *ptr, size_t size) {
  if (!ptr) return malloc(size);
  if (!size) {
#ifdef __GLIBC__
    /* glibc frees and returns null; musl keeps a minimal block. */
    hermetic_malloc_backend_free(ptr);
    return NULL;
#else
    size = 1;
#endif
  }
  return enomem(hermetic_malloc_backend_realloc(ptr, size));
}

SHIM_API void *reallocarray(void *ptr, size_t count, size_t size) {
  size_t bytes;
  if (__builtin_mul_overflow(count, size, &bytes)) {
    errno = ENOMEM;
    return NULL;
  }
  return realloc(ptr, bytes);
}

SHIM_API void *aligned_alloc(size_t alignment, size_t size) {
  if (!is_power_of_two(alignment)) {
    errno = EINVAL;
    return NULL;
  }
  return aligned(alignment, size);
}

SHIM_API int posix_memalign(void **result, size_t alignment, size_t size) {
  if (!is_power_of_two(alignment) || alignment % sizeof(void *)) return EINVAL;
  void *p = alignment <= MIN_ALIGN ? hermetic_malloc_backend_malloc(size)
                                   : hermetic_malloc_backend_aligned(alignment, size);
  if (!p) return ENOMEM;
  *result = p;
  return 0;
}

SHIM_API void *memalign(size_t alignment, size_t size) {
  /* glibc rounds an alignment that is not a power of two up to one. */
  if (!is_power_of_two(alignment)) {
    if (alignment > SIZE_MAX / 2 + 1) {
      errno = EINVAL;
      return NULL;
    }
    size_t p = MIN_ALIGN;
    while (p < alignment) p <<= 1;
    alignment = p;
  }
  return aligned(alignment, size);
}

SHIM_API void *valloc(size_t size) { return aligned(page_size(), size); }

SHIM_API void *pvalloc(size_t size) {
  size_t page = page_size();
  size_t rounded = (size + page - 1) & ~(page - 1);
  if (rounded < size) {
    errno = ENOMEM;
    return NULL;
  }
  return aligned(page, rounded ? rounded : page);
}

SHIM_API size_t malloc_usable_size(void *ptr) {
  return ptr ? hermetic_malloc_backend_usable_size(ptr) : 0;
}

#ifdef __GLIBC__
/* glibc also exports its implementation under these names, which some
 * programs call directly; they must not reach glibc's heap either. */
SHIM_API void cfree(void *ptr) { free(ptr); }
SHIM_API void *__libc_malloc(size_t size) { return malloc(size); }
SHIM_API void __libc_free(void *ptr) { free(ptr); }
SHIM_API void *__libc_calloc(size_t count, size_t size) { return calloc(count, size); }
SHIM_API void *__libc_realloc(void *ptr, size_t size) { return realloc(ptr, size); }
SHIM_API void *__libc_memalign(size_t alignment, size_t size) { return memalign(alignment, size); }
SHIM_API void *__libc_valloc(size_t size) { return valloc(size); }
SHIM_API void *__libc_pvalloc(size_t size) { return pvalloc(size); }
SHIM_API int __posix_memalign(void **result, size_t alignment, size_t size) {
  return posix_memalign(result, alignment, size);
}
#endif

#endif
