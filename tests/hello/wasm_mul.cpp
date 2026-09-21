// C++ without a standard library: templates and classes still work.
template <typename T>
struct Multiplier {
  T factor;
  constexpr T operator()(T value) const { return value * factor; }
};

extern "C" __attribute__((export_name("mul"))) int mul(int a, int b) {
  return Multiplier<int>{a}(b);
}
