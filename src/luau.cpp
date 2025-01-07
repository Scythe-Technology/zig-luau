#include "Luau/Common.h"
#include "ldo.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static int assertionHandler(const char *expr, const char *file, int line, const char *function)
{
    printf("%s(%d): ASSERTION FAILED: %s\n", file, line, expr);
    return 1;
}

extern "C" void zig_registerAssertionHandler()
{
    Luau::assertHandler() = assertionHandler;
}

extern "C" void zig_luau_free(void *ptr)
{
    free(ptr);
}

extern "C" bool zig_luau_setflag_bool(const char *name, size_t nameLen, bool value)
{
    std::string flagName(name, nameLen);
    for (Luau::FValue<bool> *flag = Luau::FValue<bool>::list; flag; flag = flag->next)
        if (flagName == flag->name)
        {
            flag->value = value;
            return true;
        }
    return false;
}

extern "C" bool zig_luau_setflag_int(const char *name, size_t nameLen, int value)
{
    std::string flagName(name, nameLen);
    for (Luau::FValue<int> *flag = Luau::FValue<int>::list; flag; flag = flag->next)
        if (flagName == flag->name)
        {
            flag->value = value;
            return true;
        }
    return false;
}

extern "C" bool zig_luau_getflag_bool(const char *name, size_t nameLen, bool *value)
{
    std::string flagName(name, nameLen);
    for (Luau::FValue<bool> *flag = Luau::FValue<bool>::list; flag; flag = flag->next)
        if (flagName == flag->name)
        {
            *value = flag->value;
            return true;
        }
    return false;
}

extern "C" bool zig_luau_getflag_int(const char *name, size_t nameLen, int *value)
{
    std::string flagName(name, nameLen);
    for (Luau::FValue<int> *flag = Luau::FValue<int>::list; flag; flag = flag->next)
        if (flagName == flag->name)
        {
            *value = flag->value;
            return true;
        }
    return false;
}

extern "C" struct FlagGroup
{
    const char **names;
    int *types;
    size_t size;
};

extern "C" FlagGroup zig_luau_getflags()
{
    std::vector<std::string> names_list;
    std::vector<int> types_list;

    for (Luau::FValue<bool> *flag = Luau::FValue<bool>::list; flag; flag = flag->next)
    {
        names_list.push_back(flag->name);
        types_list.push_back(0);
    }
    for (Luau::FValue<int> *flag = Luau::FValue<int>::list; flag; flag = flag->next)
    {
        names_list.push_back(flag->name);
        types_list.push_back(1);
    }

    size_t size = names_list.size();

    const char **names = new const char *[size];
    int *types = new int[size];

    int i = 0;

    for (size_t i = 0; i < size; ++i)
    {
        names[i] = strdup(names_list[i].c_str());
        types[i] = types_list[i];
    }

    return {names, types, size};
}

extern "C" void zig_luau_freeflags(FlagGroup group)
{
    for (size_t i = 0; i < group.size; i++)
    {
        free((void *)group.names[i]);
    }
    delete[] group.names;
    delete[] group.types;
}

// Internal API
extern "C" void zig_luau_luaD_checkstack(lua_State *L, int n)
{
    luaD_checkstack(L, n);
}
extern "C" void zig_luau_expandstacklimit(lua_State *L, int n)
{
    expandstacklimit(L, L->top + n);
}
extern "C" int zig_luau_luaG_isnative(lua_State *L, int level)
{
    return luaG_isnative(L, level);
}

#if defined(__wasm__)

#include <functional>

#define LUAU_TRY_CATCH(trying, catching) zig_luau_try_catch_js(trying, catching)
#define LUAU_THROW(e) zig_luau_throw_js(e)
#define LUAU_EXTERNAL_TRY_CATCH

#if not defined(LUAU_WASM_ENV_NAME)
#define LUAU_WASM_ENV_NAME "env"
#endif

struct TryCatchContext
{
    std::function<void()> trying;
    std::function<void(const std::exception &)> catching;
};
// only clang compilers support C/C++ -> wasm so it's safe to use the attribute here
__attribute__((import_module(LUAU_WASM_ENV_NAME), import_name("try_catch"))) void zig_luau_try_catch_js_impl(TryCatchContext *context);
__attribute__((import_module(LUAU_WASM_ENV_NAME), import_name("throw"))) void zig_luau_throw_js_impl(const std::exception *e);

void zig_luau_try_catch_js(std::function<void()> trying, std::function<void(const std::exception &)> catching)
{
    auto context = TryCatchContext{trying, catching};
    zig_luau_try_catch_js_impl(&context);
}

void zig_luau_throw_js(const std::exception &e)
{
    zig_luau_throw_js_impl(&e);
}

extern "C" void zig_luau_try_impl(TryCatchContext *context)
{
    context->trying();
}

extern "C" void zig_luau_catch_impl(TryCatchContext *context, const std::exception &e)
{
    context->catching(e);
}

#endif
