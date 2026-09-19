#pragma once
#include <string>
#if defined(_WIN32) && defined(GREETER_BUILDING)
#define GREETER_API __declspec(dllexport)
#elif defined(_WIN32) && !defined(GREETER_STATIC)
#define GREETER_API __declspec(dllimport)
#else
#define GREETER_API
#endif
GREETER_API std::string greet(const std::string& who);
