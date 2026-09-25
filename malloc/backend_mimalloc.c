/* Copyright 2026 The hermetic-cpp-cmake Authors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HERMETIC_MALLOC=mimalloc: the backend interface on mimalloc's own API.
 * mimalloc is compiled without its override (no MI_MALLOC_OVERRIDE), so it
 * defines mi_* functions only and the shim decides what the C runtime sees.
 */
#include "hermetic_malloc.h"

#include <mimalloc.h>

void *hermetic_malloc_backend_malloc(size_t size) { return mi_malloc(size); }
void *hermetic_malloc_backend_calloc(size_t count, size_t size) { return mi_calloc(count, size); }
void *hermetic_malloc_backend_realloc(void *ptr, size_t size) { return mi_realloc(ptr, size); }
void *hermetic_malloc_backend_aligned(size_t alignment, size_t size) {
  return mi_malloc_aligned(size, alignment);
}
void hermetic_malloc_backend_free(void *ptr) { mi_free(ptr); }
size_t hermetic_malloc_backend_usable_size(const void *ptr) { return mi_usable_size(ptr); }
int hermetic_malloc_backend_owns(const void *ptr) { return mi_is_in_heap_region(ptr); }
/* mimalloc registers no fork handlers on its other platforms either. */
void hermetic_malloc_backend_fork_lock(void) {}
void hermetic_malloc_backend_fork_unlock(void) {}
