#include <bridge.h>

#include "luacode.h"

#include "Luau/Common.h"

#include "Luau/Parser.h"
#include "Luau/BytecodeBuilder.h"
#include "Luau/Compiler.h"
#include "Luau/TimeTrace.h"

#define ZIG_LUAU_COMPILER(name) ZIG_FN(Luau_Compiler_##name)

const char* outputBytes(const std::string& result, size_t* len)
{
    char* copy = static_cast<char*>(malloc(result.size()));
    if (!copy)
        return nullptr;

    memcpy(copy, result.data(), result.size());
    *len = result.size();
    return copy;
}

ZIG_EXPORT const char* ZIG_LUAU_COMPILER(compile_ParseResult)(
    const Luau::ParseResult* result,
    const Luau::AstNameTable* names,
    size_t* len,
    lua_CompileOptions* options,
    Luau::BytecodeEncoder* encoder = nullptr
) {
    Luau::CompileOptions opts;

    if (options)
    {
        static_assert(sizeof(lua_CompileOptions) == sizeof(Luau::CompileOptions), "C and C++ interface must match");
        memcpy(static_cast<void*>(&opts), options, sizeof(opts));
    }

    LUAU_TIMETRACE_SCOPE("compile", "Compiler");

    if (!result->errors.empty())
    {
        // Users of this function expect only a single error message
        const Luau::ParseError& parseError = result->errors.front();
        std::string error = Luau::format(":%d: %s", parseError.getLocation().begin.line + 1, parseError.what());

        return outputBytes(Luau::BytecodeBuilder::getError(error), len);
    }

    try
    {
        Luau::BytecodeBuilder bcb(encoder);
        Luau::compileOrThrow(bcb, *result, *names, opts);

        return outputBytes(bcb.getBytecode(), len);
    }
    catch (Luau::CompileError& e)
    {
        std::string error = Luau::format(":%d: %s", e.getLocation().begin.line + 1, e.what());
        return outputBytes(Luau::BytecodeBuilder::getError(error), len);
    }
}

ZIG_EXPORT void ZIG_LUAU_COMPILER(compile_free)(void *ptr)
{
    free(ptr);
}
