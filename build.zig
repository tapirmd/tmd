const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // options

    const compileOptions = try collectCompileOptions(b, optimize);
    const libOptions = b.addOptions();
    libOptions.addOption([]const u8, "version", compileOptions.version);
    //libOptions.addOption(bool, "option1", compileOptions.option1);

    // list module

    const listLibModule = b.addModule("list", .{
        .root_source_file = b.path("library/list/list.zig"),
        //.target = target,
        //.optimize = optimize,
    });

    const listLibTest = b.addTest(.{
        .name = "list lib unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/list/list.zig"),
            .target = target,
        }),
    });
    const runListLibTest = b.addRunArtifact(listLibTest);

    // tree module

    const treeLibModule = b.addModule("tree", .{
        .root_source_file = b.path("library/tree/tree.zig"),
        //.target = target,
        //.optimize = optimize,
    });

    const treeLibTest = b.addTest(.{
        .name = "list lib unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/tree/tree.zig"),
            .target = target,
        }),
    });
    const runTreeLibTest = b.addRunArtifact(treeLibTest);

    // lib (for C users)
    // ToDo: Need many exported functions, including field setter/getter?
    //
    //const tmdLib = b.addStaticLibrary(.{
    //    .name = "tmd",
    //    .root_source_file = b.path("library/tmd-core/tmd-for-c.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const installLib = b.addInstallArtifact(tmdLib, .{});
    //
    //const libStep = b.step("lib", "Install lib");
    //libStep.dependOn(&installLib.step);

    // tmd module

    const tmdLibModule = b.addModule("tmd", .{
        .root_source_file = b.path("library/tmd-core/tmd.zig"),
        //.target = target,
        //.optimize = optimize,
    });
    tmdLibModule.addImport("list", listLibModule);
    tmdLibModule.addImport("tree", treeLibModule);
    tmdLibModule.addOptions("compile_options", libOptions); // @import("compile_options");

    // test

    const coreLibTest = b.addTest(.{
        .name = "tmd core lib unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/tmd-core-tests/all.zig"),
            .target = target,
        }),
    });
    coreLibTest.root_module.addImport("tmd", tmdLibModule);
    coreLibTest.root_module.addImport("list", listLibModule);
    coreLibTest.root_module.addImport("tree", treeLibModule);
    const runCoreLibTest = b.addRunArtifact(coreLibTest);

    const coreLibInternalTest = b.addTest(.{
        .name = "tmd core lib internal unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/tmd-core/tests.zig"),
            .target = target,
        }),
    });
    coreLibInternalTest.root_module.addImport("list", listLibModule);
    coreLibInternalTest.root_module.addImport("tree", treeLibModule);
    const runCoreLibInternalTest = b.addRunArtifact(coreLibInternalTest);

    const wasmLibTest = b.addTest(.{
        .name = "tmd wasm lib unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/tmd-wasm/tests.zig"),
            .target = target, // ToDo: related to wasmTarget?
        }),
    });
    const runWasmLibTest = b.addRunArtifact(wasmLibTest);

    const toolchainTest = b.addTest(.{
        .name = "toolchain unit test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("toolchain/tests.zig"),
            .target = target,
        }),
    });
    toolchainTest.root_module.addImport("tmd", tmdLibModule);
    const runToolchainTest = b.addRunArtifact(toolchainTest);

    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&runListLibTest.step);
    testStep.dependOn(&runTreeLibTest.step);
    testStep.dependOn(&runCoreLibTest.step);
    testStep.dependOn(&runCoreLibInternalTest.step);
    testStep.dependOn(&runWasmLibTest.step);
    testStep.dependOn(&runToolchainTest.step);

    // toolchain command

    const toolchainCommand = b.addExecutable(.{
        .name = "tmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("toolchain/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    toolchainCommand.root_module.addImport("tmd", tmdLibModule);
    toolchainCommand.root_module.addImport("list", listLibModule);
    toolchainCommand.root_module.addImport("tree", treeLibModule);
    const installToolchain = b.addInstallArtifact(toolchainCommand, .{});

    const toolchainStep = b.step("toolchain", "Build toolchain");
    toolchainStep.dependOn(&installToolchain.step);

    b.installArtifact(toolchainCommand);

    // toolchain dependencies

    const translate_c = b.dependency("translate_c", .{});
    const Translator = @import("translate_c").Translator;
    const miniz_c: Translator = .init(translate_c, .{
        .c_source_file = b.path("dependencies/miniz/miniz.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    miniz_c.addIncludePath(b.path("dependencies/miniz"));

    toolchainCommand.root_module.addImport("miniz", miniz_c.mod);
    //toolchainCommand.root_module.addIncludePath(b.path("dependencies/miniz"));
    toolchainCommand.root_module.addCSourceFiles(.{
        .root = b.path("dependencies/miniz"),
        .files = &.{"miniz.c"},
    });

    // run toolchain cmd

    const runTmdCommand = b.addRunArtifact(toolchainCommand);
    runTmdCommand.addPassthruArgs();

    const runStep = b.step("run", "Run tmd command");
    runStep.dependOn(&runTmdCommand.step);

    // wasm

    const wasmTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasmOptimize: std.lang.Optimize = .small;

    const wasmLibModule = b.addModule("tmd-wasm", .{
        .root_source_file = b.path("library/tmd-wasm/wasm.zig"),
        .target = wasmTarget,
        .optimize = wasmOptimize,
    });
    wasmLibModule.addImport("tmd", tmdLibModule);

    const wasm = b.addExecutable(.{
        .name = "tmd",
        .root_module = wasmLibModule,
    });

    // <https://github.com/ziglang/zig/issues/8633>
    //wasm.global_base = 8192; // What is the meaning? Some runtimes have requirements on this?
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // It looks the program itself need minimum memory between 1M and 1.5M initially.
    // The program will dynamically allocate about 10M at run time.
    // But why is the max_memory required to be set so large?
    wasm.max_memory = (1 << 24) + (1 << 21); // 18M

    const installWasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } });

    const wasmStep = b.step("wasm", "Build wasm lib");
    wasmStep.dependOn(&installWasm.step);

    // Used in below several places.
    const file_injector = b.addExecutable(.{
        .name = "file-injector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/inject-file-content.zig"),
            .target = b.graph.host,
        }),
    });

    // js
    const jsLibFilename = "tmd-with-wasm.js";

    const wasm_injector = b.addRunArtifact(file_injector);
    wasm_injector.addArg("base64");
    wasm_injector.addFileArg(b.path("library/tmd-js/tmd-with-wasm-template.js"));
    wasm_injector.addArg("<wasm-file-as-base64-string>");
    wasm_injector.addFileArg(installWasm.emitted_bin.?);
    const js_output_file = wasm_injector.addOutputFileArg2(jsLibFilename, .{});
    wasm_injector.step.dependOn(&installWasm.step);

    const installJsLib = b.addInstallFileWithDir(js_output_file, .lib, jsLibFilename);
    installJsLib.step.dependOn(&wasm_injector.step);

    const jsLibStep = b.step("js", "Build JavaScript lib");
    jsLibStep.dependOn(&installJsLib.step);

    // documentation fmt

    const fmtDoc = b.addRunArtifact(toolchainCommand);
    fmtDoc.setCwd(b.path("."));
    fmtDoc.addArg("fmt");
    fmtDoc.addArg("documentation/pages");

    // documentation gen

    const buildWebsite = b.addRunArtifact(toolchainCommand);
    buildWebsite.step.dependOn(&installJsLib.step);
    buildWebsite.setCwd(b.path("."));
    buildWebsite.addArg("build");
    buildWebsite.addArg("documentation/pages");

    // complete play page
    const play_page_path = b.path("documentation/pages/@tmd-build/pages/versions/latest/play.html");

    const js_injector = b.addRunArtifact(file_injector);
    js_injector.addArg("none");
    js_injector.addFileArg(play_page_path);
    js_injector.addArg("[js-lib-file]");
    js_injector.addFileArg(js_output_file);
    js_injector.addFileArg(play_page_path);

    js_injector.step.dependOn(&buildWebsite.step);

    // doc

    const buildDoc = b.step("doc", "Build documentation");
    buildDoc.dependOn(&js_injector.step);

    // fmt

    const fmtCode = b.addFmt(.{
        .paths = &.{
            b.path("."),
        },
    });
    const fmtCodeAndDoc = b.step("fmt", "Format code and documentation");
    fmtCodeAndDoc.dependOn(&fmtCode.step);
    fmtCodeAndDoc.dependOn(&fmtDoc.step);

    // ToDo: write a "release" target to update version and git hash.
}

const CompileOptions = struct {
    version: []const u8,
    option1: bool = false,
};

fn collectCompileOptions(b: *std.Build, mode: std.lang.Optimize) !CompileOptions {
    var c = CompileOptions{
        .version = try retrieveVersionFromZon(b),
    };

    if (b.option(bool, "option1", "option 1")) |o| {
        if (mode == .debug) c.option1 = o else std.debug.print(
            \\The "options1" definition is ignored, because it is only valid in Debug optimization mode.
            \\
        , .{});
    }

    return c;
}

fn retrieveVersionFromZon(b: *std.Build) ![]const u8 {
    const zonContent = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 16));
    defer b.allocator.free(zonContent);

    const needle =
        \\.version = "
    ;
    if (std.mem.indexOf(u8, zonContent, needle)) |index| {
        const start = index + needle.len;
        if (std.mem.indexOfPos(u8, zonContent, start, "\"")) |end| {
            return try b.allocator.dupe(u8, zonContent[start..end]);
        }
    }

    return error.VersionNotFoundInZon;
}
