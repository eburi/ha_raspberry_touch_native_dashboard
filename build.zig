const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Shared options (can only call these once)
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zap_dep = b.dependency("zap", .{
        .target = native_target,
        .optimize = optimize,
    });

    // Get LVGL dependency (used by tests, WASM, and server targets)
    const lvgl_dep = b.dependency("lvgl", .{});

    // Collect all LVGL C source files
    const lvgl_c_files = collectLvglSources(b, lvgl_dep) catch |err| {
        std.log.err("Failed to collect LVGL sources: {}", .{err});
        return err;
    };

    // ---------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------
    const native_tests = b.addTest(.{
        .root_source_file = b.path("tests/test_main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    native_tests.root_module.addImport("probe", b.createModule(.{
        .root_source_file = b.path("src/native/probe.zig"),
        .target = native_target,
        .optimize = optimize,
    }));

    // Create lv module for test targets (fbdev needs it)
    const test_lv_mod = b.createModule(.{
        .root_source_file = b.path("src/lv.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    test_lv_mod.addIncludePath(lvgl_dep.path(""));
    test_lv_mod.addIncludePath(lvgl_dep.path("src"));
    test_lv_mod.addIncludePath(b.path("."));
    test_lv_mod.addIncludePath(b.path("src/generated_icons"));

    // Create input module for test targets (evdev needs it)
    const test_input_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    test_input_mod.addImport("lv", test_lv_mod);
    test_input_mod.addIncludePath(lvgl_dep.path(""));
    test_input_mod.addIncludePath(lvgl_dep.path("src"));
    test_input_mod.addIncludePath(b.path("."));

    const test_fbdev_mod = b.createModule(.{
        .root_source_file = b.path("src/native/fbdev.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    test_fbdev_mod.addImport("lv", test_lv_mod);
    test_fbdev_mod.addIncludePath(lvgl_dep.path(""));
    test_fbdev_mod.addIncludePath(lvgl_dep.path("src"));
    test_fbdev_mod.addIncludePath(b.path("."));
    native_tests.root_module.addImport("fbdev", test_fbdev_mod);

    const test_evdev_mod = b.createModule(.{
        .root_source_file = b.path("src/native/evdev.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    test_evdev_mod.addImport("input", test_input_mod);
    native_tests.root_module.addImport("evdev", test_evdev_mod);

    const ha_client_mod = b.createModule(.{
        .root_source_file = b.path("src/server/ha_client.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    ha_client_mod.addImport("zap", zap_dep.module("zap"));
    native_tests.root_module.addImport("ha_client", ha_client_mod);
    native_tests.root_module.addImport("zap", zap_dep.module("zap"));

    const run_native_tests = b.addRunArtifact(native_tests);
    const test_step = b.step("test", "Run native unit tests");
    test_step.dependOn(&run_native_tests.step);

    // ---------------------------------------------------------------
    // WASM target (dashboard.wasm)
    // ---------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{}),
    });

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
    wasm_lib.addIncludePath(lvgl_dep.path("")); // For lvgl.h
    wasm_lib.addIncludePath(lvgl_dep.path("src")); // For internal includes
    wasm_lib.addIncludePath(b.path(".")); // For lv_conf.h

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

    // Add generated Tabler icon C assets (rasterized SVG -> LVGL image descriptors)
    wasm_lib.addCSourceFiles(.{
        .files = &.{
            "src/generated_icons/tabler_icons.c",
        },
        .flags = &.{
            "-DLV_LVGL_H_INCLUDE_SIMPLE=1",
            "-DLV_CONF_INCLUDE_SIMPLE=1",
            "-std=c99",
            "-fno-sanitize=undefined",
            "-D__wasm__",
        },
    });

    // Add generated_icons include path so tabler_icons.c can find tabler_icons.h
    wasm_lib.addIncludePath(b.path("src/generated_icons"));

    // -----------------------------------------------------------
    // Shared modules — platform-independent code in src/
    // These are imported by name from platform-specific code
    // (e.g., src/wasm/main.zig uses @import("lv"), @import("dashboard"), etc.)
    // -----------------------------------------------------------
    const lv_mod = b.createModule(.{
        .root_source_file = b.path("src/lv.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    // lv.zig uses @cImport — it needs the same LVGL include paths
    lv_mod.addIncludePath(b.path("src/wasm/include"));
    lv_mod.addIncludePath(lvgl_dep.path(""));
    lv_mod.addIncludePath(lvgl_dep.path("src"));
    lv_mod.addIncludePath(b.path("."));
    lv_mod.addIncludePath(b.path("src/generated_icons"));

    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    // input.zig imports lv by module name
    input_mod.addImport("lv", lv_mod);
    input_mod.addIncludePath(b.path("src/wasm/include"));
    input_mod.addIncludePath(lvgl_dep.path(""));
    input_mod.addIncludePath(lvgl_dep.path("src"));
    input_mod.addIncludePath(b.path("."));

    const dashboard_mod = b.createModule(.{
        .root_source_file = b.path("src/dashboard.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    // dashboard.zig imports lv by module name
    dashboard_mod.addImport("lv", lv_mod);
    dashboard_mod.addIncludePath(b.path("src/wasm/include"));
    dashboard_mod.addIncludePath(lvgl_dep.path(""));
    dashboard_mod.addIncludePath(lvgl_dep.path("src"));
    dashboard_mod.addIncludePath(b.path("."));
    dashboard_mod.addIncludePath(b.path("src/generated_icons"));

    // Register shared modules on the WASM executable so wasm/main.zig
    // and wasm/display.zig can use @import("lv"), @import("input"), etc.
    wasm_lib.root_module.addImport("lv", lv_mod);
    wasm_lib.root_module.addImport("input", input_mod);
    wasm_lib.root_module.addImport("dashboard", dashboard_mod);

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
        const server_exe = b.addExecutable(.{
            .name = "lvgl-server",
            .root_source_file = b.path("src/server/main.zig"),
            .target = native_target,
            .optimize = optimize,
        });

        server_exe.root_module.addImport("zap", zap_dep.module("zap"));

        // ----------------------------------------------------------
        // Native shared modules (same code as WASM, different target)
        // ----------------------------------------------------------
        const native_lv_mod = b.createModule(.{
            .root_source_file = b.path("src/lv.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_lv_mod.addIncludePath(lvgl_dep.path(""));
        native_lv_mod.addIncludePath(lvgl_dep.path("src"));
        native_lv_mod.addIncludePath(b.path("."));
        native_lv_mod.addIncludePath(b.path("src/generated_icons"));

        const native_input_mod = b.createModule(.{
            .root_source_file = b.path("src/input.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_input_mod.addImport("lv", native_lv_mod);
        native_input_mod.addIncludePath(lvgl_dep.path(""));
        native_input_mod.addIncludePath(lvgl_dep.path("src"));
        native_input_mod.addIncludePath(b.path("."));

        const native_dashboard_mod = b.createModule(.{
            .root_source_file = b.path("src/dashboard.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_dashboard_mod.addImport("lv", native_lv_mod);
        native_dashboard_mod.addIncludePath(lvgl_dep.path(""));
        native_dashboard_mod.addIncludePath(lvgl_dep.path("src"));
        native_dashboard_mod.addIncludePath(b.path("."));
        native_dashboard_mod.addIncludePath(b.path("src/generated_icons"));

        // Native hardware modules
        const native_fbdev_mod = b.createModule(.{
            .root_source_file = b.path("src/native/fbdev.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_fbdev_mod.addImport("lv", native_lv_mod);
        native_fbdev_mod.addIncludePath(lvgl_dep.path(""));
        native_fbdev_mod.addIncludePath(lvgl_dep.path("src"));
        native_fbdev_mod.addIncludePath(b.path("."));

        const native_evdev_mod = b.createModule(.{
            .root_source_file = b.path("src/native/evdev.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_evdev_mod.addImport("input", native_input_mod);

        const native_probe_mod = b.createModule(.{
            .root_source_file = b.path("src/native/probe.zig"),
            .target = native_target,
            .optimize = optimize,
        });

        // Native display module (orchestrates fbdev + evdev + dashboard)
        const native_display_mod = b.createModule(.{
            .root_source_file = b.path("src/native/main.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        native_display_mod.addImport("lv", native_lv_mod);
        native_display_mod.addImport("input", native_input_mod);
        native_display_mod.addImport("dashboard", native_dashboard_mod);
        native_display_mod.addImport("fbdev", native_fbdev_mod);
        native_display_mod.addImport("evdev", native_evdev_mod);
        native_display_mod.addImport("probe", native_probe_mod);
        native_display_mod.addIncludePath(lvgl_dep.path(""));
        native_display_mod.addIncludePath(lvgl_dep.path("src"));
        native_display_mod.addIncludePath(b.path("."));

        // Register native_display module on the server so main.zig can import it
        server_exe.root_module.addImport("native_display", native_display_mod);

        // Add LVGL C sources to the server build (for native rendering)
        server_exe.addIncludePath(lvgl_dep.path(""));
        server_exe.addIncludePath(lvgl_dep.path("src"));
        server_exe.addIncludePath(b.path("."));
        server_exe.addIncludePath(b.path("src/generated_icons"));

        server_exe.addCSourceFiles(.{
            .root = lvgl_dep.path(""),
            .files = lvgl_c_files,
            .flags = &.{
                "-DLV_CONF_INCLUDE_SIMPLE=1",
                "-std=c99",
                "-fno-sanitize=undefined",
                "-Wno-implicit-function-declaration",
            },
        });

        // Add generated icon C assets for native target
        server_exe.addCSourceFiles(.{
            .files = &.{
                "src/generated_icons/tabler_icons.c",
            },
            .flags = &.{
                "-DLV_LVGL_H_INCLUDE_SIMPLE=1",
                "-DLV_CONF_INCLUDE_SIMPLE=1",
                "-std=c99",
                "-fno-sanitize=undefined",
            },
        });

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
