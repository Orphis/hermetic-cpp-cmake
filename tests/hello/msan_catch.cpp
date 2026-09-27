// Built under MemorySanitizer (-fsanitize=memory). The C++ library must be
// instrumented too: otherwise the strings, containers and streams below make
// MSan report values it did not see initialized. After them, a genuine read
// of uninitialized memory must be reported (the test expects the report).

#include <cstdio>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

// Out of line, so the optimizer keeps the load it is about.
__attribute__((noinline)) static int first(const int *p) { return *p; }

int main() {
  std::map<std::string, std::vector<int>> groups;
  for (int i = 0; i < 20; ++i) {
    groups["group " + std::to_string(i % 3)].push_back(i);
  }
  std::ostringstream text;
  for (const auto &[name, values] : groups) {
    text << name << '=' << values.size() << ';';
  }
  std::printf("libc++ under MSan: %s OK\n", text.str().c_str());
  std::fflush(stdout);

  std::unique_ptr<int[]> block(new int[4]);  // not initialized
  if (first(block.get()) == 42) {            // MSan reports this branch
    std::puts("forty-two");
  }
  return 0;
}
