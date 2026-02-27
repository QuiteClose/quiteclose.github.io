const std = @import("std");
const yaml = @import("yaml.zig");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const CssJsPair = struct { css: []const u8, js: []const u8 };

/// Usage: generate-layout <layouts_dir> <data_dir> <pages_dir> <assets_dir> <site_yaml>
///        <staging_dir> <css_1> <js_1> <css_2> <js_2> ... <all_layouts>
///
/// Assembles a self-contained zine-in staging directory and generates
/// CSS/JS build assets for each layout.
pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var args = std.process.args();
    _ = args.skip();

    const layouts_dir_path = args.next() orelse fatal("missing layouts_dir argument");
    const data_dir_path = args.next() orelse fatal("missing data_dir argument");
    const pages_dir_path = args.next() orelse fatal("missing pages_dir argument");
    const assets_dir_path = args.next() orelse fatal("missing assets_dir argument");
    const site_yaml_path = args.next() orelse fatal("missing site_yaml argument");
    const staging_dir_path = args.next() orelse fatal("missing staging_dir argument");

    const layouts_dir = std.fs.cwd().openDir(layouts_dir_path, .{ .iterate = true }) catch |err|
        fatalFmt("cannot open layouts dir '{s}': {}", .{ layouts_dir_path, err });
    const data_dir = std.fs.cwd().openDir(data_dir_path, .{}) catch |err|
        fatalFmt("cannot open data dir '{s}': {}", .{ data_dir_path, err });

    var pairs: [16]CssJsPair = undefined;
    var pair_count: usize = 0;
    while (true) {
        const css_path = args.next() orelse break;
        // Check if this is actually the all_layouts arg (no more pairs)
        if (std.mem.indexOfScalar(u8, css_path, ',') != null or !std.mem.endsWith(u8, css_path, ".css")) {
            const all_layouts = css_path;
            const dev = if (args.next()) |flag| std.mem.eql(u8, flag, "--dev") else false;
            processAll(a, layouts_dir, data_dir, pages_dir_path, assets_dir_path, site_yaml_path, staging_dir_path, &pairs, pair_count, all_layouts, dev);
            return;
        }
        const js_path = args.next() orelse fatal("expected JS output path after CSS output path");
        pairs[pair_count] = .{ .css = css_path, .js = js_path };
        pair_count += 1;
    }

    fatal("missing all_layouts argument");
}

fn processAll(
    a: Allocator,
    layouts_dir: Dir,
    data_dir: Dir,
    pages_dir_path: []const u8,
    assets_dir_path: []const u8,
    site_yaml_path: []const u8,
    staging_dir_path: []const u8,
    pairs: []const CssJsPair,
    pair_count: usize,
    all_layouts: []const u8,
    dev: bool,
) void {
    // Parse layout names
    var layout_names: [16][]const u8 = undefined;
    var layout_count: usize = 0;
    var split = std.mem.splitScalar(u8, all_layouts, ',');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        layout_names[layout_count] = name;
        layout_count += 1;
    }

    if (pair_count != layout_count)
        fatalFmt("expected {d} CSS/JS pairs but got {d}", .{ layout_count, pair_count });

    // Create staging directory structure
    var staging_dir = std.fs.cwd().makeOpenPath(staging_dir_path, .{}) catch |err|
        fatalFmt("cannot create staging dir '{s}': {}", .{ staging_dir_path, err });

    // 1. Generate zine.ziggy from site.yaml + layout manifests
    generateZineZiggy(a, layouts_dir, site_yaml_path, staging_dir_path, layout_names[0..layout_count]) catch |err|
        fatalFmt("cannot generate zine.ziggy: {}", .{err});

    // 2. Copy pages/ -> staging/content/
    copyDirRecursive(pages_dir_path, staging_dir_path, "content") catch |err|
        fatalFmt("cannot copy pages to staging: {}", .{err});

    // 3. Copy assets/ -> staging/assets/
    copyDirRecursive(assets_dir_path, staging_dir_path, "assets") catch |err|
        fatalFmt("cannot copy assets to staging: {}", .{err});

    // 4. Flatten templates into staging/layouts/
    flattenTemplates(a, layouts_dir, staging_dir_path, layout_names[0..layout_count]) catch |err|
        fatalFmt("cannot flatten templates: {}", .{err});

    // 5. Process each layout: generate CSS, JS, and (in dev mode) pattern library
    for (layout_names[0..layout_count], 0..) |layout_name, i| {
        processLayout(a, layouts_dir, data_dir, layout_name, pairs[i].css, pairs[i].js) catch |err|
            fatalFmt("error processing layout '{s}': {}", .{ layout_name, err });

        if (dev) {
            const staging_content = std.fmt.allocPrint(a, "{s}/content", .{staging_dir_path}) catch @panic("OOM");
            const staging_layouts = std.fmt.allocPrint(a, "{s}/layouts", .{staging_dir_path}) catch @panic("OOM");
            generatePatternLibrary(a, layouts_dir, data_dir, layout_name, staging_content, staging_layouts, all_layouts) catch |err|
                fatalFmt("error generating pattern library for '{s}': {}", .{ layout_name, err });
        }
    }

    staging_dir.close();
}

fn generateZineZiggy(
    a: Allocator,
    layouts_dir: Dir,
    site_yaml_path: []const u8,
    staging_dir_path: []const u8,
    layout_names: []const []const u8,
) !void {
    const site_src = try std.fs.cwd().readFileAlloc(a, site_yaml_path, 1 << 20);
    const site = try yaml.parse(a, site_src);
    const title = if (site.get("title")) |v| v.str() orelse "@QuiteClose" else "@QuiteClose";
    const host = if (site.get("host")) |v| v.str() orelse "https://quiteclose.github.io" else "https://quiteclose.github.io";

    var output = std.ArrayList(u8){};
    const w = output.writer(a);

    try w.print(
        \\Site {{
        \\    .title = "{s}",
        \\    .host_url = "{s}",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\
    , .{ title, host });

    // Collect static_assets from layout manifests (font references)
    var static_assets = std.ArrayList([]const u8){};
    for (layout_names) |layout_name| {
        const manifest_path = try std.fmt.allocPrint(a, "{s}/layout.yaml", .{layout_name});
        const manifest_src = layouts_dir.readFileAlloc(a, manifest_path, 1 << 20) catch continue;
        const manifest = yaml.parse(a, manifest_src) catch continue;
        const css_list = manifest.get("css") orelse continue;
        for (css_list.list) |entry| {
            const pattern = entry.str() orelse continue;
            if (std.mem.indexOf(u8, pattern, "fonts/") != null and std.mem.endsWith(u8, pattern, ".css")) {
                const font_css = layouts_dir.readFileAlloc(a, pattern, 1 << 20) catch continue;
                collectFontPaths(a, font_css, &static_assets);
            }
        }
    }

    if (static_assets.items.len > 0) {
        try w.writeAll("    .static_assets = [\n");
        for (static_assets.items) |asset| {
            try w.print("        \"{s}\",\n", .{asset});
        }
        try w.writeAll("    ],\n");
    }

    try w.writeAll("}\n");

    const ziggy_path = try std.fmt.allocPrint(a, "{s}/zine.ziggy", .{staging_dir_path});
    writeGeneratedFile(ziggy_path, output.items);
}

fn collectFontPaths(a: Allocator, css: []const u8, list: *std.ArrayList([]const u8)) void {
    // Extract font file paths from url('/fonts/...') in @font-face CSS
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, css, pos, "url('")) |start| {
        const path_start = start + 5;
        if (std.mem.indexOfScalarPos(u8, css, path_start, '\'')) |path_end| {
            var font_path = css[path_start..path_end];
            if (font_path.len > 0 and font_path[0] == '/') font_path = font_path[1..];
            // Deduplicate
            var found = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, font_path)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                list.append(a, a.dupe(u8, font_path) catch @panic("OOM")) catch @panic("OOM");
            }
            pos = path_end + 1;
        } else break;
    }
}

