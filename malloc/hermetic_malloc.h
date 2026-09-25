/* Copyright 2026 The hermetic-cpp-cmake Authors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The allocator backend interface of HERMETIC_MALLOC. The toolchain's shim
 * (shim_elf.c, shim_darwin.c, shim_windows.c) owns everything the target's C
 * runtime needs replaced, and forwards to these functions; a backend (mimalloc,
 * tcmalloc, or a project's own) only implements them, without overriding
 * anything itself.
 *
 *   malloc          like malloc; size 0 returns a unique pointer.
 *   calloc          like calloc, including the overflow check.
 *   realloc         like realloc, with a non-null pointer and a non-zero size.
 *   aligned         a block aligned to ALIGNMENT, a power of two of at least
 *                   sizeof(void *); SIZE need not be a multiple of it.
 *   free            like free; never called with a null pointer.
 *   usable_size     the usable size of a block of this backend.
 *   owns            whether the pointer is a block of this backend, for any
 *                   pointer. The macOS and Windows shims call it: free() there
 *                   also receives blocks of the system heap (allocated before
 *                   the backend was installed, or by another module).
 *   fork_lock       take every lock of the backend before fork(), and release
 *   fork_unlock     them in the parent and the child afterwards. Only the macOS
 *                   shim calls them (libSystem does so for every malloc zone);
 *                   elsewhere a backend registers pthread_atfork itself if it
 *                   needs to. Empty for a backend without locks.
 *
 * Failed allocations may leave errno alone: the shim sets ENOMEM.
 */
#ifndef HERMETIC_MALLOC_H
#define HERMETIC_MALLOC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *hermetic_malloc_backend_malloc(size_t size);
void *hermetic_malloc_backend_calloc(size_t count, size_t size);
void *hermetic_malloc_backend_realloc(void *ptr, size_t size);
void *hermetic_malloc_backend_aligned(size_t alignment, size_t size);
void hermetic_malloc_backend_free(void *ptr);
size_t hermetic_malloc_backend_usable_size(const void *ptr);
int hermetic_malloc_backend_owns(const void *ptr);
void hermetic_malloc_backend_fork_lock(void);
void hermetic_malloc_backend_fork_unlock(void);

#ifdef __cplusplus
}
#endif

/* The shims define nothing in translation units built with a sanitizer that
 * brings its own allocator: its runtime intercepts malloc already. */
#if defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(hwaddress_sanitizer) || \
    __has_feature(memory_sanitizer) || __has_feature(thread_sanitizer)
#define HERMETIC_MALLOC_SANITIZED 1
#endif
#endif
#if !defined(HERMETIC_MALLOC_SANITIZED) && defined(__SANITIZE_ADDRESS__)
#define HERMETIC_MALLOC_SANITIZED 1
#endif
#if !defined(HERMETIC_MALLOC_SANITIZED)
#define HERMETIC_MALLOC_SANITIZED 0
#endif

#endif
