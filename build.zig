const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config = collectConfig(b, optimize);

    // lib (for C users)
    // ToDo: Need many exported functions, including field setter/getter.
    //
    //const tmdLib = b.addStaticLibrary(.{
    //    .name = "tmd",
    //    .root_source_file = b.path("lib/tmd-for-c.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const installLib = b.addInstallArtifact(tmdLib, .{});
    //
    //const libStep = b.step("lib", "Install lib");
    //libStep.dependOn(&installLib.step);

    // tmd module

    const tmdLibModule = b.addModule("tmd", .{
        .root_source_file = b.path("lib/tmd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libOptions = b.addOptions();
    libOptions.addOption(bool, "dump_ast", config.dumpAST);
    tmdLibModule.addOptions("config", libOptions);

    // return early if this is used as a dependency.
    _ = b.path("lib-tests").getPath3(b, null).statFile("alla.zig") catch return;

    // test


    const libTest = b.addTest(.{
        .name = "lib unit test",
        .root_source_file = b.path("lib-tests/all.zig"),
        .target = target,
    });
    libTest.root_module.addImport("tmd", tmdLibModule); // just use file imports instead of module import
    const runLibTest = b.addRunArtifact(libTest);

    const libInternalTest = b.addTest(.{
        .name = "lib internal unit test",
        .root_source_file = b.path("lib/tests.zig"),
        .target = target,
    });
    const runLibInternalTest = b.addRunArtifact(libInternalTest);

    const cmdTest = b.addTest(.{
        .name = "cmd unit test",
        .root_source_file = b.path("cmd/tests.zig"),
        .target = target,
    });
    const runCmdTest = b.addRunArtifact(cmdTest);

    const wasmTest = b.addTest(.{
        .name = "wasm unit test",
        .root_source_file = b.path("wasm/tests.zig"),
        .target = target, // ToDo: related to wasmTarget?
    });
    const runWasmTest = b.addRunArtifact(wasmTest);

    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&runLibTest.step);
    testStep.dependOn(&runLibInternalTest.step);
    testStep.dependOn(&runCmdTest.step);
    testStep.dependOn(&runWasmTest.step);

    // cmd (the default target)

    const tmdCommand = b.addExecutable(.{
        .name = "tmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/cmd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tmdCommand.root_module.addImport("tmd", tmdLibModule);
    b.installArtifact(tmdCommand);

    // run cmd

    const runTmdCommand = b.addRunArtifact(tmdCommand);
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
            .root_source_file = b.path("wasm/wasm.zig"),
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
    const installWasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } });

    const wasmStep = b.step("wasm", "Install wasm");
    wasmStep.dependOn(&installWasm.step);

    // js

    const GenerateJsLib = struct {
        step: std.Build.Step,
        jsLibPath: std.fs.Dir,
        dest_sub_path: []const u8 = "tmd-with-wasm.js",
        wasmInstallArtifact: *std.Build.Step.InstallArtifact,

        pub fn create(theBuild: *std.Build, jsLibPath: std.fs.Dir, wasmInstall: *std.Build.Step.InstallArtifact) !*@This() {
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
            const self: *@This() = @fieldParentPtr("step", step);

            const needle = "<wasm-file-as-base64-string>";

            const theBuild = step.owner;
            const oldContent = try self.jsLibPath.readFileAlloc(theBuild.allocator, "tmd-with-wasm-template.js", 1 << 19);
            if (std.mem.indexOf(u8, oldContent, needle)) |k| {
                const libDir = try std.fs.openDirAbsolute(theBuild.lib_dir, .{ .no_follow = true, .access_sub_paths = true, .iterate = false });
                const wasmFileName = self.wasmInstallArtifact.dest_sub_path;
                const wasmContent = try libDir.readFileAlloc(theBuild.allocator, wasmFileName, 1 << 19);
                const file = try libDir.createFile(self.dest_sub_path, .{ .truncate = true });
                defer file.close();
                try file.writeAll(oldContent[0..k]);
                try std.base64.standard.Encoder.encodeWriter(file.writer(), wasmContent);
                try file.writeAll(oldContent[k + needle.len ..]);
            } else return error.WasmNeedleNotFound;
        }
    };

    const jsLibPath = b.path("js");
    const jsLibDir = try jsLibPath.getPath3(b, null).openDir("", .{ .no_follow = true, .access_sub_paths = false, .iterate = true });

    const installJsLib = try GenerateJsLib.create(b, jsLibDir, installWasm);
    installJsLib.step.dependOn(&installWasm.step);

    const jsLibStep = b.step("js", "Install JavaScript lib");
    jsLibStep.dependOn(&installJsLib.step);

    // doc

    const buildWebsiteCommand = b.addRunArtifact(tmdCommand);
    buildWebsiteCommand.step.dependOn(&installJsLib.step);

    const websitePagesPath = b.path("doc/pages");

    buildWebsiteCommand.setCwd(websitePagesPath);
    buildWebsiteCommand.addArg("gen");
    buildWebsiteCommand.addArg("--trial-page-css=@");
    buildWebsiteCommand.addArg("--enabled-custom-apps=html");

    const websitePagesDir = try websitePagesPath.getPath3(b, null).openDir("", .{ .no_follow = true, .access_sub_paths = false, .iterate = true });
    var walker = try websitePagesDir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".tmd")) continue;

        buildWebsiteCommand.addArg(entry.basename);
    }

    const CompletePlayPage = struct {
        step: std.Build.Step,
        docPagesPath: std.fs.Dir,
        jsLibInstallArtifact: *GenerateJsLib,

        pub fn create(theBuild: *std.Build, docPath: std.fs.Dir, jsLibInstall: *GenerateJsLib) !*@This() {
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
            const self: *@This() = @fieldParentPtr("step", step);

            const needle = "[js-lib-file]";

            const jsLibFileName = self.jsLibInstallArtifact.dest_sub_path;
            const theBuild = step.owner;
            const oldContent = try self.docPagesPath.readFileAlloc(theBuild.allocator, "play.html", 1 << 19);
            if (std.mem.indexOf(u8, oldContent, needle)) |k| {
                const libDir = try std.fs.openDirAbsolute(theBuild.lib_dir, .{ .no_follow = true, .access_sub_paths = true, .iterate = false });
                const jsLibContent = try libDir.readFileAlloc(theBuild.allocator, jsLibFileName, 1 << 19);
                const file = try self.docPagesPath.createFile("play.html", .{ .truncate = true });
                defer file.close();
                try file.writeAll(oldContent[0..k]);
                try file.writeAll(jsLibContent);
                try file.writeAll(oldContent[k + needle.len ..]);
            } else return error.JsLibNeedleNotFound;
        }
    };

    const completePlayPage = try CompletePlayPage.create(b, websitePagesDir, installJsLib);
    completePlayPage.step.dependOn(&buildWebsiteCommand.step);

    const buildDoc = b.step("doc", "Build doc");
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

    const fmt = b.addFmt(.{
        .paths = &.{
            ".",
        },
    });
    const fmtCode = b.step("fmt", "Format code");
    fmtCode.dependOn(&fmt.step);
}

const Config = struct {
    dumpAST: bool = false,
};

fn collectConfig(b: *std.Build, mode: std.builtin.OptimizeMode) Config {
    var c = Config{};

    if (b.option(bool, "dump_ast", "dump doc AST")) |dump| {
        if (mode == .Debug) c.dumpAST = dump else std.debug.print(
            \\The "dump_ast" definition is ignored, because it is only valid in Debug optimization mode.
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