fn copyDirRecursive(src_path: []const u8, staging_path: []const u8, dest_name: []const u8) !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    const dest_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ staging_path, dest_name });
    defer alloc.free(dest_path);

    try std.fs.cwd().makePath(dest_path);

    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const dir_dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.path });
                defer alloc.free(dir_dest);
                try std.fs.cwd().makePath(dir_dest);
            },
            .file => {
                const file_dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.path });
                defer alloc.free(file_dest);
                // Ensure parent dir exists
                if (std.mem.lastIndexOfScalar(u8, file_dest, '/')) |last_slash| {
                    std.fs.cwd().makePath(file_dest[0..last_slash]) catch {};
                }
                const content = try entry.dir.readFileAlloc(alloc, entry.basename, 1 << 24);
                defer alloc.free(content);
                const out_file = try std.fs.cwd().createFile(file_dest, .{});
                defer out_file.close();
                try out_file.writeAll(content);
            },
            else => {},
        }
    }
}

fn flattenTemplates(
    a: Allocator,
    layouts_dir: Dir,
    staging_dir_path: []const u8,
    layout_names: []const []const u8,
) !void {
    const staging_layouts = try std.fmt.allocPrint(a, "{s}/layouts", .{staging_dir_path});
    try std.fs.cwd().makePath(staging_layouts);

    // _core/html/ -> staging/layouts/templates/
    const templates_dest = try std.fmt.allocPrint(a, "{s}/templates", .{staging_layouts});
    try std.fs.cwd().makePath(templates_dest);

    var core_html = layouts_dir.openDir("_core/html", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer core_html.close();

    var core_iter = core_html.iterate();
    while (try core_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const content = try core_html.readFileAlloc(a, entry.name, 1 << 20);
        const dest_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ templates_dest, entry.name });
        writeGeneratedFile(dest_path, content);
    }

    // {layout}/html/ -> staging/layouts/ (flat)
    for (layout_names) |layout_name| {
        const html_subdir = try std.fmt.allocPrint(a, "{s}/html", .{layout_name});
        var layout_html = layouts_dir.openDir(html_subdir, .{ .iterate = true }) catch continue;
        defer layout_html.close();

        var iter = layout_html.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const content = try layout_html.readFileAlloc(a, entry.name, 1 << 20);
            const dest_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ staging_layouts, entry.name });
            writeGeneratedFile(dest_path, content);
        }
    }
}

fn processLayout(
    a: Allocator,
    layouts_dir: Dir,
    data_dir: Dir,
    layout_name: []const u8,
    css_output_path: []const u8,
    js_output_path: []const u8,
) !void {
    const manifest_path = try std.fmt.allocPrint(a, "{s}/layout.yaml", .{layout_name});
    const manifest_src = layouts_dir.readFileAlloc(a, manifest_path, 1 << 20) catch |err|
        fatalFmt("cannot read manifest '{s}': {}", .{ manifest_path, err });

    const manifest = try yaml.parse(a, manifest_src);

    var output = std.ArrayList(u8){};
    const writer = output.writer(a);

    if (manifest.get("tokens")) |tokens| {
        try generateFluidTokens(a, tokens, layout_name, writer);
    }

    const highlights = manifest.get("highlights");
    if (highlights) |hl| {
        try generateColourTokens(a, data_dir, hl, writer);
    }

    const css_list = manifest.get("css") orelse
        fatalFmt("layout '{s}' has no css list", .{layout_name});

    for (css_list.list) |entry| {
        const pattern = entry.str() orelse continue;
        try appendCssFiles(a, layouts_dir, pattern, writer);
    }

    const out_file = std.fs.cwd().createFile(css_output_path, .{}) catch |err|
        fatalFmt("cannot create output '{s}': {}", .{ css_output_path, err });
    defer out_file.close();
    out_file.writeAll(output.items) catch |err|
        fatalFmt("cannot write output '{s}': {}", .{ css_output_path, err });

    if (highlights) |hl| {
        const js_flag = if (hl.get("js")) |v| v.str() else null;
        if (js_flag != null and std.mem.eql(u8, js_flag.?, "true")) {
            try generateJsModule(a, data_dir, hl, js_output_path);
            return;
        }
    }
    // Write empty JS file if no JS module needed
    const empty_js = std.fs.cwd().createFile(js_output_path, .{}) catch |err|
        fatalFmt("cannot create JS output '{s}': {}", .{ js_output_path, err });
    empty_js.close();
}

fn appendCssFiles(
    a: Allocator,
    layouts_dir: Dir,
    pattern: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const dir_path = pattern[0 .. pattern.len - 2];
        var dir = layouts_dir.openDir(dir_path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var names = std.ArrayList([]const u8){};
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".css")) continue;
            try names.append(a, try a.dupe(u8, entry.name));
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.cmp);

        for (names.items) |name| {
            const full_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
            try appendSingleFile(a, layouts_dir, full_path, writer);
        }
    } else {
        try appendSingleFile(a, layouts_dir, pattern, writer);
    }
}

fn appendSingleFile(
    a: Allocator,
    layouts_dir: Dir,
    path: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    const content = layouts_dir.readFileAlloc(a, path, 1 << 20) catch {
        return;
    };
    try writer.print("/* {s} */\n", .{path});
    try writer.writeAll(content);
    try writer.writeByte('\n');
}

