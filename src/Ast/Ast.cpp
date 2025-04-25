#include <bridge.h>

#include "Luau/Parser.h"
#include "Luau/Lexer.h"

#define ZIG_LUAU_AST(name) ZIG_FN(Luau_Ast_##name)

ZIG_EXPORT Luau::Allocator* ZIG_LUAU_AST(Allocator_init)()
{
    return new Luau::Allocator();
}

ZIG_EXPORT void ZIG_LUAU_AST(Allocator_dtor)(Luau::Allocator* allocator)
{
    delete allocator;
}

ZIG_EXPORT Luau::AstNameTable* ZIG_LUAU_AST(Lexer_AstNameTable_init)(Luau::Allocator* allocator)
{
    return new Luau::AstNameTable(*allocator);
}

ZIG_EXPORT void ZIG_LUAU_AST(Lexer_AstNameTable_dtor)(Luau::AstNameTable* names)
{
    delete names;
}

ZIG_EXPORT Luau::ParseResult* ZIG_LUAU_AST(Parser_parse)(const char* source, size_t sourceLen, Luau::AstNameTable* names, Luau::Allocator* allocator)
{
    Luau::ParseOptions parseOptions;
    Luau::ParseResult result = Luau::Parser::parse(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseResult(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseResult_dtor)(Luau::ParseResult* result)
{
    delete result;
}

ZIG_EXPORT Luau::ParseExprResult* ZIG_LUAU_AST(Parser_parseExpr)(const char* source, size_t sourceLen, Luau::AstNameTable* names, Luau::Allocator* allocator)
{
    Luau::ParseOptions parseOptions;
    Luau::ParseExprResult result = Luau::Parser::parseExpr(source, sourceLen, *names, *allocator, parseOptions);
    return new Luau::ParseExprResult(std::move(result));
}

ZIG_EXPORT void ZIG_LUAU_AST(ParseExprResult_dtor)(Luau::ParseExprResult* result)
{
    delete result;
}
