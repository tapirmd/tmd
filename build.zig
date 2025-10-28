const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // options

    const compileOptions = collectCompileOptions(b, optimize);

    // list module

    const listLibModule = b.addModule("list", .{
        .root_source_file = b.path("library/list/list.zig"),
        .target = target,
        .optimize = optimize,
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
        .target = target,
        .optimize = optimize,
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
        .target = target,
        .optimize = optimize,
    });
    tmdLibModule.addImport("list", listLibModule);
    tmdLibModule.addImport("tree", treeLibModule);

    const libOptions = b.addOptions();
    libOptions.addOption(bool, "option1", compileOptions.option1);
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

    //const toolchainTest = b.addTest(.{
    //    .name = "toolchain unit test",
    //    .root_module = b.createModule(.{
    //        .root_source_file = b.path("toolchain/tmd/tests.zig"),
    //        .target = target,
    //    }),
    //});
    //const runToolchainTest = b.addRunArtifact(toolchainTest);

    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&runListLibTest.step);
    testStep.dependOn(&runTreeLibTest.step);
    testStep.dependOn(&runCoreLibTest.step);
    testStep.dependOn(&runCoreLibInternalTest.step);
    testStep.dependOn(&runWasmLibTest.step);
    //testStep.dependOn(&runToolchainTest.step);

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

    // run toolchain cmd

    const runTmdCommand = b.addRunArtifact(toolchainCommand);
    if (b.args) |args| runTmdCommand.addArgs(args);

    const runStep = b.step("run", "Run tmd command");
    runStep.dependOn(&runTmdCommand.step);

    // wasm

    const wasmTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasmOptimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const wasm = b.addExecutable(.{
        .name = "tmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("library/tmd-wasm/wasm.zig"),
            .target = wasmTarget,
            .optimize = wasmOptimize,
        }),
    });

    // <https://github.com/ziglang/zig/issues/8633>
    //wasm.global_base = 8192; // What is the meaning? Some runtimes have requirements on this?
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // It looks the program itself need minimum memory between 1M and 1.5M initially.
    // The program will dynamically allocate about 10M at run time.
    // But why is the max_memory required to be set so large?
    wasm.max_memory = (1 << 24) + (1 << 21); // 18M

    wasm.root_module.addImport("tmd", tmdLibModule);
    wasm.root_module.addImport("list", listLibModule);
    wasm.root_module.addImport("tree", treeLibModule);
    const installWasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } });

    const wasmStep = b.step("wasm", "Build wasm lib");
    wasmStep.dependOn(&installWasm.step);

    // js

    // ToDo: write a replace-file-placeholder cmd
    //       and use LazyPath, Build.Step.Run.captureStdOut and Build.addWriteFile
    //       to unify/simplfy the GenerateJsLib and CompletePlayPage steps.

    const GenerateJsLib = struct {
        step: std.Build.Step,
        jsLibPath: std.Build.LazyPath,
        dest_sub_path: []const u8 = "tmd-with-wasm.js",
        wasmInstallArtifact: *std.Build.Step.InstallArtifact,

        pub fn create(theBuild: *std.Build, jsLibPath: std.Build.LazyPath, wasmInstall: *std.Build.Step.InstallArtifact) !*@This() {
            const self = try theBuild.allocator.create(@This());
            self.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "generate JavaScript lib",
                    .owner = theBuild,
                    .makeFn = make,
                }),
                .jsLibPath = jsLibPath,
                .wasmInstallArtifact = wasmInstall,
            };
            return self;
        }

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const self: *@This() = @alignCast(@fieldParentPtr("step", step));

            const needle = "<wasm-file-as-base64-string>";

            const theBuild = step.owner;
            var dir = try self.jsLibPath.getPath3(theBuild, null).openDir("", .{});
            defer dir.close();
            const oldContent = try dir.readFileAlloc(theBuild.allocator, "tmd-with-wasm-template.js", 1 << 19);
            if (std.mem.indexOf(u8, oldContent, needle)) |k| {
                const libDir = try std.fs.openDirAbsolute(theBuild.lib_dir, .{});
                const wasmFileName = self.wasmInstallArtifact.dest_sub_path;
                const wasmContent = try libDir.readFileAlloc(theBuild.allocator, wasmFileName, 1 << 19);
                const file = try libDir.createFile(self.dest_sub_path, .{ .truncate = true });
                defer file.close();

                var buffer: [4096]u8 = undefined;
                var writer = file.writer(&buffer);
                const w = &writer.interface;
                try w.writeAll(oldContent[0..k]);
                try std.base64.standard.Encoder.encodeWriter(w, wasmContent);
                try w.writeAll(oldContent[k + needle.len ..]);
                try w.flush();
            } else return error.WasmNeedleNotFound;
        }
    };

    const installJsLib = try GenerateJsLib.create(b, b.path("library/tmd-js"), installWasm);
    installJsLib.step.dependOn(&installWasm.step);

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

    const CompletePlayPage = struct {
        step: std.Build.Step,
        docPagesPath: std.Build.LazyPath,
        jsLibInstallArtifact: *GenerateJsLib,

        pub fn create(theBuild: *std.Build, docPath: std.Build.LazyPath, jsLibInstall: *GenerateJsLib) !*@This() {
            const self = try theBuild.allocator.create(@This());
            self.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "complete play page",
                    .owner = theBuild,
                    .makeFn = make,
                }),
                .docPagesPath = docPath,
                .jsLibInstallArtifact = jsLibInstall,
            };
            return self;
        }

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const self: *@This() = @alignCast(@fieldParentPtr("step", step));

            const needle = "[js-lib-file]";

            const jsLibFileName = self.jsLibInstallArtifact.dest_sub_path;
            const theBuild = step.owner;
            var dir = try self.docPagesPath.getPath3(theBuild, null).openDir("", .{});
            defer dir.close();
            var outputDir = try dir.openDir("@tmd-build", .{});
            defer outputDir.close();
            var outputPagesDir = try outputDir.openDir("pages", .{});
            defer outputPagesDir.close();
            const oldContent = try outputPagesDir.readFileAlloc(theBuild.allocator, "play.html", 1 << 19);
            if (std.mem.indexOf(u8, oldContent, needle)) |k| {
                const libDir = try std.fs.openDirAbsolute(theBuild.lib_dir, .{});
                const jsLibContent = try libDir.readFileAlloc(theBuild.allocator, jsLibFileName, 1 << 19);
                const file = try outputPagesDir.createFile("play.html", .{ .truncate = true });
                defer file.close();
                
                var buffer: [4096]u8 = undefined;
                var writer = file.writer(&buffer);
                const w = &writer.interface;
                try w.writeAll(oldContent[0..k]);
                try w.writeAll(jsLibContent);
                try w.writeAll(oldContent[k + needle.len ..]);
                try w.flush();
            } else return error.JsLibNeedleNotFound;
        }
    };

    const websitePagesPath = b.path("documentation/pages");
    const completePlayPage = try CompletePlayPage.create(b, websitePagesPath, installJsLib);
    completePlayPage.step.dependOn(&buildWebsite.step);

    const buildDoc = b.step("doc", "Build documentation");
    buildDoc.dependOn(&completePlayPage.step);

    RequireOptimizeMode_ReleaseSmall.current = optimize;
    // ToDo: it looks only the root steps (specified in "go build" commands)
    //       will call their .makeFn functions. Dependency steps will not call.
    //       So, here, set .makeFn for both of the two steps.
    //       And it looks, the "make" methods of custom steps (like CompletePlayPage)
    //       will always be called. So an alternative way is not add
    //       RequireOptimizeMode custom step and let the "wasm" step depend on it.
    buildDoc.makeFn = RequireOptimizeMode_ReleaseSmall.check;
    wasmStep.makeFn = RequireOptimizeMode_ReleaseSmall.check;

    // fmt

    const fmtCode = b.addFmt(.{
        .paths = &.{
            ".",
        },
    });
    const fmtCodeAndDoc = b.step("fmt", "Format code and documentation");
    fmtCodeAndDoc.dependOn(&fmtCode.step);
    fmtCodeAndDoc.dependOn(&fmtDoc.step);

    // ToDo: write a "release" target to update version and git hash.
}

const CompileOptions = struct {
    option1: bool = false,
};

fn collectCompileOptions(b: *std.Build, mode: std.builtin.OptimizeMode) CompileOptions {
    var c = CompileOptions{};

    if (b.option(bool, "option1", "option 1")) |o| {
        if (mode == .Debug) c.option1 = o else std.debug.print(
            \\The "options1" definition is ignored, because it is only valid in Debug optimization mode.
            \\
        , .{});
    }

    return c;
}

const RequireOptimizeMode_ReleaseSmall = struct {
    const required: std.builtin.OptimizeMode = .ReleaseSmall;
    var current: std.builtin.OptimizeMode = undefined;

    fn check(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        if (current == required) return;

        std.debug.print(
            \\The "{s}" step requires "{s}" optimization mode (-Doptimize={s}), but it is "{s}" now.
            \\
        , .{ step.name, @tagName(required), @tagName(required), @tagName(current) });
        return error.InvalidOptimizeMode;
    }
};
