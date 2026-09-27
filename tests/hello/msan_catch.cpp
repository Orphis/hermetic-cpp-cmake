// Built under MemorySanitizer (-fsanitize=memory). The C++ library must be
// instrumented too: otherwise the strings, containers, streams, exceptions
// and demangling below make MSan report values it did not see initialized.
// After them, a genuine read of uninitialized memory must be reported (the
// test expects the report).

#include <cxxabi.h>

#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <typeinfo>
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
  // libc++abi: exceptions and the demangler.
  try {
    throw std::runtime_error(text.str());
  } catch (const std::exception &e) {
    int status = 0;
    char *type = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
    text << ' ' << (status == 0 ? type : "?") << ':' << std::string(e.what()).size();
    std::free(type);
  }
  std::printf("libc++ under MSan: %s OK\n", text.str().c_str());
  std::fflush(stdout);

  std::unique_ptr<int[]> block(new int[4]);  // not initialized
  if (first(block.get()) == 42) {            // MSan reports this branch
    std::puts("forty-two");
  }
  return 0;
}