fn generateColourTokens(
    a: Allocator,
    data_dir: Dir,
    highlights: yaml.Value,
    writer: std.ArrayList(u8).Writer,
) !void {
    const default_hl = highlights.get("default");
    var default_scheme: ?[]const u8 = null;
    var default_mode: ?[]const u8 = null;
    if (default_hl) |d| {
        default_scheme = if (d.get("scheme")) |v| v.str() else null;
        default_mode = if (d.get("mode")) |v| v.str() else null;
    }

    const schemes = highlights.get("schemes") orelse return;

    for (schemes.list) |entry| {
        const spec = entry.str() orelse continue;
        const dot = std.mem.indexOfScalar(u8, spec, '.') orelse continue;
        const scheme_name = spec[0..dot];
        const mode = spec[dot + 1 ..];

        const file_path = try std.fmt.allocPrint(a, "colours/{s}.yaml", .{scheme_name});
        const scheme_src = data_dir.readFileAlloc(a, file_path, 1 << 20) catch |err|
            fatalFmt("cannot read scheme '{s}': {}", .{ file_path, err });

        const scheme = try yaml.parse(a, scheme_src);
        const variant = scheme.get(mode) orelse
            fatalFmt("scheme '{s}' has no '{s}' variant", .{ scheme_name, mode });
        const palette = variant.get("palette") orelse
            fatalFmt("scheme '{s}.{s}' has no palette", .{ scheme_name, mode });

        const is_default = if (default_scheme) |ds|
            std.mem.eql(u8, ds, scheme_name) and
                std.mem.eql(u8, default_mode orelse "", mode)
        else
            false;

        if (is_default) {
            try writer.writeAll(":root,\n");
        }
        try writer.print("[data-theme=\"{s}-{s}\"] {{\n", .{ scheme_name, mode });

        if (variant.get("styles")) |styles| {
            try emitStyleProperties(a, styles, palette, writer, "text", "color-text");
            try emitStyleProperties(a, styles, palette, writer, "background", "color-bg");
        }
        if (variant.get("syntax")) |syntax| {
            try emitSyntaxProperties(a, syntax, palette, writer);
        }

        try writer.writeAll("}\n\n");
    }
}

fn emitStyleProperties(
    a: Allocator,
    styles: yaml.Value,
    palette: yaml.Value,
    writer: std.ArrayList(u8).Writer,
    section: []const u8,
    prefix: []const u8,
) !void {
    _ = a;
    const sub = styles.get(section) orelse return;
    const map = switch (sub) {
        .map => |m| m,
        else => return,
    };
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const role = entry.key_ptr.*;
        const palette_key = entry.value_ptr.str() orelse continue;
        const hex = resolvePalette(palette, palette_key);
        try writer.print("  --{s}-{s}: {s};\n", .{ prefix, role, hex });
    }
}

fn emitSyntaxProperties(
    a: Allocator,
    syntax: yaml.Value,
    palette: yaml.Value,
    writer: std.ArrayList(u8).Writer,
) !void {
    _ = a;
    const map = switch (syntax) {
        .map => |m| m,
        else => return,
    };
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const role = entry.key_ptr.*;
        const palette_key = entry.value_ptr.str() orelse continue;
        const hex = resolvePalette(palette, palette_key);
        try writer.print("  --syntax-{s}: {s};\n", .{ role, hex });
    }
}

fn resolvePalette(palette: yaml.Value, key: []const u8) []const u8 {
    if (palette.get(key)) |v| {
        return v.str() orelse key;
    }
    return key;
}

// --- Fluid token generation (typography + spacing) ---

const SpaceSize = struct {
    label: []const u8,
    min_size: f64,
    max_size: f64,
};

fn parseFloatValue(val: ?yaml.Value) f64 {
    const s = (val orelse return 0).str() orelse return 0;
    return std.fmt.parseFloat(f64, s) catch 0;
}

fn parseUintValue(val: ?yaml.Value) usize {
    const s = (val orelse return 0).str() orelse return 0;
    return std.fmt.parseInt(usize, s, 10) catch 0;
}

fn roundTo4(n: f64) f64 {
    return @floor(n * 10000.0 + 0.5) / 10000.0;
}

fn writeRoundedFloat(writer: std.ArrayList(u8).Writer, n: f64) !void {
    const rounded = roundTo4(n);
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:.4}", .{rounded}) catch unreachable;
    var end = formatted.len;
    while (end > 1 and formatted[end - 1] == '0') end -= 1;
    if (end > 1 and formatted[end - 1] == '.') end -= 1;
    try writer.writeAll(formatted[0..end]);
}

fn writeClamp(writer: std.ArrayList(u8).Writer, min_size: f64, max_size: f64, min_vp: f64, max_vp: f64) !void {
    const is_neg = min_size > max_size;
    const clamp_min = if (is_neg) max_size else min_size;
    const clamp_max = if (is_neg) min_size else max_size;
    const d = 16.0;
    const slope = (max_size / d - min_size / d) / (max_vp / d - min_vp / d);
    const intercept = -(min_vp / d) * slope + min_size / d;

    try writer.writeAll("clamp(");
    try writeRoundedFloat(writer, clamp_min / d);
    try writer.writeAll("rem, ");
    try writeRoundedFloat(writer, intercept);
    try writer.writeAll("rem + ");
    try writeRoundedFloat(writer, slope * 100.0);
    try writer.writeAll("vw, ");
    try writeRoundedFloat(writer, clamp_max / d);
    try writer.writeAll("rem)");
}

fn checkAccessibility(min_size: f64, max_size: f64, min_width: f64, max_width: f64) ?[2]f64 {
    var mn = min_size;
    var mx = max_size;
    var mn_w = min_width;
    var mx_w = max_width;

    if (mn_w > mx_w) {
        const tw = mn_w;
        mn_w = mx_w;
        mx_w = tw;
        const ts = mn;
        mn = mx;
        mx = ts;
    }

    const slope = (mx - mn) / (mx_w - mn_w);
    if (slope == 0) return null;
    const intercept = mn - mn_w * slope;
    const lh = (5.0 * mn - 2.0 * intercept) / (2.0 * slope);
    const rh = (5.0 * intercept - 2.0 * mx) / (-slope);
    const lh2 = 3.0 * intercept / slope;

    var vals: [6]f64 = undefined;
    var count: usize = 0;

    if (mx_w < 5.0 * mn_w) {
        if (mn_w < lh and lh < mx_w) {
            vals[count] = @max(lh, mn_w);
            count += 1;
            vals[count] = mx_w;
            count += 1;
        }
        if (5.0 * mn < 2.0 * mx) {
            vals[count] = mx_w;
            count += 1;
            vals[count] = 5.0 * mn_w;
            count += 1;
        }
        if (5.0 * mn_w < rh and rh < 5.0 * mx_w) {
            vals[count] = 5.0 * mn_w;
            count += 1;
            vals[count] = @min(rh, 5.0 * mx_w);
            count += 1;
        }
    } else {
        if (mn_w < lh and lh < 5.0 * mn_w) {
            vals[count] = @max(lh, mn_w);
            count += 1;
            vals[count] = 5.0 * mn_w;
            count += 1;
        }
        if (5.0 * mn_w < lh2 and lh2 < mx_w) {
            vals[count] = @max(lh2, 5.0 * mn_w);
            count += 1;
            vals[count] = mx_w;
            count += 1;
        }
        if (mx_w < rh and rh < 5.0 * mx_w) {
            vals[count] = mx_w;
            count += 1;
            vals[count] = @min(rh, 5.0 * mx_w);
            count += 1;
        }
    }

    if (count == 0) return null;
    const first = vals[0];
    const last = vals[count - 1];
    if (@abs(last - first) < 0.1) return null;
    return .{ first, last };
}

