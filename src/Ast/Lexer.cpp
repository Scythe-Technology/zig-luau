#include <bridge.h>

#include "Luau/Lexer.h"

#define ZIG_LUAU_AST(name) ZIG_FN(Luau_Ast_##name)

ZIG_EXPORT Luau::AstNameTable* ZIG_LUAU_AST(Lexer_AstNameTable_init)(Luau::Allocator* allocator)
{
    return new Luau::AstNameTable(*allocator);
}

ZIG_EXPORT void ZIG_LUAU_AST(Lexer_AstNameTable_dtor)(Luau::AstNameTable* names)
{
    delete names;
}
