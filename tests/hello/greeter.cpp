#include "greeter.h"
#include <sstream>
std::string greet(const std::string& who) {
  std::ostringstream os;
  os << "hello, " << who;
  return os.str();
}
