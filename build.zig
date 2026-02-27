const std = @import("std");
const zine = @import("zine");

const layouts = [_][]const u8{ "default", "pattern-library", "semantica" };

pub fn build(b: *std.Build) void {
    const gen = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate.zig"),
            .target = b.graph.host,
        }),
    });

    // Release pipeline: no pattern library, no drafts
    const rel = addPipeline(b, gen, false);
    const release_opts: zine.Options = .{
        .website_root = rel.staging,
        .output_path = "zine-release",
        .force = true,
        .build_assets = rel.assets[0..rel.count],
    };
    const release = zine.website(b, release_opts);
    const install = b.getInstallStep();
    install.dependOn(&release.step);
    install.dependOn(&b.addInstallDirectory(.{
        .source_dir = rel.staging,
        .install_dir = .prefix,
        .install_subdir = "zine-in",
    }).step);

    // Dev pipeline: pattern library included, drafts enabled
    const dev = addPipeline(b, gen, true);
    const dev_opts: zine.Options = .{
        .website_root = dev.staging,
        .output_path = "zine-draft",
        .force = true,
        .build_assets = dev.assets[0..dev.count],
    };

    // zig build draft
    const draft_release = zine.website(b, dev_opts);
    draft_release.addArg("--drafts");
    const draft_step = b.step("draft", "Build with pattern library and draft pages");
    draft_step.dependOn(&draft_release.step);
    draft_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = dev.staging,
        .install_dir = .prefix,
        .install_subdir = "zine-in",
    }).step);

    // zig build serve
    const dev_serve = zine.serve(b, dev_opts);
    dev_serve.addArg("--drafts");
    const serve_step = b.step("serve", "Start dev server with pattern library and drafts");
    serve_step.dependOn(&dev_serve.step);
}

const Pipeline = struct {
    staging: std.Build.LazyPath,
    assets: [layouts.len * 2]zine.BuildAsset,
    count: usize,
};

fn addPipeline(b: *std.Build, gen: *std.Build.Step.Compile, dev: bool) Pipeline {
    const run = b.addRunArtifact(gen);

    run.addDirectoryArg(b.path("layouts"));
    run.addDirectoryArg(b.path("data"));
    run.addDirectoryArg(b.path("pages"));
    run.addDirectoryArg(b.path("assets"));
    run.addFileArg(b.path("data/site.yaml"));

    const staging = run.addOutputDirectoryArg("zine-in");

    var result: Pipeline = .{
        .staging = staging,
        .assets = undefined,
        .count = 0,
    };

    for (&layouts) |layout_name| {
        const css_file = b.fmt("{s}.css", .{layout_name});
        const css_output = run.addOutputFileArg(css_file);
        result.assets[result.count] = .{
            .name = css_file,
            .lp = css_output,
            .install_path = css_file,
        };
        result.count += 1;

        const js_file = b.fmt("{s}.js", .{layout_name});
        const js_output = run.addOutputFileArg(js_file);
        result.assets[result.count] = .{
            .name = js_file,
            .lp = js_output,
            .install_path = js_file,
        };
        result.count += 1;
    }

    // Comma-separated layout names
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

    return result;
}
