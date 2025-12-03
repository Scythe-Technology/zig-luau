#include <bridge.h>

#include "Luau/ConfigResolver.h"

#include "./FileUtils.h"

#define ZIG_LUAU_ANALYSIS(name) ZIG_FN(Luau_Analysis_##name)

// This code is based on https://github.com/luau-lang/luau/blob/68cdcc4a3a5f3ed23186c4f7f6b8a5aacf835bee/CLI/src/Analyze.cpp#L202
struct GenericConfigResolver : Luau::ConfigResolver
{
    mutable std::vector<std::pair<std::string, std::string>> configErrors;
    mutable std::unordered_map<std::string, Luau::Config> configCache;
    
    Luau::Config defaultConfig;

    GenericConfigResolver(Luau::Mode mode)
    {
        defaultConfig.mode = mode;
    }

    const Luau::Config& getConfig(const Luau::ModuleName& name, const Luau::TypeCheckLimits& limits) const override
    {
        std::optional<std::string> path = getParentPath(name);
        if (!path)
            return defaultConfig;

        return readConfigRec(*path, limits);
    }

    const Luau::Config& readConfigRec(const std::string& path, const Luau::TypeCheckLimits& limits) const
    {
        auto it = configCache.find(path);
        if (it != configCache.end())
            return it->second;

        std::optional<std::string> parent = getParentPath(path);
        Luau::Config result = parent ? readConfigRec(*parent, limits) : defaultConfig;

        std::string configPath = joinPaths(path, Luau::kConfigName);

        if (std::optional<std::string> contents = readFile(configPath))
        {
            Luau::ConfigOptions::AliasOptions aliasOpts;
            aliasOpts.configLocation = configPath;
            aliasOpts.overwriteAliases = true;

            Luau::ConfigOptions opts;
            opts.aliasOptions = std::move(aliasOpts);

            std::optional<std::string> error = Luau::parseConfig(*contents, result, opts);
            if (error)
                configErrors.push_back({configPath, *error});
        }

        return configCache[path] = result;
    }
};

ZIG_EXPORT GenericConfigResolver* ZIG_LUAU_ANALYSIS(GenericConfigResolver_init)(unsigned char mode)
{
    Luau::Mode luauMode = Luau::Mode::NoCheck;
    if (mode == 0)
        luauMode = Luau::Mode::NoCheck;
    else if (mode == 1)
        luauMode = Luau::Mode::Nonstrict;
    else if (mode == 2)
        luauMode = Luau::Mode::Strict;
    else if (mode == 3)
        luauMode = Luau::Mode::Definition;
    return new GenericConfigResolver(luauMode);
}

ZIG_EXPORT struct ErrorGroup
{
    const char **paths;
    const char **messages;
    size_t size;
};

ZIG_EXPORT void ZIG_LUAU_ANALYSIS(GenericConfigResolver_dtor)(GenericConfigResolver* resolver)
{
    delete resolver;
}
