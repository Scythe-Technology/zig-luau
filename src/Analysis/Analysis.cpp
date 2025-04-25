#include <bridge.h>

#include "Luau/Ast.h"
#include "Luau/AstJsonEncoder.h"

#define ZIG_LUAU_ANALYSIS(name) ZIG_FN(Luau_Analysis_##name)

ZIG_EXPORT const char* ZIG_LUAU_ANALYSIS(AstJsonEncoder_toJson)(Luau::AstNode* node, size_t* len)
{
    std::string res = Luau::toJson(node);

    char* copy = static_cast<char*>(malloc(res.size()));
    if (!copy)
        return nullptr;

    memcpy(copy, res.data(), res.size());
    *len = res.size();
    return copy;
}

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(AstJsonEncoder_free)(const char* json)
{
    free((void*)json);
}