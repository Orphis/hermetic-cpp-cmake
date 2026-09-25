/* Copyright 2026 The hermetic-cpp-cmake Authors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HERMETIC_MALLOC for macOS targets: a malloc zone backed by the backend,
 * made the default zone before main.
 *
 * Defining malloc in the executable would only reach the executable's own
 * calls: libSystem (strdup, stdio, ...), the SDK's libc++.dylib (operator
 * new) and every other image bind to libsystem_malloc through the two-level
 * namespace, and keep allocating from the system zone. Their malloc() goes
 * to the default zone though, which is the first registered one, so this zone
 * is registered and the others are registered again behind it, as mimalloc
 * and gperftools do. free() and realloc() look up the zone that owns a block
 * (zone->size() is non-zero for it), so blocks allocated before the switch
 * still go back to the system zone.
 */
/* The project's warning flags (-Werror included) are not this file's concern. */
#if defined(__clang__)
#pragma clang diagnostic ignored "-Weverything"
#elif defined(_MSC_VER)
#pragma warning(push, 0)
#endif

#include "hermetic_malloc.h"

#include <errno.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <string.h>

#if !defined(__APPLE__)
#error "shim_darwin.c is for macOS targets"
#endif

#if !HERMETIC_MALLOC_SANITIZED

static size_t zone_size(malloc_zone_t *zone, const void *ptr) {
  (void)zone;
  return hermetic_malloc_backend_owns(ptr) ? hermetic_malloc_backend_usable_size(ptr) : 0;
}

static void *enomem(void *p) {
  if (!p) errno = ENOMEM;
  return p;
}

static void *zone_malloc(malloc_zone_t *zone, size_t size) {
  (void)zone;
  return enomem(hermetic_malloc_backend_malloc(size));
}

static void *zone_calloc(malloc_zone_t *zone, size_t count, size_t size) {
  (void)zone;
  return enomem(hermetic_malloc_backend_calloc(count, size));
}

static void *zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size) {
  (void)zone;
  if (alignment <= 16) return enomem(hermetic_malloc_backend_malloc(size));
  return enomem(hermetic_malloc_backend_aligned(alignment, size));
}

static void *zone_valloc(malloc_zone_t *zone, size_t size) {
  return zone_memalign(zone, vm_page_size, size);
}

static void zone_free(malloc_zone_t *zone, void *ptr) {
  (void)zone;
  if (ptr) hermetic_malloc_backend_free(ptr);
}

static void zone_free_definite_size(malloc_zone_t *zone, void *ptr, size_t size) {
  (void)size;
  zone_free(zone, ptr);
}

static void *zone_realloc(malloc_zone_t *zone, void *ptr, size_t size) {
  if (!ptr) return zone_malloc(zone, size);
  return enomem(hermetic_malloc_backend_realloc(ptr, size ? size : 1));
}

static void zone_destroy(malloc_zone_t *zone) { (void)zone; }

static unsigned zone_batch_malloc(malloc_zone_t *zone, size_t size, void **results, unsigned count) {
  unsigned i = 0;
  for (; i < count; i++) {
    if (!(results[i] = zone_malloc(zone, size))) break;
  }
  return i;
}

static void zone_batch_free(malloc_zone_t *zone, void **ptrs, unsigned count) {
  for (unsigned i = 0; i < count; i++) zone_free(zone, ptrs[i]);
}

static size_t zone_pressure_relief(malloc_zone_t *zone, size_t goal) {
  (void)zone;
  (void)goal;
  return 0;
}

static boolean_t zone_claimed_address(malloc_zone_t *zone, void *ptr) {
  (void)zone;
  return hermetic_malloc_backend_owns(ptr);
}

/* The introspection interface serves heap tools (leaks, vmmap, heap), which
 * do not see into the backend, and fork(): libSystem locks every zone before
 * forking and unlocks it on both sides afterwards. */
static kern_return_t intro_enumerator(task_t task, void *context, unsigned type, vm_address_t zone,
                                      memory_reader_t reader, vm_range_recorder_t recorder) {
  (void)task, (void)context, (void)type, (void)zone, (void)reader, (void)recorder;
  return KERN_SUCCESS;
}
static size_t intro_good_size(malloc_zone_t *zone, size_t size) {
  (void)zone;
  return size;
}
static boolean_t intro_check(malloc_zone_t *zone) {
  (void)zone;
  return 1;
}
static void intro_print(malloc_zone_t *zone, boolean_t verbose) { (void)zone, (void)verbose; }
static void intro_log(malloc_zone_t *zone, void *address) { (void)zone, (void)address; }
static void intro_force_lock(malloc_zone_t *zone) {
  (void)zone;
  hermetic_malloc_backend_fork_lock();
}
static void intro_force_unlock(malloc_zone_t *zone) {
  (void)zone;
  hermetic_malloc_backend_fork_unlock();
}
static void intro_statistics(malloc_zone_t *zone, malloc_statistics_t *stats) {
  (void)zone;
  memset(stats, 0, sizeof *stats);
}
static boolean_t intro_zone_locked(malloc_zone_t *zone) {
  (void)zone;
  return 0;
}

static malloc_introspection_t introspection = {
    .enumerator = intro_enumerator,
    .good_size = intro_good_size,
    .check = intro_check,
    .print = intro_print,
    .log = intro_log,
    .force_lock = intro_force_lock,
    .force_unlock = intro_force_unlock,
    .statistics = intro_statistics,
    .zone_locked = intro_zone_locked,
    .reinit_lock = intro_force_unlock,
};

static malloc_zone_t zone = {
    .size = zone_size,
    .malloc = zone_malloc,
    .calloc = zone_calloc,
    .valloc = zone_valloc,
    .free = zone_free,
    .realloc = zone_realloc,
    .destroy = zone_destroy,
    .zone_name = "hermetic-malloc",
    .batch_malloc = zone_batch_malloc,
    .batch_free = zone_batch_free,
    .introspect = &introspection,
    .version = 10,
    .memalign = zone_memalign,
    .free_definite_size = zone_free_definite_size,
    .pressure_relief = zone_pressure_relief,
    .claimed_address = zone_claimed_address,
};

static malloc_zone_t *first_zone(void) {
  vm_address_t *zones = NULL;
  unsigned count = 0;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS || !count) {
    return malloc_default_zone();
  }
  return (malloc_zone_t *)zones[0];
}

/* Priority 101, the first one available to programs: before other
 * constructors allocate. */
__attribute__((constructor(101), used)) static void hermetic_malloc_install_zone(void) {
  /* The purgeable zone is created on first use, and registering it later
   * would put it in front of ours again. */
  malloc_zone_t *purgeable = malloc_default_purgeable_zone();
  malloc_zone_register(&zone);
  for (int attempt = 0; attempt < 16; attempt++) {
    malloc_zone_t *first = first_zone();
    if (first == &zone) return;
    malloc_zone_unregister(first);
    malloc_zone_register(first);
    if (purgeable && purgeable != first) {
      malloc_zone_unregister(purgeable);
      malloc_zone_register(purgeable);
    }
  }
}

#endif
