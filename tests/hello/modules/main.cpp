import std;
import greet;

int main() {
  auto s = greet::numbers("modules", 3);
  std::map<std::string, int> m{{"a", 1}};
  bool ok = s == "hello, modules: 1,2,3" && m.at("a") == 1;
  std::println("{} (import std): {}", s, ok ? "OK" : "FAIL");
  return ok ? 0 : 1;
}
