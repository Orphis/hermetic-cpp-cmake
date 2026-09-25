#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#if defined(HELLO_MALLOC) && defined(_WIN32) && defined(_DLL)
/* HERMETIC_MALLOC on the DLL runtime: mimalloc.dll, which ucrtbase.dll's
 * allocation functions were redirected to. */
__declspec(dllimport) _Bool mi_is_in_heap_region(const void* ptr);
#define OWNED(p) mi_is_in_heap_region(p)
#elif defined(HELLO_MALLOC)
/* HERMETIC_MALLOC: the program's and the C library's blocks are the backend's. */
int hermetic_malloc_backend_owns(const void* ptr);
#define OWNED(p) hermetic_malloc_backend_owns(p)
#else
#define OWNED(p) 1
#endif
#ifdef _WIN32
#define strdup _strdup
#endif
int main(void) {
  char* s = malloc(32);
  snprintf(s, 32, "%.1f", sqrt(16.0));
  char* d = strdup(s);
  int ok = strcmp(d, "4.0") == 0 && OWNED(s) && OWNED(d);
  free(d);
  free(s);
  printf("hello from C: %s\n", ok ? "OK" : "FAIL");
  return ok ? 0 : 1;
}
