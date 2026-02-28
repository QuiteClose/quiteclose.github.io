const std = @import("std");

const layouts = [_][]const u8{ "default", "pattern-library", "semantica" };

pub fn build(b: *std.Build) void {
    const gen = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate.zig"),
            .target = b.graph.host,
        }),
    });

    const template_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template.zig"),
            .target = b.graph.host,
        }),
    });

    const test_step = b.step("test", "Run template engine tests");
    test_step.dependOn(&b.addRunArtifact(template_tests).step);

    // zig build -- release build (no pattern library, no drafts)
    const release_site = addGenerateStep(b, gen, false);
    const install = b.getInstallStep();
    install.dependOn(&b.addInstallDirectory(.{
        .source_dir = release_site,
        .install_dir = .prefix,
        .install_subdir = "site",
    }).step);

    // zig build draft -- includes pattern library and draft pages
    const draft_site = addGenerateStep(b, gen, true);
    const draft_step = b.step("draft", "Build with pattern library and draft pages");
    draft_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = draft_site,
        .install_dir = .prefix,
        .install_subdir = "site",
    }).step);

    // zig build serve -- draft build then serve with python3
    const serve_cmd = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8080", "-d" });
    serve_cmd.addDirectoryArg(draft_site);
    const serve_step = b.step("serve", "Build draft and start dev server");
    serve_step.dependOn(&serve_cmd.step);
}

fn addGenerateStep(b: *std.Build, gen: *std.Build.Step.Compile, dev: bool) std.Build.LazyPath {
    const run = b.addRunArtifact(gen);

    run.addDirectoryArg(b.path("styles"));
    run.addDirectoryArg(b.path("data"));
    run.addDirectoryArg(b.path("pages"));
    run.addDirectoryArg(b.path("assets"));
    const site_dir = run.addOutputDirectoryArg("site");

    var all_len: usize = 0;
    for (&layouts, 0..) |lname, i| {
        if (i > 0) all_len += 1;
        all_len += lname.len;
    }
    const all_layouts = b.allocator.alloc(u8, all_len) catch @panic("OOM");
    var all_pos: usize = 0;
    for (&layouts, 0..) |lname, i| {
        if (i > 0) {
            all_layouts[all_pos] = ',';
            all_pos += 1;
        }
        @memcpy(all_layouts[all_pos..][0..lname.len], lname);
        all_pos += lname.len;
    }
    run.addArg(all_layouts);

    if (dev) run.addArg("--dev");

    return site_dir;
}