fn spaceLabel(a: Allocator, step: i32) ![]const u8 {
    return switch (step) {
        -1 => "xs",
        0 => "s",
        1 => "m",
        2 => "l",
        3 => "xl",
        else => if (step > 3)
            try std.fmt.allocPrint(a, "{d}xl", .{step - 2})
        else
            try std.fmt.allocPrint(a, "{d}xs", .{@as(i32, 0) - step}),
    };
}

fn findSpaceSize(sizes: []const SpaceSize, label: []const u8) ?SpaceSize {
    for (sizes) |s| {
        if (std.mem.eql(u8, s.label, label)) return s;
    }
    return null;
}

fn sortFloats(slice: []f64) void {
    std.mem.sort(f64, slice, {}, struct {
        fn cmp(_: void, a_val: f64, b_val: f64) bool {
            return a_val < b_val;
        }
    }.cmp);
}

fn generateFluidTokens(
    a: Allocator,
    tokens: yaml.Value,
    layout_name: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    const viewport = tokens.get("viewport") orelse return;
    const min_vp = parseFloatValue(viewport.get("min"));
    const max_vp = parseFloatValue(viewport.get("max"));
    if (min_vp == 0 or max_vp == 0) return;

    var min_base: f64 = 16.0;
    var max_base: f64 = 16.0;

    try writer.writeAll(":root {\n");

    if (tokens.get("typography")) |typo| {
        if (typo.get("base")) |base| {
            const mb = parseFloatValue(base.get("min"));
            const xb = parseFloatValue(base.get("max"));
            if (mb > 0) min_base = mb;
            if (xb > 0) max_base = xb;
        }
        try generateTypographyTokens(a, typo, min_vp, max_vp, min_base, max_base, layout_name, writer);
    }

    if (tokens.get("spacing")) |spacing| {
        try generateSpacingTokens(a, spacing, min_vp, max_vp, min_base, max_base, writer);
    }

    try writer.writeAll("}\n\n");
}

fn generateTypographyTokens(
    a: Allocator,
    typo: yaml.Value,
    min_vp: f64,
    max_vp: f64,
    min_base: f64,
    max_base: f64,
    layout_name: []const u8,
    writer: std.ArrayList(u8).Writer,
) !void {
    const scale = typo.get("scale") orelse return;
    const steps = typo.get("steps") orelse return;
    const min_ratio = parseFloatValue(scale.get("min"));
    const max_ratio = parseFloatValue(scale.get("max"));
    const steps_above: i32 = @intCast(parseUintValue(steps.get("above")));
    const steps_below: i32 = @intCast(parseUintValue(steps.get("below")));

    const a11y_enabled = if (typo.get("accessibility_check")) |v|
        !std.mem.eql(u8, v.str() orelse "true", "false")
    else
        true;

    const Violation = struct { step: i32, range: [2]f64 };
    var violations: [32]Violation = undefined;
    var violation_count: usize = 0;

    var step: i32 = -steps_below;
    while (step <= steps_above) : (step += 1) {
        const step_f: f64 = @floatFromInt(step);
        const min_fs = min_base * std.math.pow(f64, min_ratio, step_f);
        const max_fs = max_base * std.math.pow(f64, max_ratio, step_f);

        if (a11y_enabled) {
            if (checkAccessibility(min_fs, max_fs, min_vp, max_vp)) |range| {
                if (violation_count < violations.len) {
                    violations[violation_count] = .{ .step = step, .range = range };
                    violation_count += 1;
                }
            }
        }

        try writer.print("  --size-step-{d}: ", .{step});
        try writeClamp(writer, min_fs, max_fs, min_vp, max_vp);
        try writer.writeAll(";\n");
    }

    if (violation_count > 0) {
        var msg = std.ArrayList(u8){};
        const w = msg.writer(a);
        try w.print(
            \\
            \\Accessibility check failed for layout '{s}'.
            \\
            \\The following type scale steps may prevent users from resizing text
            \\to 200% of its original size (WCAG 1.4.4 "Resize Text"). This affects
            \\people with low vision who rely on browser zoom.
            \\
            \\
        , .{layout_name});
        for (violations[0..violation_count]) |v| {
            try w.print("  --size-step-{d}: affected between {d:.0}px and {d:.0}px viewport width\n", .{
                v.step, v.range[0], v.range[1],
            });
        }
        try w.print(
            \\
            \\To fix: reduce the difference between min and max type scale ratios,
            \\or reduce the number of steps above the base.
            \\
            \\To disable this check for this layout, add to the typography section
            \\of layouts/{s}/layout.yaml:
            \\
            \\  accessibility_check: false
            \\
        , .{layout_name});
        fatal(msg.items);
    }
}

fn generateSpacingTokens(
    a: Allocator,
    spacing: yaml.Value,
    min_vp: f64,
    max_vp: f64,
    min_base: f64,
    max_base: f64,
    writer: std.ArrayList(u8).Writer,
) !void {
    var neg_mults: [16]f64 = undefined;
    var neg_count: usize = 0;
    if (spacing.get("negative")) |neg| {
        for (neg.list) |v| {
            const s = v.str() orelse continue;
            neg_mults[neg_count] = std.fmt.parseFloat(f64, s) catch continue;
            neg_count += 1;
        }
    }
    sortFloats(neg_mults[0..neg_count]);
    std.mem.reverse(f64, neg_mults[0..neg_count]);

    var pos_mults: [16]f64 = undefined;
    var pos_count: usize = 0;
    if (spacing.get("positive")) |pos| {
        for (pos.list) |v| {
            const s = v.str() orelse continue;
            pos_mults[pos_count] = std.fmt.parseFloat(f64, s) catch continue;
            pos_count += 1;
        }
    }
    sortFloats(pos_mults[0..pos_count]);

    var sizes: [32]SpaceSize = undefined;
    var size_count: usize = 0;

    {
        var i = neg_count;
        while (i > 0) {
            i -= 1;
            const s: i32 = -@as(i32, @intCast(i)) - 1;
            sizes[size_count] = .{
                .label = try spaceLabel(a, s),
                .min_size = @floor(min_base * neg_mults[i] + 0.5),
                .max_size = @floor(max_base * neg_mults[i] + 0.5),
            };
            size_count += 1;
        }
    }

    sizes[size_count] = .{
        .label = "s",
        .min_size = @floor(min_base + 0.5),
        .max_size = @floor(max_base + 0.5),
    };
    size_count += 1;

    for (pos_mults[0..pos_count], 0..) |mult, j| {
        const s: i32 = @intCast(j + 1);
        sizes[size_count] = .{
            .label = try spaceLabel(a, s),
            .min_size = @floor(min_base * mult + 0.5),
            .max_size = @floor(max_base * mult + 0.5),
        };
        size_count += 1;
    }

    for (sizes[0..size_count]) |sz| {
        try writer.print("  --space-{s}: ", .{sz.label});
        try writeClamp(writer, sz.min_size, sz.max_size, min_vp, max_vp);
        try writer.writeAll(";\n");
    }

    if (size_count > 1) {
        var j: usize = 0;
        while (j < size_count - 1) : (j += 1) {
            const prev = sizes[j];
            const next = sizes[j + 1];
            try writer.print("  --space-{s}-{s}: ", .{ prev.label, next.label });
            try writeClamp(writer, prev.min_size, next.max_size, min_vp, max_vp);
            try writer.writeAll(";\n");
        }
    }

    if (spacing.get("pairs")) |pairs_val| {
        for (pairs_val.list) |entry| {
            const pair_str = entry.str() orelse continue;
            const dash = std.mem.indexOfScalar(u8, pair_str, '-') orelse continue;
            const key_a = pair_str[0..dash];
            const key_b = pair_str[dash + 1 ..];
            const a_size = findSpaceSize(sizes[0..size_count], key_a) orelse continue;
            const b_size = findSpaceSize(sizes[0..size_count], key_b) orelse continue;
            try writer.print("  --space-{s}-{s}: ", .{ key_a, key_b });
            try writeClamp(writer, a_size.min_size, b_size.max_size, min_vp, max_vp);
            try writer.writeAll(";\n");
        }
    }
}

