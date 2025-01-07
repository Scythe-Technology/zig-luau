# Zig-luau
[![shield showing current tests status](https://github.com/SnorlaxAssist/zig-luau/actions/workflows/tests.yml/badge.svg)](https://github.com/SnorlaxAssist/zig-luau/actions/workflows/tests.yml)

A Zig package that provides a complete and lightweight wrapper around the [Luau C API](https://www.lua.org/manual/5.4/manual.html#4). Zig-luau currently supports [Luau](https://luau-lang.org) and targets Zig. Tagged versions of Zig-luau are made for stable Zig releases. Forked from [natecraddock/ziglua](https://github.com/natecraddock/ziglua)

Zig-luau can be used in two ways, either
* **embedded** to statically embed the Lua VM in a Zig program,
* or as a shared **module** to create Lua libraries that can be loaded at runtime in other Lua-based software.

In both cases, Zig-luau will compile Lua from source and link against your Zig code making it easy to create software that integrates with Lua without requiring any system Lua libraries.

## Documentation
Docs are a work in progress and are automatically generated for each push to main. Most functions and public declarations are documented:
* [Ziglua Docs](https://natecraddock.github.io/ziglua/#ziglua.lib.Lua)

See [docs.md](https://github.com/natecraddock/ziglua/blob/main/docs.md) for more general information on Zigluau and how it differs from the C API.

Example code is included in the [examples](https://github.com/natecraddock/ziglua/tree/main/examples) directory.
* Run an example with `zig build run-example-<name>`
* Install an example with `zig build install-example-<name>`

## Why use Zig-luau?
In a nutshell, Zig-luau is a simple wrapper around the C API you would get by using Zig's `@cImport()`. Zig-luau aims to mirror the [Lua C API](https://www.lua.org/manual/5.4/manual.html#4) as closely as possible, while improving ergonomics using Zig's features. For example:

* Zig error unions to require failure state handling
* Null-terminated slices instead of C strings
* Type-checked enums for parameters and return values
* Compiler-enforced checking of optional pointers
* Better types in many cases (e.g. `bool` instead of `int`)
* Comptime convenience functions to make binding creation easier

Nearly every function in the C API is exposed in Zig-luau.

## Integrating Zig-luau in your project

Find the archive url of the Zig-luau version you want to integrate with your project. For example, the url for the commit **N/A**

Then run `zig fetch --save <url>`. This will add the dependency to your `build.zig.zon` file.

Then in your `build.zig` file you can use the dependency.

```zig
pub fn build(b: *std.Build) void {
    // ... snip ...

    const zigluau = b.dependency("zig-luau", .{
        .target = target,
        .optimize = optimize,
    });

    // ... snip ...

    // add the zig-luau module and lua artifact
    exe.root_module.addImport("luau", zigluau.module("zig-luau"));

}
```

This will compile the Lua C sources and link with your project.

For example, here is a `b.dependency()` call that and links against a Luau library:

```zig
const zigluau = b.dependency("zig-luau", .{
    .target = target,
    .optimize = optimize,
});
``````

The `zig-luau` module will now be available in your code. Here is a simple example that pushes and inspects an integer on the Lua stack:

```zig
const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

pub fn main() anyerror!void {
    // Create an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize the Luau vm
    var l = try Luau.init(allocator);
    defer l.deinit();

    // Add an integer to the Luau stack and retrieve it
    l.pushInteger(42);
    std.debug.print("{}\n", .{try l.toInteger(1)});
}
```

## Wasm Usage
For wasm, make sure to define `zig_luau_try_catch_js_impl` and `zig_luau_throw_js_impl` in your program and host environment (forward them to js). These functions are used to catch and throw errors from the Lua VM.
```cpp
// don't need to actually work with these values, they're just pointers which you can pass around as numbers on the js side
extern "C" void zig_luau_try_catch_js_impl(TryCatchContext *context);
extern "C" void zig_luau_throw_js_impl(const std::exception *e); 
```
Then in your JS environment, when you're ready to run the try and catch branches, you can call `zig_luau_try_impl` and `zig_luau_catch_impl` with the appropriate pointers. For example
```javascript
zig_luau_throw_js_impl = function(e) {
    // a class to store the error pointer
    throw new NativeException(e);
}
zig_luau_try_catch_js_impl = function(context) {
    try {
        exports.zig_luau_try_impl(context);
    } catch (e) {
        if (e instanceof NativeException) {
            exports.zig_luau_catch_impl(e.error);
        } else {
            throw e;
        } 
    }
}
```

## Contributing

Please make suggestions, report bugs, and create pull requests. Anyone is welcome to contribute!

I only use a subset of the Luau API through Zig-luau, so if there are parts that aren't easy to use or understand, please fix it yourself or let me know!

Thank you to the [Luau](https://luau-lang.org/) team for creating such a great language!
