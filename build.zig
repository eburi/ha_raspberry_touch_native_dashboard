const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Shared options (can only call these once)
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // WASM target (dashboard.wasm)
    // ---------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{}),
    });

    // Get LVGL dependency
    const lvgl_dep = b.dependency("lvgl", .{});

    // Collect all LVGL C source files
    const lvgl_c_files = collectLvglSources(b, lvgl_dep) catch |err| {
        std.log.err("Failed to collect LVGL sources: {}", .{err});
        return err;
    };

    // WASM executable (our Zig code + LVGL C)
    const wasm_lib = b.addExecutable(.{
        .name = "dashboard",
        .root_source_file = b.path("src/wasm/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Entry point disabled for WASM (we use exported functions)
    wasm_lib.entry = .disabled;

    // Export WASM memory so JS can access the framebuffer
    wasm_lib.export_memory = true;
    // Start with 64MB of memory (1024 pages * 64KB)
    wasm_lib.initial_memory = 64 * 1024 * 1024;
    // Allow growth up to 256MB
    wasm_lib.max_memory = 256 * 1024 * 1024;

    // Dynamic exports (export all `export fn` functions)
    wasm_lib.rdynamic = true;

    // Add LVGL include paths
    // IMPORTANT: wasm/include MUST come first — it provides an inttypes.h shim
    // that replaces Zig's built-in version (which does #include_next and fails
    // on freestanding targets).
    wasm_lib.addIncludePath(b.path("src/wasm/include")); // inttypes.h shim
    wasm_lib.addIncludePath(lvgl_dep.path(""));      // For lvgl.h
    wasm_lib.addIncludePath(lvgl_dep.path("src"));   // For internal includes
    wasm_lib.addIncludePath(b.path("."));             // For lv_conf.h

    // Add LVGL C source files to the WASM build
    wasm_lib.addCSourceFiles(.{
        .root = lvgl_dep.path(""),
        .files = lvgl_c_files,
        .flags = &.{
            "-DLV_CONF_INCLUDE_SIMPLE=1",
            "-std=c99",
            "-fno-sanitize=undefined",
            "-Wno-implicit-function-declaration",
            "-D__wasm__",
        },
    });

    // Add custom font C files (FontAwesome 6 icons converted via lv_font_conv)
    wasm_lib.addCSourceFiles(.{
        .files = &.{
            "src/wasm/fa_icons_28.c",
            "src/wasm/fa_icons_20.c",
        },
        .flags = &.{
            "-DLV_LVGL_H_INCLUDE_SIMPLE=1",
            "-DLV_CONF_INCLUDE_SIMPLE=1",
            "-std=c99",
            "-fno-sanitize=undefined",
            "-D__wasm__",
        },
    });

    // Install the WASM binary
    const install_wasm = b.addInstallArtifact(wasm_lib, .{});
    const wasm_step = b.step("wasm", "Build the WASM dashboard module");
    wasm_step.dependOn(&install_wasm.step);

    // Also copy to web/ directory for easy serving during development
    const copy_wasm = b.addInstallFile(wasm_lib.getEmittedBin(), "../web/dashboard.wasm");
    wasm_step.dependOn(&copy_wasm.step);

    // ---------------------------------------------------------------
    // Server target (lvgl-server)
    // ---------------------------------------------------------------
    // Only build server for non-WASM native targets
    if (native_target.result.os.tag != .freestanding) {
        const zap_dep = b.dependency("zap", .{
            .target = native_target,
            .optimize = optimize,
        });

        const server_exe = b.addExecutable(.{
            .name = "lvgl-server",
            .root_source_file = b.path("src/server/main.zig"),
            .target = native_target,
            .optimize = optimize,
        });

        server_exe.root_module.addImport("zap", zap_dep.module("zap"));

        const install_server = b.addInstallArtifact(server_exe, .{});
        const server_step = b.step("server", "Build the native web server");
        server_step.dependOn(&install_server.step);

        // Default step builds both
        b.default_step.dependOn(&install_wasm.step);
        b.default_step.dependOn(&install_server.step);

        // Run step
        const run_server = b.addRunArtifact(server_exe);
        run_server.step.dependOn(&install_wasm.step); // Ensure WASM is built first
        if (b.args) |args| {
            run_server.addArgs(args);
        }
        const run_step = b.step("run", "Build and run the server");
        run_step.dependOn(&run_server.step);
    } else {
        // WASM-only build
        b.default_step.dependOn(&install_wasm.step);
    }
}

/// Collect all .c files from LVGL's src/ directory recursively.
/// Returns a list of relative paths (relative to the LVGL root).
fn collectLvglSources(b: *std.Build, lvgl_dep: *std.Build.Dependency) ![]const []const u8 {
    var sources = std.ArrayList([]const u8).init(b.allocator);

    const lvgl_path = lvgl_dep.path("src").getPath(b);

    // Walk the directory tree
    var walker = try std.fs.openDirAbsolute(lvgl_path, .{ .iterate = true });
    defer walker.close();

    var iter = try walker.walk(b.allocator);
    defer iter.deinit();

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.path;

        // Only .c files
        if (!std.mem.endsWith(u8, name, ".c")) continue;

        // Skip demos and examples
        if (std.mem.startsWith(u8, name, "demos/")) continue;
        if (std.mem.startsWith(u8, name, "examples/")) continue;

        // Prepend "src/" since paths are relative to LVGL root
        const full_rel = try std.fmt.allocPrint(b.allocator, "src/{s}", .{name});
        try sources.append(full_rel);
    }

    return sources.toOwnedSlice();
}
