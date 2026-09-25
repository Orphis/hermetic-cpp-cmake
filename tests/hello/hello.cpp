#include "greeter.h"
#include <atomic>
#include <cstdio>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

// The compiler's own description: clang's __VERSION__, or cl.exe's version.
#define HELLO_STR_(x) #x
#define HELLO_STR(x) HELLO_STR_(x)
#if defined(__VERSION__)
#define HELLO_COMPILER __VERSION__
#elif defined(_MSC_FULL_VER)
#define HELLO_COMPILER "MSVC " HELLO_STR(_MSC_FULL_VER)
#else
#define HELLO_COMPILER "unknown compiler"
#endif

namespace {
int throwing(int x) {
  if (x > 2) throw std::runtime_error("too big");
  return x * 2;
}
}  // namespace

int main() {
  std::atomic<int> counter{0};
  std::mutex m;
  std::map<std::string, int> seen;
  std::vector<std::thread> threads;
  for (int i = 0; i < 4; ++i) {
    threads.emplace_back([&, i] {
      std::lock_guard<std::mutex> lock(m);
      seen[greet("thread " + std::to_string(i))] = i;
      counter += i;
    });
  }
  for (auto& t : threads) t.join();

  int caught = 0;
  for (int i = 0; i < 5; ++i) {
    try {
      counter += throwing(i);
    } catch (const std::exception& e) {
      ++caught;
    }
  }
  auto p = std::make_unique<std::string>(greet("world"));
  bool ok = counter == 6 + 0 + 2 + 4 && caught == 2 && seen.size() == 4 && *p == "hello, world";
  std::cout << *p << " (" << HELLO_COMPILER << "): " << (ok ? "OK" : "FAIL") << std::endl;
  return ok ? 0 : 1;
}