fn generateJsModule(
    a: Allocator,
    data_dir: Dir,
    highlights: yaml.Value,
    js_path: []const u8,
) !void {
    var output = std.ArrayList(u8){};
    const writer = output.writer(a);

    const default_hl = highlights.get("default");
    var default_scheme: []const u8 = "solarized";
    var default_mode: []const u8 = "dark";
    if (default_hl) |d| {
        if (d.get("scheme")) |v| if (v.str()) |s| {
            default_scheme = s;
        };
        if (d.get("mode")) |v| if (v.str()) |s| {
            default_mode = s;
        };
    }

    try writer.print(
        \\export default {{
        \\  default: {{ scheme: "{s}", mode: "{s}" }},
        \\  schemes: [
        \\
    , .{ default_scheme, default_mode });

    const schemes = highlights.get("schemes") orelse {
        try writer.writeAll("  ]\n};\n");
        return;
    };

    for (schemes.list) |entry| {
        const spec = entry.str() orelse continue;
        const dot = std.mem.indexOfScalar(u8, spec, '.') orelse continue;
        const scheme_name = spec[0..dot];
        const mode = spec[dot + 1 ..];

        const file_path = try std.fmt.allocPrint(a, "colours/{s}.yaml", .{scheme_name});
        const scheme_src = data_dir.readFileAlloc(a, file_path, 1 << 20) catch |err|
            fatalFmt("cannot read scheme '{s}': {}", .{ file_path, err });

        const scheme = try yaml.parse(a, scheme_src);
        const variant = scheme.get(mode) orelse continue;
        const meta = variant.get("meta") orelse continue;
        const label = if (meta.get("name")) |v| v.str() orelse spec else spec;

        try writer.print(
            \\    {{ id: "{s}-{s}", scheme: "{s}", mode: "{s}", label: "{s}" }},
            \\
        , .{ scheme_name, mode, scheme_name, mode, label });
    }

    try writer.writeAll("  ]\n};\n");

    const js_file = std.fs.cwd().createFile(js_path, .{}) catch |err|
        fatalFmt("cannot create JS output '{s}': {}", .{ js_path, err });
    defer js_file.close();
    js_file.writeAll(output.items) catch |err|
        fatalFmt("cannot write JS output '{s}': {}", .{ js_path, err });
}

// --- Pattern library generation ---

fn writeGeneratedFile(path: []const u8, content: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        std.fs.cwd().makePath(path[0..last_slash]) catch |err|
            fatalFmt("cannot create directory for '{s}': {}", .{ path, err });
    }
    const file = std.fs.cwd().createFile(path, .{}) catch |err|
        fatalFmt("cannot create '{s}': {}", .{ path, err });
    defer file.close();
    file.writeAll(content) catch |err|
        fatalFmt("cannot write '{s}': {}", .{ path, err });
}

fn clampToString(a: Allocator, min_size: f64, max_size: f64, min_vp: f64, max_vp: f64) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(a);
    try writeClamp(w, min_size, max_size, min_vp, max_vp);
    return buf.items;
}

fn generatePatternLibrary(
    a: Allocator,
    layouts_dir: Dir,
    data_dir: Dir,
    layout_name: []const u8,
    content_dir_path: []const u8,
    layouts_dir_path: []const u8,
    all_layouts_arg: ?[]const u8,
) !void {
    const manifest_path = try std.fmt.allocPrint(a, "{s}/layout.yaml", .{layout_name});
    const manifest_src = layouts_dir.readFileAlloc(a, manifest_path, 1 << 20) catch |err|
        fatalFmt("cannot read manifest '{s}': {}", .{ manifest_path, err });
    const manifest = try yaml.parse(a, manifest_src);
    const display_name = if (manifest.get("name")) |v| v.str() orelse layout_name else layout_name;

    try generatePatternTemplate(a, layout_name, display_name, layouts_dir_path);

    if (all_layouts_arg) |al| {
        try generatePatternIndex(a, layouts_dir, content_dir_path, al);
    }

    try generatePatternOverview(a, manifest, layout_name, display_name, content_dir_path);

    if (manifest.get("highlights")) |highlights| {
        try generatePatternColourPage(a, data_dir, highlights, layout_name, content_dir_path);
    }

    if (manifest.get("tokens")) |tokens| {
        try generatePatternTypographyPage(a, tokens, layout_name, content_dir_path);
        try generatePatternSpacingPage(a, tokens, layout_name, content_dir_path);
    }

    if (manifest.get("css")) |css_list| {
        try generatePatternCssPages(a, css_list, layout_name, content_dir_path);
    }
}

fn generatePatternTemplate(
    a: Allocator,
    layout_name: []const u8,
    display_name: []const u8,
    layouts_dir_path: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(a);

    try w.print(
        \\<extend template="base.shtml">
        \\<head id="head">
        \\  <link rel="stylesheet" href="$build.asset('{s}.css').link()">
        \\  <link rel="stylesheet" href="$site.asset('css/patterns.css').link()">
        \\</head>
        \\<body id="body">
        \\  <div class="patterns">
        \\    <header class="patterns__header">
        \\      <a href="/patterns/">Patterns</a> / {s}
        \\    </header>
        \\    <div class="patterns__body">
        \\      <nav class="patterns__nav">
        \\        <h2>Tokens</h2>
        \\        <ul>
        \\          <li><a href="/patterns/{s}/tokens/colour/">Colour</a></li>
        \\          <li><a href="/patterns/{s}/tokens/typography/">Typography</a></li>
        \\          <li><a href="/patterns/{s}/tokens/spacing/">Spacing</a></li>
        \\        </ul>
        \\        <h2>CSS</h2>
        \\        <ul>
        \\          <li><a href="/patterns/{s}/css/compositions/">Compositions</a></li>
        \\          <li><a href="/patterns/{s}/css/utilities/">Utilities</a></li>
        \\        </ul>
        \\      </nav>
        \\      <main class="patterns__content">
        \\        <h1 :text="$page.title"></h1>
        \\        <div :html="$page.content()"></div>
        \\      </main>
        \\    </div>
        \\  </div>
        \\</body>
        \\
    , .{ layout_name, display_name, layout_name, layout_name, layout_name, layout_name, layout_name });

    const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}.shtml", .{ layouts_dir_path, layout_name });
    writeGeneratedFile(path, buf.items);
}

