#include <bridge.h>

#include "Luau/Ast.h"
#include "Luau/Frontend.h"
#include "Luau/ModuleResolver.h"

#define ZIG_LUAU_ANALYSIS(name) ZIG_FN(Luau_Analysis_##name)

ZIG_EXPORT using FileResolver_readSource = const char* (*)(void* ctx, const char* name, size_t len, size_t* outLen, unsigned char* outType);
ZIG_EXPORT using FileResolver_resolveModule = const char* (*)(void* ctx, const char* name, size_t len, const char* node, size_t nodeLen, size_t* outLen);
ZIG_EXPORT using FileResolver_getHumanReadableModuleName = const char* (*)(void* ctx, const char* name, size_t len, size_t* outLen);
ZIG_EXPORT using FileResolver_freeString = void (*)(void* ctx, const char* str, size_t len);
struct zig_FileResolver : Luau::FileResolver
{
    void* ctx = nullptr;
    FileResolver_readSource c_readSource;
    FileResolver_resolveModule c_resolveModule;
    FileResolver_getHumanReadableModuleName c_getHumanReadableModuleName;
    FileResolver_freeString c_freeString;

    zig_FileResolver(
        void* ctx,
        FileResolver_readSource fn_readSource,
        FileResolver_resolveModule fn_resolveModule,
        FileResolver_getHumanReadableModuleName fn_getHumanReadableModuleName,
        FileResolver_freeString fn_freeString
    )
        : ctx(ctx),
          c_readSource(fn_readSource),
          c_resolveModule(fn_resolveModule),
          c_getHumanReadableModuleName(fn_getHumanReadableModuleName),
          c_freeString(fn_freeString)
    {
    }

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override
    {
        size_t len = 0;
        unsigned char type = 0;
        const char* source = c_readSource(ctx, name.data(), name.size(), &len, &type);
        if (!source)
            return std::nullopt;
    
        Luau::SourceCode::Type sourceType;
        if (type == 0)
        {
            sourceType = Luau::SourceCode::Script;
        }
        else if (type == 1)
        {
            sourceType = Luau::SourceCode::Module;
        }
        else 
        {
            sourceType = Luau::SourceCode::None;
        }

        std::string sourceStr(source, len);
        c_freeString(ctx, source, len);

        return Luau::SourceCode{sourceStr, sourceType};
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo* context, Luau::AstExpr* node) override
    {
        if (Luau::AstExprConstantString* expr = node->as<Luau::AstExprConstantString>())
        {
            std::string path{expr->value.data, expr->value.size};
            size_t len = 0;
            const char* result = c_resolveModule(ctx, context->name.c_str(), context->name.size(), path.c_str(), path.size(), &len);
            if (result)
            {
                std::string resolvedPath(result, len);
                c_freeString(ctx, result, len);
                return {{resolvedPath}};
            }
        }
        return std::nullopt;
    }

    std::string getHumanReadableModuleName(const Luau::ModuleName& name) const override
    {
        size_t len = 0;
        const char* nameStr = c_getHumanReadableModuleName(ctx, name.data(), name.size(), &len);
        std::string result(nameStr, len);
        c_freeString(ctx, nameStr, len);
        return result;
    }
};

ZIG_EXPORT zig_FileResolver* ZIG_LUAU_ANALYSIS(FileResolver_init)(
    void* ctx,
    FileResolver_readSource fn_readSource,
    FileResolver_resolveModule fn_resolveModule,
    FileResolver_getHumanReadableModuleName fn_getHumanReadableModuleName,
    FileResolver_freeString fn_freeString
)
{
    return new zig_FileResolver(
        ctx,
        fn_readSource,
        fn_resolveModule,
        fn_getHumanReadableModuleName,
        fn_freeString
    );
}

ZIG_EXPORT void* ZIG_LUAU_ANALYSIS(FileResolver_dtor)(zig_FileResolver* resolver)
{
    void* ctx = resolver->ctx;
    delete resolver;
    return ctx;
}
