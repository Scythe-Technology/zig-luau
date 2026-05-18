# zig-luau
[![shield showing current tests status](https://github.com/Scythe-Technology/zig-luau/actions/workflows/tests.yml/badge.svg)](https://github.com/Scythe-Technology/zig-luau/actions/workflows/tests.yml)

A zig library for [Luau](https://luau-lang.org/). C API and Zig API combined.

Developed primarily for [ZUNE](https://zune.sh), but can be used in any zig project.

## Zig Backend
This is a experimental backend, which has some luau API entirely in zig, translated from C++. (incomplete)

Such as the `VM/src/lgc.cpp` would be in [`src/VM/lgc.zig`](src/VM/lgc.zig). The code translated is to be close as possible to the original C++ code, but with some slight optimizations and changes to fit the zig language better, things like error handling are done through zig errorset rather than C++ exceptions.

Only the `VM` has primary focus, while other parts of the luau codebase are still in C++.

The zig backend can be disabled by compiling with `-Duse_zig_backend=false`, or setting the dependency options in your `build.zig`, which would use the original C++ API for everything, and the zig code will be ignored.

## WASM Support
This library can be compiled into `wasm32-wasi`, but does not support lua errors, due to C++ exceptions or setjmp/longjmp not supported in wasi (work in progress, experimental wasm `sjlj` clang flags are not enabled for zig).

## Contributing

Please make suggestions, report bugs, or create pull requests. Anyone is welcome to contribute!

Thank you to the [Luau](https://luau-lang.org/) team for creating such a great language!

## License
- zig-luau is licensed under the [MIT License](LICENSE).
- luau is licensed under the [MIT License](LUAU-LICENSE).