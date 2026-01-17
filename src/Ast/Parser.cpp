#include <bridge.h>

#include "Luau/Ast.h"
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
    const luau_ParseOptions* options
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

ZIG_EXPORT Luau::ParseNodeResult<Luau::AstExpr>* ZIG_LUAU_AST(Parser_parseExpr)(
    const char* source, size_t sourceLen,
    Luau::AstNameTable* names,
    Luau::Allocator* allocator,
    const luau_ParseOptions* options
)
{
    Luau::ParseOptions parseOptions;
    if (options)
    {
        static_assert(sizeof(luau_ParseOptions) == sizeof(Luau::ParseOptions), "C and C++ interface must match");
        memcpy(static_cast<void*>(&parseOptions), options, sizeof(parseOptions));
    }
    Luau::ParseNodeResult<Luau::AstExpr> result = Luau::Parser::parseExpr(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseNodeResult<Luau::AstExpr>(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseNodeResult_AstExpr_dtor)(Luau::ParseNodeResult<Luau::AstExpr>* result)
{
    delete result;
}


ZIG_EXPORT Luau::ParseNodeResult<Luau::AstType>* ZIG_LUAU_AST(Parser_parseType)(
    const char* source, size_t sourceLen,
    Luau::AstNameTable* names,
    Luau::Allocator* allocator,
    const luau_ParseOptions* options
)
{
    Luau::ParseOptions parseOptions;
    if (options)
    {
        static_assert(sizeof(luau_ParseOptions) == sizeof(Luau::ParseOptions), "C and C++ interface must match");
        memcpy(static_cast<void*>(&parseOptions), options, sizeof(parseOptions));
    }
    Luau::ParseNodeResult<Luau::AstType> result = Luau::Parser::parseType(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseNodeResult<Luau::AstType>(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseNodeResult_AstType_dtor)(Luau::ParseNodeResult<Luau::AstType>* result)
{
    delete result;
}
