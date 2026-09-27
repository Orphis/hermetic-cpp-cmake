// Built with a sanitizer (SAN_CATCH_* names which). First, correct code
// through the C++ library, threads included, which must not be reported:
// strings, containers, streams, exceptions, demangling, mutexes, condition
// variables, futures and shared pointers across threads. Then one genuine bug
// of the kind the sanitizer finds, whose report the tests expect: the program
// prints what that report must contain first.

#include <cxxabi.h>

#include <atomic>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <vector>

#if defined(SAN_CATCH_MEMORY)
static const char *const kind = "MemorySanitizer", *const expected = "use-of-uninitialized-value";
#elif defined(SAN_CATCH_THREAD)
static const char *const kind = "ThreadSanitizer", *const expected = "data race";
#elif defined(SAN_CATCH_ADDRESS)
static const char *const kind = "AddressSanitizer", *const expected = "heap-buffer-overflow";
#elif defined(SAN_CATCH_HWADDRESS)
static const char *const kind = "HWAddressSanitizer", *const expected = "tag-mismatch";
#elif defined(SAN_CATCH_UNDEFINED)
static const char *const kind = "UndefinedBehaviorSanitizer", *const expected = "signed integer overflow";
#else
#error "SAN_CATCH_<kind> is required"
#endif

thread_local std::string tls = "tls";

static std::string correct_code() {
  std::map<std::string, std::vector<int>> groups;
  for (int i = 0; i < 20; ++i) {
    groups["group " + std::to_string(i % 3)].push_back(i);
  }
  std::ostringstream text;
  for (const auto &[name, values] : groups) {
    text << name << '=' << values.size() << ';';
  }
  // libc++abi: exceptions (thrown in another thread too) and the demangler.
  try {
    throw std::runtime_error(text.str());
  } catch (const std::exception &e) {
    int status = 0;
    char *type = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
    text << ' ' << (status == 0 ? type : "?") << ':' << std::string(e.what()).size();
    std::free(type);
  }
  std::exception_ptr thrown;
  std::thread([&] {
    try { throw std::logic_error("elsewhere"); } catch (...) { thrown = std::current_exception(); }
  }).join();
  try { std::rethrow_exception(thrown); } catch (const std::logic_error &e) { text << ' ' << e.what(); }
  // Threads synchronized through the library.
  std::mutex m;
  int counter = 0;
  auto shared = std::make_shared<std::string>(tls);
  std::vector<std::thread> workers;
  for (int i = 0; i < 4; ++i) {
    workers.emplace_back([&, shared] {
      for (int j = 0; j < 100; ++j) { std::lock_guard<std::mutex> lock(m); counter += (int)shared->size(); }
    });
  }
  for (auto &w : workers) w.join();
  std::condition_variable cv;
  bool ready = false;
  std::thread waiter([&] { std::unique_lock<std::mutex> lock(m); cv.wait(lock, [&] { return ready; }); });
  { std::lock_guard<std::mutex> lock(m); ready = true; }
  cv.notify_one();
  waiter.join();
  std::atomic<int> flag{0};
  auto answer = std::async(std::launch::async, [&] { flag.store(1, std::memory_order_release); return 42; });
  text << " threads:" << counter << ',' << answer.get() + flag.load(std::memory_order_acquire);
  return text.str();
}

// Out of line, so the optimizer keeps the access it is about.
__attribute__((noinline)) static int first(const int *p) { return *p; }
__attribute__((noinline)) static void store(char *p, int i) { p[i] = 1; }
static int racy;

int main(int argc, char **) {
  std::printf("%s expects: %s\n", kind, expected);
  std::printf("libc++ under %s: %s OK\n", kind, correct_code().c_str());
  std::fflush(stdout);
#if defined(SAN_CATCH_MEMORY)
  std::unique_ptr<int[]> block(new int[4]);  // not initialized
  if (first(block.get()) == 42) std::puts("forty-two");
#elif defined(SAN_CATCH_THREAD)
  std::thread a([] { for (int i = 0; i < 1000; ++i) ++racy; });
  std::thread b([] { for (int i = 0; i < 1000; ++i) ++racy; });
  a.join();
  b.join();
  std::printf("%d\n", racy);
#elif defined(SAN_CATCH_ADDRESS) || defined(SAN_CATCH_HWADDRESS)
  std::unique_ptr<char[]> block(new char[16]);
  store(block.get(), 15 + argc);  // one past the end
#elif defined(SAN_CATCH_UNDEFINED)
  volatile int big = INT_MAX;
  std::printf("%d\n", big + argc);
#endif
  (void)first; (void)store; (void)racy;
  return 0;
}
