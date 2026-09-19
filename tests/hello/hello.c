#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
int main(void) {
  char* s = malloc(32);
  snprintf(s, 32, "%.1f", sqrt(16.0));
  int ok = strcmp(s, "4.0") == 0;
  free(s);
  printf("hello from C: %s\n", ok ? "OK" : "FAIL");
  return ok ? 0 : 1;
}
