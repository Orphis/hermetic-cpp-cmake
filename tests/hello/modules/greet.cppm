// A module of the sample's own, importing the standard library and {fmt},
// which is itself built as a module that imports std.
export module greet;
import std;
import fmt;

export namespace greet {
std::string numbers(std::string_view who, int n) {
  std::vector<int> v(n);
  std::iota(v.begin(), v.end(), 1);
  return fmt::format("hello, {}: {}", who, fmt::join(v, ","));
}
}  // namespace greet
