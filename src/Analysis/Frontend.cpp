#include <bridge.h>

#include "Luau/Frontend.h"
#include "Luau/BuiltinDefinitions.h"

#define ZIG_LUAU_ANALYSIS(name) ZIG_FN(Luau_Analysis_##name)

ZIG_EXPORT struct luau_FrontendOptions
{
    // When true, we retain full type information about every term in the AST.
    // Setting this to false cuts back on RAM and is a good idea for batch
    // jobs where the type graph is not deeply inspected after typechecking
    // is complete.
    bool retainFullTypeGraphs = false;

    // Run typechecking only in mode required for autocomplete (strict mode in
    // order to get more precise type information)
    bool forAutocomplete = false;

    bool runLintChecks = false;

    // When true, some internal complexity limits will be scaled down for modules that miss the limit set by moduleTimeLimitSec
    bool applyInternalLimitScaling = false;
};

ZIG_EXPORT Luau::Frontend* ZIG_LUAU_ANALYSIS(Frontend_init)(Luau::FileResolver* fileResolver, Luau::ConfigResolver* configResolver, luau_FrontendOptions options)
{
    Luau::FrontendOptions frontendOptions;
    frontendOptions.retainFullTypeGraphs = options.retainFullTypeGraphs;
    frontendOptions.runLintChecks = options.runLintChecks;
    frontendOptions.forAutocomplete = options.forAutocomplete;
    frontendOptions.applyInternalLimitScaling = options.applyInternalLimitScaling;
    
    return new Luau::Frontend(fileResolver, configResolver, frontendOptions);
}

ZIG_EXPORT using Frontend_loadDefinitionError = bool (*)(void* ctx, const char* str, size_t len, Luau::Location location);
ZIG_EXPORT bool ZIG_LUAU_ANALYSIS(Frontend_loadDefinitionFile)(
    Luau::Frontend* frontend,
    const char* src,
    size_t srcLen,
    const char* packagename,
    bool captureComments,
    bool typeCheckForAutocomplete,
    void* ctx,
    Frontend_loadDefinitionError fn_loadDefinitionError
)
{
    std::string source(src, srcLen);
    std::string packageName(packagename);
    Luau::LoadDefinitionFileResult result = frontend->loadDefinitionFile(frontend->globals, frontend->globals.globalScope, source, packageName, captureComments, typeCheckForAutocomplete);
    if (!result.success)
    {
        if (fn_loadDefinitionError)
        {
            if (result.parseResult.errors.size() > 0){
                Luau::ParseError error = result.parseResult.errors.front();
                std::string msg = error.getMessage();
                Luau::Location location = error.getLocation();
                fn_loadDefinitionError(ctx, msg.c_str(), msg.size(), location);
            } else if (result.module->errors.size() > 0) {
                Luau::TypeError error = result.module->errors.front();
                std::string msg = "<type error>";
                Luau::Location location = error.location;
                fn_loadDefinitionError(ctx, msg.c_str(), msg.size(), location);
            }
        }
    }
    return result.success;
}

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(Frontend_registerBuiltinGlobals)(Luau::Frontend& frontend)
{
    Luau::registerBuiltinGlobals(frontend, frontend.globals);
}

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(Frontend_freeze)(Luau::Frontend* frontend)
{
    Luau::freeze(frontend->globals.globalTypes);
}

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(Frontend_queueModuleCheck)(Luau::Frontend* frontend, const char* path, size_t pathLen)
{
    std::string modulePath(path, pathLen);
    frontend->queueModuleCheck(modulePath);
}

ZIG_EXPORT using Frontend_checkedModule = bool (*)(void* ctx, const char* str, size_t len);
ZIG_EXPORT using Frontend_checkedModuleError = void (*)(
    void* ctx,
    const char* moduleName,
    size_t moduleNameLen,
    const char* errorMessage,
    size_t errorMessageLen,
    Luau::Location location
);
ZIG_EXPORT bool ZIG_LUAU_ANALYSIS(Frontend_checkQueuedModules)(
    Luau::Frontend* frontend,
    void* ctx,
    Frontend_checkedModule fn_checkedModule,
    Frontend_checkedModuleError fn_checkedModuleError
)
{
    std::vector<Luau::ModuleName> checkedModules;
    try
    {
        checkedModules = frontend->checkQueuedModules(std::nullopt);
    }
    catch (const Luau::InternalCompilerError& ice)
    {
        Luau::Location location = ice.location ? *ice.location : Luau::Location();

        std::string moduleName = ice.moduleName ? *ice.moduleName : "<unknown module>";
        std::string readableName = frontend->fileResolver->getHumanReadableModuleName(moduleName);

        if (fn_checkedModuleError)
            fn_checkedModuleError(ctx, readableName.c_str(), readableName.size(), ice.message.c_str(), ice.message.size(), location);

        return false;
    }

    for (const auto& module : checkedModules)
    {
        if (!fn_checkedModule(ctx, module.c_str(), module.size()))
            return false;
    }

    return true;
}

ZIG_EXPORT using Frontend_checkedResult = void (*)(
    void* ctx,
    unsigned char kind,
    const char* moduleName,
    size_t moduleNameLen,
    const char* errorMessage,
    size_t errorMessageLen,
    const char* typeName,
    Luau::Location location
);
ZIG_EXPORT unsigned char ZIG_LUAU_ANALYSIS(Frontend_getCheckResult)(
    Luau::Frontend* frontend,
    const char* moduleName,
    size_t moduleNameLen,
    bool accumulateNested,
    bool forAutocomplete,
    void* ctx,
    Frontend_checkedResult fn_checkedResult
)
{
    std::string name(moduleName, moduleNameLen);
    std::optional<Luau::CheckResult> cr = frontend->getCheckResult(name, false);
    if (!cr)
    {
        return 0;
    }

    for (auto& error : cr->errors)
    {
        std::string readableName = frontend->fileResolver->getHumanReadableModuleName(error.moduleName);

        if (const Luau::SyntaxError* syntaxError = Luau::get_if<Luau::SyntaxError>(&error.data))
            fn_checkedResult(ctx, 0, readableName.c_str(), readableName.size(), syntaxError->message.c_str(), syntaxError->message.size(), "SyntaxError", error.location);
        else
        {
            std::string msg = Luau::toString(error, Luau::TypeErrorToStringOptions{frontend->fileResolver});
            fn_checkedResult(ctx, 0, readableName.c_str(), readableName.size(), msg.c_str(), msg.size(), "TypeError", error.location);
        }
    }

    std::string readableName = frontend->fileResolver->getHumanReadableModuleName(name);
    for (auto& error : cr->lintResult.errors)
        fn_checkedResult(ctx, 1, readableName.c_str(), readableName.size(), error.text.c_str(), error.text.size(), Luau::LintWarning::getName(error.code), error.location);
    for (auto& warning : cr->lintResult.warnings)
        fn_checkedResult(ctx, 2, readableName.c_str(), readableName.size(), warning.text.c_str(), warning.text.size(), Luau::LintWarning::getName(warning.code), warning.location);
    return cr->errors.empty() && cr->lintResult.errors.empty() ? 1 : 2;
}

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(Frontend_dtor)(Luau::Frontend* frontend)
{
    delete frontend;
}
