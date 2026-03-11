#ifndef LUAU_HEADERS
#define LUAU_HEADERS

#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#if (defined(__x86_64__) || defined(__amd64__) || defined(__aarch64__) || defined(__arm64__) || defined(__ARM64__)) && !defined(__BIG_ENDIAN__)
#include "luacodegen.h"
#endif

#define ZIG_EXPORT extern "C"

#define ZIG_FN(name) zig_##name

#endif // LUAU_HEADERS