fn generatePatternIndex(
    a: Allocator,
    layouts_dir: Dir,
    content_dir_path: []const u8,
    all_layouts: []const u8,
) !void {
    var page = std.ArrayList(u8){};
    const w = page.writer(a);

    try w.writeAll(
        \\---
        \\.title = "Pattern Libraries",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "page.shtml",
        \\.draft = false,
        \\---
        \\
        \\Browse the pattern library for each layout:
        \\
        \\
    );

    var split = std.mem.splitScalar(u8, all_layouts, ',');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        const mpath = try std.fmt.allocPrint(a, "{s}/layout.yaml", .{name});
        const msrc = layouts_dir.readFileAlloc(a, mpath, 1 << 20) catch continue;
        const manifest = yaml.parse(a, msrc) catch continue;
        const label = if (manifest.get("name")) |v| v.str() orelse name else name;
        try w.print("- [{s}](/patterns/{s}/)\n", .{ label, name });
    }

    const path = try std.fmt.allocPrint(a, "{s}/patterns/index.smd", .{content_dir_path});
    writeGeneratedFile(path, page.items);
}

fn generatePatternOverview(
    a: Allocator,
    manifest: yaml.Value,
    layout_name: []const u8,
    display_name: []const u8,
    content_dir_path: []const u8,
) !void {
    var page = std.ArrayList(u8){};
    const w = page.writer(a);

    try w.print(
        \\---
        \\.title = "{s}",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\Pattern library for the **{s}** layout.
        \\
        \\
    , .{ display_name, layout_name, display_name });

    if (manifest.get("tokens")) |tokens| {
        try w.writeAll("## Token Configuration\n\n");
        if (tokens.get("viewport")) |vp| {
            const mn = if (vp.get("min")) |v| v.str() orelse "?" else "?";
            const mx = if (vp.get("max")) |v| v.str() orelse "?" else "?";
            try w.print("- **Viewport:** {s}px -- {s}px\n", .{ mn, mx });
        }
        if (tokens.get("typography")) |typo| {
            if (typo.get("base")) |base| {
                const mn = if (base.get("min")) |v| v.str() orelse "?" else "?";
                const mx = if (base.get("max")) |v| v.str() orelse "?" else "?";
                try w.print("- **Base font size:** {s}px -- {s}px\n", .{ mn, mx });
            }
            if (typo.get("scale")) |sc| {
                const mn = if (sc.get("min")) |v| v.str() orelse "?" else "?";
                const mx = if (sc.get("max")) |v| v.str() orelse "?" else "?";
                try w.print("- **Type scale:** {s} -- {s}\n", .{ mn, mx });
            }
        }
        try w.writeByte('\n');
    }

    if (manifest.get("highlights")) |hl| {
        try w.writeAll("## Colour Schemes\n\n");
        if (hl.get("default")) |def| {
            const ds = if (def.get("scheme")) |v| v.str() orelse "?" else "?";
            const dm = if (def.get("mode")) |v| v.str() orelse "?" else "?";
            try w.print("Default: **{s}** ({s})\n\n", .{ ds, dm });
        }
        if (hl.get("schemes")) |schemes| {
            try w.writeAll("Available schemes: ");
            for (schemes.list, 0..) |entry, i| {
                const spec = entry.str() orelse continue;
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(spec);
            }
            try w.writeAll("\n\n");
        }
    }

    if (manifest.get("css")) |css_list| {
        try w.writeAll("## CSS Files\n\n");
        for (css_list.list) |entry| {
            const pattern = entry.str() orelse continue;
            try w.print("- `{s}`\n", .{pattern});
        }
        try w.writeByte('\n');
    }

    const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(path, page.items);
}

fn generatePatternColourPage(
    a: Allocator,
    data_dir: Dir,
    highlights: yaml.Value,
    layout_name: []const u8,
    content_dir_path: []const u8,
) !void {
    var page = std.ArrayList(u8){};
    const w = page.writer(a);

    try w.print(
        \\---
        \\.title = "Colour Tokens",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\
    , .{layout_name});

    const default_hl = highlights.get("default");
    var default_scheme: ?[]const u8 = null;
    var default_mode: ?[]const u8 = null;
    if (default_hl) |d| {
        default_scheme = if (d.get("scheme")) |v| v.str() else null;
        default_mode = if (d.get("mode")) |v| v.str() else null;
    }

    const schemes = highlights.get("schemes") orelse {
        try w.writeAll("No colour schemes configured for this layout.\n");
        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/colour/index.smd", .{ content_dir_path, layout_name });
        writeGeneratedFile(path, page.items);
        return;
    };

    for (schemes.list) |entry| {
        const spec = entry.str() orelse continue;
        const dot = std.mem.indexOfScalar(u8, spec, '.') orelse continue;
        const scheme_name = spec[0..dot];
        const mode = spec[dot + 1 ..];

        const file_path = try std.fmt.allocPrint(a, "colours/{s}.yaml", .{scheme_name});
        const scheme_src = data_dir.readFileAlloc(a, file_path, 1 << 20) catch continue;
        const scheme = yaml.parse(a, scheme_src) catch continue;
        const variant = scheme.get(mode) orelse continue;
        const palette = variant.get("palette") orelse continue;
        const meta = variant.get("meta") orelse continue;
        const label = if (meta.get("name")) |v| v.str() orelse spec else spec;

        const is_default = if (default_scheme) |ds|
            std.mem.eql(u8, ds, scheme_name) and
                std.mem.eql(u8, default_mode orelse "", mode)
        else
            false;

        try w.print("## {s}", .{label});
        if (is_default) try w.writeAll(" (default)");
        try w.writeAll("\n\n");

        if (variant.get("styles")) |styles| {
            try emitColourSwatchTable(a, styles, palette, w, "text", "color-text", "Text");
            try emitColourSwatchTable(a, styles, palette, w, "background", "color-bg", "Background");
        }

        if (variant.get("syntax")) |syntax| {
            const syn_map = switch (syntax) {
                .map => |m| m,
                else => continue,
            };
            try w.writeAll("### Syntax\n\n```=html\n");
            try w.writeAll("<table class=\"patterns__swatches\">\n");
            try w.writeAll("<thead><tr><th></th><th>Role</th><th>Palette</th><th>Hex</th><th>Property</th></tr></thead>\n<tbody>\n");
            var syn_iter = syn_map.iterator();
            while (syn_iter.next()) |se| {
                const role = se.key_ptr.*;
                const pkey = se.value_ptr.str() orelse continue;
                const hex = resolvePalette(palette, pkey);
                try w.print("<tr><td><span class=\"patterns__swatch\" style=\"background:{s}\"></span></td>", .{hex});
                try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td>", .{ role, pkey, hex });
                try w.print("<td><code>--syntax-{s}</code></td></tr>\n", .{role});
            }
            try w.writeAll("</tbody></table>\n```\n\n");
        }
    }

    const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/colour/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(path, page.items);
}

