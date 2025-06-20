#include <bridge.h>

#include "Luau/Parser.h"

#define ZIG_LUAU_AST(name) ZIG_FN(Luau_Ast_##name)

ZIG_EXPORT struct luau_ParseOptions
{
    unsigned char data[sizeof(Luau::ParseOptions)];
};

ZIG_EXPORT Luau::ParseResult* ZIG_LUAU_AST(Parser_parse)(
    const char* source, size_t sourceLen,
    Luau::AstNameTable* names,
    Luau::Allocator* allocator,
    luau_ParseOptions* options
)
{
    Luau::ParseOptions parseOptions;
    if (options)
    {
        static_assert(sizeof(luau_ParseOptions) == sizeof(Luau::ParseOptions), "C and C++ interface must match");
        memcpy(static_cast<void*>(&parseOptions), options, sizeof(parseOptions));
    }
    Luau::ParseResult result = Luau::Parser::parse(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseResult(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseResult_dtor)(Luau::ParseResult* result)
{
    delete result;
}

ZIG_EXPORT Luau::ParseExprResult* ZIG_LUAU_AST(Parser_parseExpr)(
    const char* source, size_t sourceLen,
    Luau::AstNameTable* names,
    Luau::Allocator* allocator,
    luau_ParseOptions* options
)
{
    Luau::ParseOptions parseOptions;
    if (options)
    {
        static_assert(sizeof(luau_ParseOptions) == sizeof(Luau::ParseOptions), "C and C++ interface must match");
        memcpy(static_cast<void*>(&parseOptions), options, sizeof(parseOptions));
    }
    Luau::ParseExprResult result = Luau::Parser::parseExpr(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseExprResult(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseExprResult_dtor)(Luau::ParseExprResult* result)
{
    delete result;
}
