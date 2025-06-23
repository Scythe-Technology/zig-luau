#include <bridge.h>

#include "Luau/Allocator.h"

#define ZIG_LUAU_AST(name) ZIG_FN(Luau_Ast_##name)

ZIG_EXPORT Luau::Allocator* ZIG_LUAU_AST(Allocator_init)()
{
    return new Luau::Allocator();
}

ZIG_EXPORT void ZIG_LUAU_AST(Allocator_dtor)(Luau::Allocator* allocator)
{
    delete allocator;
}
