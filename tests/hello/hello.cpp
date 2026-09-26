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

#ifdef HELLO_MALLOC
// HERMETIC_MALLOC: blocks come from the backend, the greeter library's too
// (with the static runtime on Windows a DLL keeps its own C runtime heap,
// which the executable's free returns its blocks to).
#if defined(_WIN32) && (defined(_DLL) || defined(__MINGW32__))
extern "C" __declspec(dllimport) bool mi_is_in_heap_region(const void* ptr);
static bool owned(const void* ptr) { return mi_is_in_heap_region(ptr); }
#else
extern "C" int hermetic_malloc_backend_owns(const void* ptr);
static bool owned(const void* ptr) { return hermetic_malloc_backend_owns(ptr); }
#endif
static bool allocator_ok() {
  auto n = std::make_unique<int>(1);
  std::string s = greet(std::string(64, 'x'));
  bool ok = owned(n.get());
#if !defined(_WIN32) || defined(_DLL) || defined(__MINGW32__) || defined(GREETER_STATIC)
  ok = ok && owned(s.data());
#endif
  return ok;
}
#else
static bool allocator_ok() { return true; }
#endif

namespace {
// A thread_local object with a destructor: registered through
// __cxa_thread_atexit, which musl's runtime sets once failed to link.
struct PerThread {
  std::string name = "unset";
  ~PerThread() { name.clear(); }
};
thread_local PerThread per_thread;

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
      per_thread.name = "thread " + std::to_string(i);
      seen[greet(per_thread.name)] = i;
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
  bool ok = counter == 6 + 0 + 2 + 4 && caught == 2 && seen.size() == 4 && *p == "hello, world" &&
            allocator_ok();
  std::cout << *p << " (" << HELLO_COMPILER << "): " << (ok ? "OK" : "FAIL") << std::endl;
  return ok ? 0 : 1;
}
