
#ifndef LUAU_HEADERS
#define LUAU_HEADERS

#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#if !defined(__EMSCRIPTEN__) && !defined(__wasm__) && !defined(__wasm32__) && !defined(__wasm64__)
#include "luacodegen.h"
#endif

#define ZIG_EXPORT extern "C"

#define ZIG_FN(name) zig_##name

#endif // LUAU_HEADERS
