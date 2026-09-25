/* Copyright 2026 The hermetic-cpp-cmake Authors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HERMETIC_MALLOC for Windows targets on the MSVC ABI.
 *
 * Static release runtime (/MT, CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded):
 * the UCRT's own allocations (_strdup, stdio buffers, getcwd, ...) do not go
 * through malloc but through _malloc_base and its siblings, each in an object
 * of its own in libucrt.lib; defining malloc alone would leave them on the
 * CRT heap and hand the program blocks that the backend's free would then
 * receive. So every allocation entry point of libucrt.lib's heap objects is
 * defined here, which keeps the linker from pulling any of them in (msize.obj,
 * recalloc.obj and expand.obj each define two, hence the pairs). The aligned
 * functions (_aligned_malloc, ...) stay the UCRT's: they are built on malloc,
 * free, _msize_base and _expand.
 *
 * Other modules keep their own C runtime: a DLL built with /MT (or /MD)
 * allocates from the process heap. Blocks it hands to the executable are
 * returned there; blocks the executable hands to it must not be freed by it,
 * which is the rule of the static runtime anyway.
 *
 * DLL runtime (/MD, /MDd, CMake's default): the allocator is ucrtbase.dll's,
 * which no definition in the executable replaces. With mimalloc, the
 * executable imports mimalloc.dll instead, first in its import table, whose
 * redirection DLL (mimalloc-redirect.dll) patches ucrtbase.dll's allocation
 * functions when it loads: every module of the process then allocates with
 * mimalloc. Other backends need the static runtime.
 *
 * The debug static runtime (/MTd) keeps its debug heap: its malloc family
 * lives in one object together with the _Crt* debugging interface that
 * programs built with it rely on. The shim is empty there.
 */
/* The project's warning flags (-Werror included) are not this file's concern. */
#if defined(__clang__)
#pragma clang diagnostic ignored "-Weverything"
#elif defined(_MSC_VER)
#pragma warning(push, 0)
#endif

#if !defined(_WIN32)
#error "shim_windows.c is for Windows targets"
#endif

#include "hermetic_malloc.h"
#include "hermetic_malloc_config.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#if !HERMETIC_MALLOC_SANITIZED

#if defined(_DLL)

#if HERMETIC_MALLOC_WINDOWS_REDIRECT
/* The import itself, not the static library's mi_version: mimalloc.dll's
 * import library comes right after the static library on the link line. */
#pragma comment(linker, "/include:__imp_mi_version")
#else
#error "HERMETIC_MALLOC with a backend of the project needs the static C runtime on Windows targets: set CMAKE_MSVC_RUNTIME_LIBRARY (or the MSVC_RUNTIME_LIBRARY property) to MultiThreaded, or set the HERMETIC_MALLOC target property to OFF for this executable. The DLL runtime (ucrtbase.dll) keeps its own heap; only mimalloc redirects it."
#endif

#elif !defined(_DEBUG)

static void *enomem(void *p) {
  if (!p) errno = ENOMEM;
  return p;
}

/* Blocks the backend does not own come from the process heap, which is the
 * UCRT's heap: a DLL with a C runtime of its own (static or ucrtbase.dll)
 * allocated them and handed them over. They go back there. */
static int foreign(const void *ptr) { return !hermetic_malloc_backend_owns(ptr); }

void *_malloc_base(size_t size) { return enomem(hermetic_malloc_backend_malloc(size)); }
void *malloc(size_t size) { return _malloc_base(size); }

void _free_base(void *ptr) {
  if (!ptr) return;
  if (foreign(ptr)) {
    HeapFree(GetProcessHeap(), 0, ptr);
    return;
  }
  hermetic_malloc_backend_free(ptr);
}
void free(void *ptr) { _free_base(ptr); }

void *_calloc_base(size_t count, size_t size) {
  return enomem(hermetic_malloc_backend_calloc(count, size));
}
void *calloc(size_t count, size_t size) { return _calloc_base(count, size); }

size_t _msize_base(void *ptr) {
  if (!ptr) {
    errno = EINVAL;
    return (size_t)-1;
  }
  if (foreign(ptr)) return HeapSize(GetProcessHeap(), 0, ptr);
  return hermetic_malloc_backend_usable_size(ptr);
}
size_t _msize(void *ptr) { return _msize_base(ptr); }

void *_realloc_base(void *ptr, size_t size) {
  if (!ptr) return _malloc_base(size);
  if (!size) {
    /* As the UCRT does: free, and return null. */
    _free_base(ptr);
    return NULL;
  }
  if (!foreign(ptr)) return enomem(hermetic_malloc_backend_realloc(ptr, size));
  /* Moves a foreign block into the backend. */
  size_t old = HeapSize(GetProcessHeap(), 0, ptr);
  void *result = _malloc_base(size);
  if (result) {
    memcpy(result, ptr, old < size ? old : size);
    HeapFree(GetProcessHeap(), 0, ptr);
  }
  return result;
}
void *realloc(void *ptr, size_t size) { return _realloc_base(ptr, size); }

/* Grows the block and clears what lies beyond its old size. */
void *_recalloc_base(void *ptr, size_t count, size_t size) {
  if (size && count > SIZE_MAX / size) {
    errno = ENOMEM;
    return NULL;
  }
  size_t bytes = count * size;
  size_t old = ptr ? _msize_base(ptr) : 0;
  char *result = _realloc_base(ptr, bytes);
  if (result && bytes > old) memset(result + old, 0, bytes - old);
  return result;
}
void *_recalloc(void *ptr, size_t count, size_t size) { return _recalloc_base(ptr, count, size); }

/* Resizing in place: always possible within the block's usable size, never
 * beyond it (null is the documented answer then). */
void *_expand_base(void *ptr, size_t size) {
  if (!ptr) {
    errno = EINVAL;
    return NULL;
  }
  if (foreign(ptr)) return enomem(HeapReAlloc(GetProcessHeap(), HEAP_REALLOC_IN_PLACE_ONLY, ptr, size));
  if (size > hermetic_malloc_backend_usable_size(ptr)) {
    errno = ENOMEM;
    return NULL;
  }
  return ptr;
}
void *_expand(void *ptr, size_t size) { return _expand_base(ptr, size); }

#endif

#endif
