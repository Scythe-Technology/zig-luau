const std = @import("std");
const zon: ZonConfig = @import("build.zig.zon");

const Build = std.Build;
const Step = std.Build.Step;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Remove the default install and uninstall steps
    b.top_level_steps = .{};

    var tag_parts = std.mem.splitBackwardsScalar(u8, zon.dependencies.luau.url, '#');
    var version_parts = std.mem.splitScalar(u8, tag_parts.first(), '.');
    const major_parsed = try std.json.parseFromSlice(u32, b.allocator, version_parts.next().?, .{});
    const minor_parsed = try std.json.parseFromSlice(u32, b.allocator, version_parts.next().?, .{});

    const major = major_parsed.value;
    major_parsed.deinit();
    const minor = minor_parsed.value;
    minor_parsed.deinit();

    const version = std.SemanticVersion{ .major = major, .minor = minor, .patch = 0 };

    const luau_dep = b.dependency("luau", .{});

    const build_Ast = b.option(bool, "Ast", "Build Luau Ast") orelse true;
    const build_CodeGen = b.option(bool, "CodeGen", "Build Luau CodeGen") orelse !target.result.cpu.arch.isWasm();
    const build_Analysis = b.option(bool, "Analysis", "Build Luau Analysis") orelse !target.result.cpu.arch.isWasm();
    const build_Compiler = b.option(bool, "Compiler", "Build Luau Compiler") orelse true;
    const build_VM = b.option(bool, "VM", "Build Luau VM") orelse true;

    const use_4_vector = b.option(bool, "use_4_vector", "Build Luau to use 4-vectors instead of the default 3-vector.") orelse false;
    const wasm_env_name = b.option([]const u8, "wasm_env", "The environment to import symbols from when building for WebAssembly.") orelse "env";

    // Expose build configuration to the zig-luau module
    const config = b.addOptions();
    config.addOption(bool, "use_4_vector", use_4_vector);
    config.addOption(std.SemanticVersion, "luau_version", version);

    config.addOption(bool, "buildAst", build_Ast);
    config.addOption(bool, "buildCodeGen", build_CodeGen);
    config.addOption(bool, "buildAnalysis", build_Analysis);
    config.addOption(bool, "buildCompiler", build_Compiler);
    config.addOption(bool, "buildVM", build_VM);

    // Luau C Headers
    const headers = b.addTranslateC(.{
        .root_source_file = b.path("src/bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    headers.addIncludePath(luau_dep.path("Compiler/include"));
    headers.addIncludePath(luau_dep.path("VM/include"));
    if (!target.result.cpu.arch.isWasm())
        headers.addIncludePath(luau_dep.path("CodeGen/include"));

    const c_module = headers.createModule();

    var FLAGS = std.ArrayList([]const u8).init(b.allocator);

    try FLAGS.append("-DLUA_USE_LONGJMP=" ++ if (!target.result.cpu.arch.isWasm()) "1" else "0");
    try FLAGS.append("-DLUA_API=extern\"C\"");
    try FLAGS.append("-DLUACODE_API=extern\"C\"");
    try FLAGS.append("-DLUACODEGEN_API=extern\"C\"");
    if (use_4_vector)
        try FLAGS.append("-DLUA_VECTOR_SIZE=4");
    if (target.result.cpu.arch.isWasm()) {
        if (target.result.os.tag == .emscripten)
            try FLAGS.append("-fexceptions");
        // else
        // try FLAGS.append("-fwasm-exceptions");
        try FLAGS.append(b.fmt("-DLUAU_WASM_ENV_NAME=\"{s}\"", .{wasm_env_name}));
    }

    const compile_flags = FLAGS.items;

    const libCommon = buildCommon(b, target, luau_dep, optimize, version);
    const libAst = buildAst(b, target, luau_dep, optimize, version, compile_flags, libCommon);
    const libConfig = buildConfig(b, target, luau_dep, optimize, version, compile_flags, libAst);
    const libEqSat = buildEqSat(b, target, luau_dep, optimize, version, compile_flags, libCommon);
    const libCompiler = buildCompiler(b, target, luau_dep, optimize, version, compile_flags, libAst);
    const libVM = buildVM(b, target, luau_dep, optimize, version, compile_flags, libCommon);
    const libCodeGen = buildCodeGen(b, target, luau_dep, optimize, version, compile_flags, libVM);
    const libAnalysis = try buildAnalysis(b, target, luau_dep, optimize, version, compile_flags, libAst, libEqSat, libConfig, libCompiler, libVM);

    const lib = try buildLuau(
        b,
        target,
        luau_dep,
        optimize,
        version,
        compile_flags,
        if (build_Ast) libAst else null,
        if (build_Analysis) libAnalysis else null,
        if (build_CodeGen) libCodeGen else null,
        if (build_Compiler) libCompiler else null,
        if (build_VM) libVM else null,
    );
    b.installArtifact(lib);

    // Zig module
    const luauModule = b.addModule("luau", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    try buildAndLinkModule(b, target, luau_dep, luauModule, config, c_module, lib, use_4_vector);

    // Tests
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    try buildAndLinkModule(b, target, luau_dep, lib_tests.root_module, config, c_module, lib, use_4_vector);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("luau", luauModule);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zig-luau tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_tests.step);

    // Examples
    const examples = [_]struct { []const u8, []const u8 }{
        .{ "luau-bytecode", "examples/luau-bytecode.zig" },
        .{ "repl", "examples/repl.zig" },
        .{ "zig-fn", "examples/zig-fn.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example[0],
            .root_source_file = b.path(example[1]),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("luau", luauModule);

        const artifact = b.addInstallArtifact(exe, .{});
        const exe_step = b.step(b.fmt("install-example-{s}", .{example[0]}), b.fmt("Install {s} example", .{example[0]}));
        exe_step.dependOn(&artifact.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args|
            run_cmd.addArgs(args);

        const run_step = b.step(b.fmt("run-example-{s}", .{example[0]}), b.fmt("Run {s} example", .{example[0]}));
        run_step.dependOn(&run_cmd.step);
    }

    const docs = b.addStaticLibrary(.{
        .name = "luau",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs.root_module.addOptions("config", config);
    docs.root_module.addImport("luau", luauModule);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build and install the documentation");
    docs_step.dependOn(&install_docs.step);
}

fn buildAndLinkModule(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    module: *Build.Module,
    config: *Step.Options,
    c_module: *Build.Module,
    lib: *Step.Compile,
    use_4_vector: bool,
) !void {
    module.addImport("c", c_module);

    module.addOptions("config", config);

    const vector_size: usize = if (use_4_vector) 4 else 3;
    module.addCMacro("LUA_VECTOR_SIZE", b.fmt("{}", .{vector_size}));

    module.addIncludePath(dependency.path("Compiler/include"));
    module.addIncludePath(dependency.path("VM/include"));
    if (!target.result.cpu.arch.isWasm())
        module.addIncludePath(dependency.path("CodeGen/include"));

    module.linkLibrary(lib);
}

pub fn addModuleExportSymbols(b: *Build, module: *Build.Module) void {
    if (module.resolved_target.?.result.cpu.arch.isWasm()) {
        var old_export_symbols = std.ArrayList([]const u8).init(b.allocator);
        old_export_symbols.appendSlice(module.export_symbol_names) catch @panic("OOM");
        old_export_symbols.appendSlice(&.{
            "zig_luau_try_impl",
            "zig_luau_catch_impl",
        }) catch @panic("OOM");
        module.export_symbol_names = old_export_symbols.toOwnedSlice() catch @panic("OOM");
    }
}

fn linkIncludePath(
    target: *Step.Compile,
    source: *Step.Compile,
) void {
    for (source.root_module.include_dirs.items) |dir|
        switch (dir) {
            .path => |path| blk: {
                for (target.root_module.include_dirs.items) |target_dir|
                    if (target_dir == .path and
                        path == .dependency and target_dir.path == .dependency and
                        path.dependency.dependency == target_dir.path.dependency.dependency and
                        std.mem.eql(u8, path.dependency.sub_path, target_dir.path.dependency.sub_path))
                        break :blk;

                target.addIncludePath(path);
            },
            else => {},
        };
}

fn buildCommon(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Common",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    for (LUAU_Common_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    return lib;
}

fn buildAst(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libCommon: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Ast",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libCommon);

    lib.linkLibCpp();

    for (LUAU_Ast_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_Ast_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildCompiler(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libAst: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Compiler",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libAst);
    lib.linkLibrary(libAst);

    lib.linkLibCpp();

    for (LUAU_Compiler_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_Compiler_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildConfig(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libAst: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Config",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libAst);
    lib.linkLibrary(libAst);

    lib.linkLibCpp();

    for (LUAU_Config_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_Config_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildAnalysis(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libAst: *Step.Compile,
    libEqSat: *Step.Compile,
    libConfig: *Step.Compile,
    libCompiler: *Step.Compile,
    libVM: *Step.Compile,
) !*Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Analysis",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libAst);
    linkIncludePath(lib, libEqSat);
    linkIncludePath(lib, libConfig);
    linkIncludePath(lib, libCompiler);
    linkIncludePath(lib, libVM);

    lib.linkLibrary(libAst);
    lib.linkLibrary(libEqSat);
    lib.linkLibrary(libConfig);
    lib.linkLibrary(libCompiler);
    lib.linkLibrary(libVM);

    lib.linkLibCpp();

    for (LUAU_Analysis_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_Analysis_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildEqSat(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libCommon: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "EqSat",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libCommon);

    lib.linkLibCpp();

    for (LUAU_EqSat_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_EqSat_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildCodeGen(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libVM: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "CodeGen",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libVM);
    lib.linkLibrary(libVM);

    lib.linkLibCpp();

    for (LUAU_CodeGen_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_CodeGen_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildVM(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libCommon: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "VM",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libCommon);

    lib.linkLibCpp();

    for (LUAU_VM_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_VM_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildRequire(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libVM: *Step.Compile,
    libRequireNavigator: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "Require",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libVM);
    linkIncludePath(lib, libRequireNavigator);

    lib.linkLibCpp();

    for (LUAU_Require_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_Require_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

fn buildRequireNavigator(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libConfig: *Step.Compile,
) *Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "RequireNavigator",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    linkIncludePath(lib, libConfig);

    lib.linkLibCpp();

    for (LUAU_RequireNavigator_HEADERS_DIRS) |dir|
        lib.addIncludePath(dependency.path(dir));

    lib.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &LUAU_RequireNavigator_SOURCE_FILES,
        .flags = flags,
    });

    return lib;
}

/// Luau has diverged enough from Lua (C++, project structure, ...) that it is easier to separate the build logic
fn buildLuau(
    b: *Build,
    target: Build.ResolvedTarget,
    dependency: *Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    flags: []const []const u8,
    libAst: ?*Step.Compile,
    libAnalysis: ?*Step.Compile,
    libCodeGen: ?*Step.Compile,
    libCompiler: ?*Step.Compile,
    libVM: ?*Step.Compile,
) !*Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "luau",
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    lib.addIncludePath(b.path("src"));

    lib.linkLibCpp();

    lib.addCSourceFile(.{ .file = b.path("src/bridge.cpp"), .flags = flags });

    if (libAst) |mod| {
        lib.linkLibrary(mod);
        lib.addCSourceFiles(.{ .flags = flags, .root = b.path("src/Ast/"), .files = &.{
            "Allocator.cpp",
            "Lexer.cpp",
            "Parser.cpp",
        } });
        linkIncludePath(lib, mod);
    }
    if (libAnalysis) |mod| {
        lib.linkLibrary(mod);
        lib.addCSourceFiles(.{ .flags = flags, .root = b.path("src/Analysis/"), .files = &.{
            "FileUtils.cpp",
            "AstJsonEncoder.cpp",
            "Frontend.cpp",
            "FileResolver.cpp",
            "GenericConfigResolver.cpp",
        } });
        linkIncludePath(lib, mod);
    }
    if (libCodeGen) |mod| {
        lib.linkLibrary(mod);
        linkIncludePath(lib, mod);
    }
    if (libCompiler) |mod| {
        lib.linkLibrary(mod);
        lib.addCSourceFile(.{ .file = b.path("src/Compiler/Compiler.cpp"), .flags = flags });
        linkIncludePath(lib, mod);
    }
    if (libVM) |mod| {
        lib.linkLibrary(mod);
        linkIncludePath(lib, mod);
    }

    // It may not be as likely that other software links against Luau, but might as well expose these anyway
    lib.installHeader(dependency.path("VM/include/lua.h"), "lua.h");
    lib.installHeader(dependency.path("VM/include/lualib.h"), "lualib.h");
    lib.installHeader(dependency.path("VM/include/luaconf.h"), "luaconf.h");
    if (!target.result.cpu.arch.isWasm())
        lib.installHeader(dependency.path("CodeGen/include/luacodegen.h"), "luacodegen.h");

    return lib;
}

const LUAU_Analysis_HEADERS_DIRS = [_][]const u8{
    "Analysis/include/",
    "Analysis/src/",
};
const LUAU_Analysis_SOURCE_FILES = [_][]const u8{
    "Analysis/src/Anyification.cpp",
    "Analysis/src/ApplyTypeFunction.cpp",
    "Analysis/src/AstJsonEncoder.cpp",
    "Analysis/src/AstQuery.cpp",
    "Analysis/src/Autocomplete.cpp",
    "Analysis/src/AutocompleteCore.cpp",
    "Analysis/src/BuiltinDefinitions.cpp",
    "Analysis/src/BuiltinTypeFunctions.cpp",
    "Analysis/src/Clone.cpp",
    "Analysis/src/Constraint.cpp",
    "Analysis/src/ConstraintGenerator.cpp",
    "Analysis/src/ConstraintSolver.cpp",
    "Analysis/src/DataFlowGraph.cpp",
    "Analysis/src/DcrLogger.cpp",
    "Analysis/src/Def.cpp",
    "Analysis/src/EmbeddedBuiltinDefinitions.cpp",
    "Analysis/src/EqSatSimplification.cpp",
    "Analysis/src/Error.cpp",
    "Analysis/src/ExpectedTypeVisitor.cpp",
    "Analysis/src/FileResolver.cpp",
    "Analysis/src/FragmentAutocomplete.cpp",
    "Analysis/src/Frontend.cpp",
    "Analysis/src/Generalization.cpp",
    "Analysis/src/GlobalTypes.cpp",
    "Analysis/src/InferPolarity.cpp",
    "Analysis/src/Instantiation.cpp",
    "Analysis/src/Instantiation2.cpp",
    "Analysis/src/IostreamHelpers.cpp",
    "Analysis/src/JsonEmitter.cpp",
    "Analysis/src/Linter.cpp",
    "Analysis/src/LValue.cpp",
    "Analysis/src/Module.cpp",
    "Analysis/src/NonStrictTypeChecker.cpp",
    "Analysis/src/Normalize.cpp",
    "Analysis/src/OverloadResolution.cpp",
    "Analysis/src/Quantify.cpp",
    "Analysis/src/Refinement.cpp",
    "Analysis/src/RequireTracer.cpp",
    "Analysis/src/Scope.cpp",
    "Analysis/src/Simplify.cpp",
    "Analysis/src/Substitution.cpp",
    "Analysis/src/Subtyping.cpp",
    "Analysis/src/Symbol.cpp",
    "Analysis/src/TableLiteralInference.cpp",
    "Analysis/src/ToDot.cpp",
    "Analysis/src/TopoSortStatements.cpp",
    "Analysis/src/ToString.cpp",
    "Analysis/src/Transpiler.cpp",
    "Analysis/src/TxnLog.cpp",
    "Analysis/src/Type.cpp",
    "Analysis/src/TypeArena.cpp",
    "Analysis/src/TypeAttach.cpp",
    "Analysis/src/TypeChecker2.cpp",
    "Analysis/src/TypedAllocator.cpp",
    "Analysis/src/TypeFunction.cpp",
    "Analysis/src/TypeFunctionReductionGuesser.cpp",
    "Analysis/src/TypeFunctionRuntime.cpp",
    "Analysis/src/TypeFunctionRuntimeBuilder.cpp",
    "Analysis/src/TypeIds.cpp",
    "Analysis/src/TypeInfer.cpp",
    "Analysis/src/TypeOrPack.cpp",
    "Analysis/src/TypePack.cpp",
    "Analysis/src/TypePath.cpp",
    "Analysis/src/TypeUtils.cpp",
    "Analysis/src/Unifiable.cpp",
    "Analysis/src/Unifier.cpp",
    "Analysis/src/Unifier2.cpp",
    "Analysis/src/UserDefinedTypeFunction.cpp",
};

const LUAU_Ast_HEADERS_DIRS = [_][]const u8{
    "Ast/include/",
};
const LUAU_Ast_SOURCE_FILES = [_][]const u8{
    "Ast/src/Ast.cpp",
    "Ast/src/Cst.cpp",
    "Ast/src/Allocator.cpp",
    "Ast/src/Confusables.cpp",
    "Ast/src/Lexer.cpp",
    "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",
    "Ast/src/StringUtils.cpp",
    "Ast/src/TimeTrace.cpp",
};

const LUAU_CodeGen_HEADERS_DIRS = [_][]const u8{
    "CodeGen/include/",
    "CodeGen/src/",
};
const LUAU_CodeGen_SOURCE_FILES = [_][]const u8{
    "CodeGen/src/AssemblyBuilderA64.cpp",
    "CodeGen/src/AssemblyBuilderX64.cpp",
    "CodeGen/src/CodeAllocator.cpp",
    "CodeGen/src/CodeBlockUnwind.cpp",
    "CodeGen/src/CodeGen.cpp",
    "CodeGen/src/CodeGenAssembly.cpp",
    "CodeGen/src/CodeGenContext.cpp",
    "CodeGen/src/CodeGenUtils.cpp",
    "CodeGen/src/CodeGenA64.cpp",
    "CodeGen/src/CodeGenX64.cpp",
    "CodeGen/src/EmitBuiltinsX64.cpp",
    "CodeGen/src/EmitCommonX64.cpp",
    "CodeGen/src/EmitInstructionX64.cpp",
    "CodeGen/src/IrAnalysis.cpp",
    "CodeGen/src/IrBuilder.cpp",
    "CodeGen/src/IrCallWrapperX64.cpp",
    "CodeGen/src/IrDump.cpp",
    "CodeGen/src/IrLoweringA64.cpp",
    "CodeGen/src/IrLoweringX64.cpp",
    "CodeGen/src/IrRegAllocA64.cpp",
    "CodeGen/src/IrRegAllocX64.cpp",
    "CodeGen/src/IrTranslateBuiltins.cpp",
    "CodeGen/src/IrTranslation.cpp",
    "CodeGen/src/IrUtils.cpp",
    "CodeGen/src/IrValueLocationTracking.cpp",
    "CodeGen/src/lcodegen.cpp",
    "CodeGen/src/NativeProtoExecData.cpp",
    "CodeGen/src/NativeState.cpp",
    "CodeGen/src/OptimizeConstProp.cpp",
    "CodeGen/src/OptimizeDeadStore.cpp",
    "CodeGen/src/OptimizeFinalX64.cpp",
    "CodeGen/src/UnwindBuilderDwarf2.cpp",
    "CodeGen/src/UnwindBuilderWin.cpp",
    "CodeGen/src/BytecodeAnalysis.cpp",
    "CodeGen/src/BytecodeSummary.cpp",
    "CodeGen/src/SharedCodeAllocator.cpp",
};

const LUAU_Common_HEADERS_DIRS = [_][]const u8{
    "Common/include/",
};

const LUAU_Compiler_HEADERS_DIRS = [_][]const u8{
    "Compiler/include/",
    "Compiler/src/",
};
const LUAU_Compiler_SOURCE_FILES = [_][]const u8{
    "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/Builtins.cpp",
    "Compiler/src/BytecodeBuilder.cpp",
    "Compiler/src/Compiler.cpp",
    "Compiler/src/ConstantFolding.cpp",
    "Compiler/src/CostModel.cpp",
    "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",
    "Compiler/src/ValueTracking.cpp",
    "Compiler/src/lcode.cpp",
};

const LUAU_Config_HEADERS_DIRS = [_][]const u8{
    "Config/include/",
};
const LUAU_Config_SOURCE_FILES = [_][]const u8{
    "Config/src/Config.cpp",
    "Config/src/LinterConfig.cpp",
};

const LUAU_EqSat_HEADERS_DIRS = [_][]const u8{
    "EqSat/include/",
};
const LUAU_EqSat_SOURCE_FILES = [_][]const u8{
    "EqSat/src/Id.cpp",
    "EqSat/src/UnionFind.cpp",
};

const LUAU_Require_HEADERS_DIRS = [_][]const u8{
    "Require/Runtime/include/",
    "Require/Runtime/src/",
};
const LUAU_Require_SOURCE_FILES = [_][]const u8{
    "Require/Runtime/src/Navigation.cpp",
    "Require/Runtime/src/Require.cpp",
    "Require/Runtime/src/RequireImpl.cpp",
};

const LUAU_RequireNavigator_HEADERS_DIRS = [_][]const u8{
    "Require/Navigator/include/",
};
const LUAU_RequireNavigator_SOURCE_FILES = [_][]const u8{
    "Require/Navigator/src/PathUtilities.cpp",
    "Require/Navigator/src/RequireNavigator.cpp",
};

const LUAU_VM_HEADERS_DIRS = [_][]const u8{
    "VM/include/",
    "VM/src/",
};

const LUAU_VM_SOURCE_FILES = [_][]const u8{
    "VM/src/lapi.cpp",
    "VM/src/laux.cpp",
    "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",
    "VM/src/lbuffer.cpp",
    "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",
    "VM/src/lcorolib.cpp",
    "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",
    "VM/src/ldo.cpp",
    "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",
    "VM/src/lgcdebug.cpp",
    "VM/src/linit.cpp",
    "VM/src/lmathlib.cpp",
    "VM/src/lmem.cpp",
    "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",
    "VM/src/loslib.cpp",
    "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",
    "VM/src/lstring.cpp",
    "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",
    "VM/src/ltablib.cpp",
    "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",
    "VM/src/lutf8lib.cpp",
    "VM/src/lvmexecute.cpp",
    "VM/src/lveclib.cpp",
    "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
};

const ZonConfig = struct {
    name: enum { luau },
    fingerprint: u64,
    version: []const u8,
    dependencies: struct {
        luau: struct { url: []const u8, hash: []const u8 },
    },
    paths: []const []const u8,
};
