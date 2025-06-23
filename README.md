# zig-luau
[![shield showing current tests status](https://github.com/Scythe-Technology/zig-luau/actions/workflows/tests.yml/badge.svg)](https://github.com/SnorlaxAssist/zig-luau/actions/workflows/tests.yml)

zig-luau is a wrapper and binding to [Luau](https://luau-lang.org/). This library provides some api that is written entirely in Zig, and most that are bindings to the luau C api.

## Wasm Usage
zig-luau can be compiled into `wasm32-wasi`, but does not support lua errors, due to C++ exceptions not supported in wasi (work in progress).

## Contributing

Please make suggestions, report bugs, and create pull requests. Anyone is welcome to contribute!

I only use a subset of the Luau API through zig-luau, so if there are parts that aren't easy to use or understand, please fix it yourself or let me know!

Thank you to the [Luau](https://luau-lang.org/) team for creating such a great language!