fn emitColourSwatchTable(
    a: Allocator,
    styles: yaml.Value,
    palette: yaml.Value,
    w: std.ArrayList(u8).Writer,
    section: []const u8,
    prefix: []const u8,
    heading: []const u8,
) !void {
    _ = a;
    const sub = styles.get(section) orelse return;
    const map = switch (sub) {
        .map => |m| m,
        else => return,
    };
    try w.print("### {s}\n\n```=html\n", .{heading});
    try w.writeAll("<table class=\"patterns__swatches\">\n");
    try w.writeAll("<thead><tr><th></th><th>Role</th><th>Palette</th><th>Hex</th><th>Property</th></tr></thead>\n<tbody>\n");
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const role = entry.key_ptr.*;
        const pkey = entry.value_ptr.str() orelse continue;
        const hex = resolvePalette(palette, pkey);
        try w.print("<tr><td><span class=\"patterns__swatch\" style=\"background:{s}\"></span></td>", .{hex});
        try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td>", .{ role, pkey, hex });
        try w.print("<td><code>--{s}-{s}</code></td></tr>\n", .{ prefix, role });
    }
    try w.writeAll("</tbody></table>\n```\n\n");
}

fn generatePatternTypographyPage(
    a: Allocator,
    tokens: yaml.Value,
    layout_name: []const u8,
    content_dir_path: []const u8,
) !void {
    var page = std.ArrayList(u8){};
    const w = page.writer(a);

    try w.print(
        \\---
        \\.title = "Typography Tokens",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\
    , .{layout_name});

    const viewport = tokens.get("viewport") orelse {
        try w.writeAll("No viewport configuration.\n");
        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/typography/index.smd", .{ content_dir_path, layout_name });
        writeGeneratedFile(path, page.items);
        return;
    };

    const min_vp = parseFloatValue(viewport.get("min"));
    const max_vp = parseFloatValue(viewport.get("max"));
    if (min_vp == 0 or max_vp == 0) return;

    const typo = tokens.get("typography") orelse {
        try w.writeAll("No typography configuration.\n");
        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/typography/index.smd", .{ content_dir_path, layout_name });
        writeGeneratedFile(path, page.items);
        return;
    };

    var min_base: f64 = 16.0;
    var max_base: f64 = 16.0;
    if (typo.get("base")) |base| {
        const mb = parseFloatValue(base.get("min"));
        const xb = parseFloatValue(base.get("max"));
        if (mb > 0) min_base = mb;
        if (xb > 0) max_base = xb;
    }

    const scale = typo.get("scale") orelse return;
    const steps = typo.get("steps") orelse return;
    const min_ratio = parseFloatValue(scale.get("min"));
    const max_ratio = parseFloatValue(scale.get("max"));
    const steps_above: i32 = @intCast(parseUintValue(steps.get("above")));
    const steps_below: i32 = @intCast(parseUintValue(steps.get("below")));

    try w.writeAll("```=html\n");
    try w.writeAll("<table class=\"patterns__tokens\">\n");
    try w.writeAll("<thead><tr><th>Step</th><th>Property</th><th>Min (px)</th><th>Max (px)</th><th>Clamp</th><th>Sample</th></tr></thead>\n<tbody>\n");

    var step: i32 = -steps_below;
    while (step <= steps_above) : (step += 1) {
        const step_f: f64 = @floatFromInt(step);
        const min_fs = min_base * std.math.pow(f64, min_ratio, step_f);
        const max_fs = max_base * std.math.pow(f64, max_ratio, step_f);
        const clamp = try clampToString(a, min_fs, max_fs, min_vp, max_vp);

        var min_buf: [16]u8 = undefined;
        const min_str = std.fmt.bufPrint(&min_buf, "{d:.1}", .{min_fs}) catch "?";
        var max_buf: [16]u8 = undefined;
        const max_str = std.fmt.bufPrint(&max_buf, "{d:.1}", .{max_fs}) catch "?";

        try w.print("<tr><td>{d}</td><td><code>--size-step-{d}</code></td>", .{ step, step });
        try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td>", .{ min_str, max_str, clamp });
        try w.print("<td><span class=\"patterns__type-sample\" style=\"font-size:{s}\">Aa</span></td></tr>\n", .{clamp});
    }

    try w.writeAll("</tbody></table>\n```\n\n");

    const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/typography/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(path, page.items);
}

