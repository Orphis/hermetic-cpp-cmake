#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#ifdef HELLO_MALLOC
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