fn generatePatternSpacingPage(
    a: Allocator,
    tokens: yaml.Value,
    layout_name: []const u8,
    content_dir_path: []const u8,
) !void {
    var page = std.ArrayList(u8){};
    const w = page.writer(a);

    try w.print(
        \\---
        \\.title = "Spacing Tokens",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\
    , .{layout_name});

    const viewport = tokens.get("viewport") orelse {
        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/spacing/index.smd", .{ content_dir_path, layout_name });
        writeGeneratedFile(path, page.items);
        return;
    };

    const min_vp = parseFloatValue(viewport.get("min"));
    const max_vp = parseFloatValue(viewport.get("max"));
    if (min_vp == 0 or max_vp == 0) return;

    var min_base: f64 = 16.0;
    var max_base: f64 = 16.0;
    if (tokens.get("typography")) |typo| {
        if (typo.get("base")) |base| {
            const mb = parseFloatValue(base.get("min"));
            const xb = parseFloatValue(base.get("max"));
            if (mb > 0) min_base = mb;
            if (xb > 0) max_base = xb;
        }
    }

    const spacing = tokens.get("spacing") orelse {
        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/spacing/index.smd", .{ content_dir_path, layout_name });
        writeGeneratedFile(path, page.items);
        return;
    };

    var neg_mults: [16]f64 = undefined;
    var neg_count: usize = 0;
    if (spacing.get("negative")) |neg| {
        for (neg.list) |v| {
            const s = v.str() orelse continue;
            neg_mults[neg_count] = std.fmt.parseFloat(f64, s) catch continue;
            neg_count += 1;
        }
    }
    sortFloats(neg_mults[0..neg_count]);
    std.mem.reverse(f64, neg_mults[0..neg_count]);

    var pos_mults: [16]f64 = undefined;
    var pos_count: usize = 0;
    if (spacing.get("positive")) |pos| {
        for (pos.list) |v| {
            const s = v.str() orelse continue;
            pos_mults[pos_count] = std.fmt.parseFloat(f64, s) catch continue;
            pos_count += 1;
        }
    }
    sortFloats(pos_mults[0..pos_count]);

    var sizes: [32]SpaceSize = undefined;
    var size_count: usize = 0;

    {
        var i = neg_count;
        while (i > 0) {
            i -= 1;
            const s: i32 = -@as(i32, @intCast(i)) - 1;
            sizes[size_count] = .{
                .label = try spaceLabel(a, s),
                .min_size = @floor(min_base * neg_mults[i] + 0.5),
                .max_size = @floor(max_base * neg_mults[i] + 0.5),
            };
            size_count += 1;
        }
    }

    sizes[size_count] = .{ .label = "s", .min_size = @floor(min_base + 0.5), .max_size = @floor(max_base + 0.5) };
    size_count += 1;

    for (pos_mults[0..pos_count], 0..) |mult, j| {
        const s: i32 = @intCast(j + 1);
        sizes[size_count] = .{
            .label = try spaceLabel(a, s),
            .min_size = @floor(min_base * mult + 0.5),
            .max_size = @floor(max_base * mult + 0.5),
        };
        size_count += 1;
    }

    try w.writeAll("## Base Sizes\n\n");
    try emitSpacingTable(a, w, sizes[0..size_count], min_vp, max_vp);

    if (size_count > 1) {
        try w.writeAll("## One-up Pairs\n\n```=html\n");
        try w.writeAll("<table class=\"patterns__tokens\">\n");
        try w.writeAll("<thead><tr><th>Label</th><th>Property</th><th>Min (px)</th><th>Max (px)</th><th>Clamp</th></tr></thead>\n<tbody>\n");
        var j: usize = 0;
        while (j < size_count - 1) : (j += 1) {
            const prev = sizes[j];
            const next = sizes[j + 1];
            const clamp = try clampToString(a, prev.min_size, next.max_size, min_vp, max_vp);
            var min_buf: [16]u8 = undefined;
            const min_str = std.fmt.bufPrint(&min_buf, "{d:.0}", .{prev.min_size}) catch "?";
            var max_buf: [16]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "{d:.0}", .{next.max_size}) catch "?";
            try w.print("<tr><td>{s}-{s}</td><td><code>--space-{s}-{s}</code></td>", .{ prev.label, next.label, prev.label, next.label });
            try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td></tr>\n", .{ min_str, max_str, clamp });
        }
        try w.writeAll("</tbody></table>\n```\n\n");
    }

    if (spacing.get("pairs")) |pairs_val| {
        try w.writeAll("## Custom Pairs\n\n```=html\n");
        try w.writeAll("<table class=\"patterns__tokens\">\n");
        try w.writeAll("<thead><tr><th>Label</th><th>Property</th><th>Min (px)</th><th>Max (px)</th><th>Clamp</th></tr></thead>\n<tbody>\n");
        for (pairs_val.list) |entry| {
            const pair_str = entry.str() orelse continue;
            const dash = std.mem.indexOfScalar(u8, pair_str, '-') orelse continue;
            const key_a = pair_str[0..dash];
            const key_b = pair_str[dash + 1 ..];
            const a_size = findSpaceSize(sizes[0..size_count], key_a) orelse continue;
            const b_size = findSpaceSize(sizes[0..size_count], key_b) orelse continue;
            const clamp = try clampToString(a, a_size.min_size, b_size.max_size, min_vp, max_vp);
            var min_buf: [16]u8 = undefined;
            const min_str = std.fmt.bufPrint(&min_buf, "{d:.0}", .{a_size.min_size}) catch "?";
            var max_buf: [16]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "{d:.0}", .{b_size.max_size}) catch "?";
            try w.print("<tr><td>{s}-{s}</td><td><code>--space-{s}-{s}</code></td>", .{ key_a, key_b, key_a, key_b });
            try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td></tr>\n", .{ min_str, max_str, clamp });
        }
        try w.writeAll("</tbody></table>\n```\n\n");
    }

    const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/spacing/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(path, page.items);
}

fn emitSpacingTable(
    a: Allocator,
    w: std.ArrayList(u8).Writer,
    sizes: []const SpaceSize,
    min_vp: f64,
    max_vp: f64,
) !void {
    try w.writeAll("```=html\n");
    try w.writeAll("<table class=\"patterns__tokens\">\n");
    try w.writeAll("<thead><tr><th>Label</th><th>Property</th><th>Min (px)</th><th>Max (px)</th><th>Clamp</th><th>Preview</th></tr></thead>\n<tbody>\n");
    for (sizes) |sz| {
        const clamp = try clampToString(a, sz.min_size, sz.max_size, min_vp, max_vp);
        var min_buf: [16]u8 = undefined;
        const min_str = std.fmt.bufPrint(&min_buf, "{d:.0}", .{sz.min_size}) catch "?";
        var max_buf: [16]u8 = undefined;
        const max_str = std.fmt.bufPrint(&max_buf, "{d:.0}", .{sz.max_size}) catch "?";
        try w.print("<tr><td>{s}</td><td><code>--space-{s}</code></td>", .{ sz.label, sz.label });
        try w.print("<td>{s}</td><td>{s}</td><td><code>{s}</code></td>", .{ min_str, max_str, clamp });
        try w.print("<td><span class=\"patterns__spacing-bar\" style=\"--patterns-bar-height:{s}\"></span></td></tr>\n", .{clamp});
    }
    try w.writeAll("</tbody></table>\n```\n\n");
}

fn generatePatternCssPages(
    a: Allocator,
    css_list: yaml.Value,
    layout_name: []const u8,
    content_dir_path: []const u8,
) !void {
    var comp_page = std.ArrayList(u8){};
    const cw = comp_page.writer(a);
    var util_page = std.ArrayList(u8){};
    const uw = util_page.writer(a);

    try cw.print(
        \\---
        \\.title = "Compositions",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\Layout compositions included in this layout.
        \\
        \\
    , .{layout_name});

    try uw.print(
        \\---
        \\.title = "Utilities",
        \\.date = @date("2026-01-01T00:00:00"),
        \\.author = "QuiteClose",
        \\.layout = "patterns/{s}.shtml",
        \\.draft = false,
        \\---
        \\
        \\Utility classes included in this layout.
        \\
        \\
    , .{layout_name});

    var has_comp = false;
    var has_util = false;

    for (css_list.list) |entry| {
        const pattern = entry.str() orelse continue;
        if (std.mem.indexOf(u8, pattern, "compositions")) |_| {
            try cw.print("- `{s}`\n", .{pattern});
            has_comp = true;
        } else if (std.mem.indexOf(u8, pattern, "utilities")) |_| {
            try uw.print("- `{s}`\n", .{pattern});
            has_util = true;
        }
    }

    if (!has_comp) try cw.writeAll("No compositions configured.\n");
    if (!has_util) try uw.writeAll("No utilities configured.\n");

    const comp_path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/css/compositions/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(comp_path, comp_page.items);

    const util_path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/css/utilities/index.smd", .{ content_dir_path, layout_name });
    writeGeneratedFile(util_path, util_page.items);
}

fn fatal(msg: []const u8) noreturn {
    std.process.fatal("{s}", .{msg});
}

fn fatalFmt(comptime fmt: []const u8, args: anytype) noreturn {
    std.process.fatal(fmt, args);
}
