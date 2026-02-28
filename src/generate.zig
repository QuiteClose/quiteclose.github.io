const std = @import("std");
const yaml = @import("yaml.zig");
const template = @import("template.zig");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

/// Usage: generate <layouts_dir> <data_dir> <pages_dir> <assets_dir>
///        <output_dir> <layout_names> [--dev]
///
/// Generates a complete static site: CSS bundles, rendered HTML pages,
/// and copied assets, written directly to output_dir/.
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
    const output_dir_path = args.next() orelse fatal("missing output_dir argument");
    const all_layouts = args.next() orelse fatal("missing layout_names argument");
    const dev = if (args.next()) |flag| std.mem.eql(u8, flag, "--dev") else false;

    const layouts_dir = std.fs.cwd().openDir(layouts_dir_path, .{ .iterate = true }) catch |err|
        fatalFmt("cannot open layouts dir '{s}': {}", .{ layouts_dir_path, err });
    const data_dir = std.fs.cwd().openDir(data_dir_path, .{}) catch |err|
        fatalFmt("cannot open data dir '{s}': {}", .{ data_dir_path, err });

    processAll(a, layouts_dir, data_dir, pages_dir_path, assets_dir_path, output_dir_path, all_layouts, dev);
}

fn processAll(
    a: Allocator,
    layouts_dir: Dir,
    data_dir: Dir,
    pages_dir_path: []const u8,
    assets_dir_path: []const u8,
    output_dir_path: []const u8,
    all_layouts: []const u8,
    dev: bool,
) void {
    var layout_names: [16][]const u8 = undefined;
    var layout_count: usize = 0;
    var split = std.mem.splitScalar(u8, all_layouts, ',');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        layout_names[layout_count] = name;
        layout_count += 1;
    }

    std.fs.cwd().makePath(output_dir_path) catch |err|
        fatalFmt("cannot create output dir '{s}': {}", .{ output_dir_path, err });

    // 1. Generate CSS/JS for each layout
    for (layout_names[0..layout_count]) |layout_name| {
        const css_path = std.fmt.allocPrint(a, "{s}/css/{s}.css", .{ output_dir_path, layout_name }) catch @panic("OOM");
        const js_path = std.fmt.allocPrint(a, "{s}/js/{s}.js", .{ output_dir_path, layout_name }) catch @panic("OOM");
        processLayout(a, layouts_dir, data_dir, layout_name, css_path, js_path) catch |err|
            fatalFmt("error processing layout '{s}': {}", .{ layout_name, err });
    }

    // 2. Load templates into resolver
    var resolver: template.Resolver = .{};
    loadTemplates(a, layouts_dir, layout_names[0..layout_count], &resolver) catch |err|
        fatalFmt("error loading templates: {}", .{err});

    // 3. Load site-level variables
    const site_yaml_src = data_dir.readFileAlloc(a, "site.yaml", 1 << 20) catch |err|
        fatalFmt("cannot read data/site.yaml: {}", .{err});
    const site_conf = yaml.parse(a, site_yaml_src) catch |err|
        fatalFmt("cannot parse data/site.yaml: {}", .{err});

    // 4. Render content pages
    renderPages(a, pages_dir_path, output_dir_path, site_conf, &resolver, dev) catch |err|
        fatalFmt("error rendering pages: {}", .{err});

    // 5. Copy assets
    copyDirRecursive(assets_dir_path, output_dir_path) catch |err|
        fatalFmt("cannot copy assets: {}", .{err});

    // 6. Validate pattern examples exist
    {
        var missing_count: usize = 0;
        for (layout_names[0..layout_count]) |layout_name| {
            missing_count += validatePatternExamples(a, layouts_dir, layout_name);
        }
        if (missing_count > 0) {
            fatalFmt("{d} pattern(s) missing example files -- see warnings above", .{missing_count});
        }
    }

    // 7. Pattern library (dev mode only)
    if (dev) {
        for (layout_names[0..layout_count]) |layout_name| {
            generatePatternLibrary(a, layouts_dir, data_dir, layout_name, output_dir_path, site_conf, &resolver) catch |err|
                fatalFmt("error generating pattern library for '{s}': {}", .{ layout_name, err });
        }
    }
}

fn loadTemplates(
    a: Allocator,
    layouts_dir: Dir,
    layout_names: []const []const u8,
    resolver: *template.Resolver,
) !void {
    // Load _core/html/*.html as templates (e.g., base.html)
    var core_html = layouts_dir.openDir("_core/html", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer core_html.close();

    var core_iter = core_html.iterate();
    while (try core_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
        const content = try core_html.readFileAlloc(a, entry.name, 1 << 20);
        try resolver.put(a, try a.dupe(u8, entry.name), content);
    }

    // Load {layout}/html/*.html (e.g., page.html, semantica.html)
    for (layout_names) |layout_name| {
        const html_subdir = try std.fmt.allocPrint(a, "{s}/html", .{layout_name});
        var layout_html = layouts_dir.openDir(html_subdir, .{ .iterate = true }) catch continue;
        defer layout_html.close();

        var iter = layout_html.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
            const content = try layout_html.readFileAlloc(a, entry.name, 1 << 20);
            try resolver.put(a, try a.dupe(u8, entry.name), content);
        }
    }
}

fn renderPages(
    a: Allocator,
    pages_dir_path: []const u8,
    output_dir_path: []const u8,
    site_conf: yaml.Value,
    resolver: *const template.Resolver,
    dev: bool,
) !void {
    var pages_dir = std.fs.cwd().openDir(pages_dir_path, .{ .iterate = true }) catch |err|
        fatalFmt("cannot open pages dir '{s}': {}", .{ pages_dir_path, err });
    defer pages_dir.close();

    var walker = try pages_dir.walk(a);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".html")) continue;

        const page_src = try entry.dir.readFileAlloc(a, entry.basename, 1 << 20);
        const parsed = parseFrontmatter(a, page_src) catch |err|
            fatalFmt("cannot parse frontmatter in '{s}': {}", .{ entry.path, err });

        const is_draft = if (parsed.frontmatter.get("draft")) |v|
            std.mem.eql(u8, v.str() orelse "false", "true")
        else
            false;

        if (is_draft and !dev) continue;

        const layout_name = if (parsed.frontmatter.get("layout")) |v|
            v.str() orelse "page.html"
        else
            "page.html";

        const layout_content = resolver.get(layout_name) orelse
            fatalFmt("template '{s}' not found (referenced by '{s}')", .{ layout_name, entry.path });

        var ctx: template.Context = .{ .dev_mode = dev };

        // Set site.* vars
        if (site_conf == .map) {
            var site_iter = site_conf.map.iterator();
            while (site_iter.next()) |kv| {
                const key = try std.fmt.allocPrint(a, "site.{s}", .{kv.key_ptr.*});
                if (kv.value_ptr.str()) |val| {
                    try ctx.putVar(a, key, val);
                }
            }
        }

        // Set page.* vars from frontmatter
        var fm_iter = parsed.frontmatter.map.iterator();
        while (fm_iter.next()) |kv| {
            const key = try std.fmt.allocPrint(a, "page.{s}", .{kv.key_ptr.*});
            if (kv.value_ptr.str()) |val| {
                try ctx.putVar(a, key, val);
            }
        }

        // Page body is the anonymous slot
        try ctx.putSlot(a, "", parsed.body);

        const rendered = template.render(a, layout_content, &ctx, resolver) catch |err|
            fatalFmt("error rendering '{s}': {}", .{ entry.path, err });

        const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ output_dir_path, entry.path });
        writeGeneratedFile(out_path, rendered);
    }
}

const ParsedPage = struct {
    frontmatter: yaml.Value,
    body: []const u8,
};

fn parseFrontmatter(a: Allocator, src: []const u8) !ParsedPage {
    if (!std.mem.startsWith(u8, src, "---\n") and !std.mem.startsWith(u8, src, "---\r\n")) {
        return .{ .frontmatter = .{ .map = .{} }, .body = src };
    }

    const after_open = if (std.mem.startsWith(u8, src, "---\r\n")) @as(usize, 5) else @as(usize, 4);
    const close = std.mem.indexOf(u8, src[after_open..], "\n---") orelse
        return error.MalformedElement;
    const fm_text = src[after_open .. after_open + close];
    var body_start = after_open + close + 4;
    if (body_start < src.len and (src[body_start] == '\n' or src[body_start] == '\r')) {
        body_start += 1;
        if (body_start < src.len and src[body_start] == '\n') body_start += 1;
    }

    const fm = try yaml.parse(a, fm_text);
    return .{ .frontmatter = fm, .body = src[body_start..] };
}

fn copyDirRecursive(src_path: []const u8, dest_path: []const u8) !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const file_dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.path });
        defer alloc.free(file_dest);

        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(file_dest),
            .file => {
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

// --- CSS/JS generation (unchanged) ---

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

    if (std.mem.lastIndexOfScalar(u8, css_output_path, '/')) |last_slash| {
        std.fs.cwd().makePath(css_output_path[0..last_slash]) catch {};
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
    if (std.mem.lastIndexOfScalar(u8, js_output_path, '/')) |last_slash| {
        std.fs.cwd().makePath(js_output_path[0..last_slash]) catch {};
    }
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

    if (std.mem.lastIndexOfScalar(u8, js_path, '/')) |last_slash| {
        std.fs.cwd().makePath(js_path[0..last_slash]) catch {};
    }
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

fn validatePatternExamples(a: Allocator, layouts_dir: Dir, layout_name: []const u8) usize {
    const manifest_path = std.fmt.allocPrint(a, "{s}/layout.yaml", .{layout_name}) catch @panic("OOM");
    const manifest_src = layouts_dir.readFileAlloc(a, manifest_path, 1 << 20) catch return 0;
    const manifest = yaml.parse(a, manifest_src) catch return 0;
    const css_list = manifest.get("css") orelse return 0;

    const categories = [_][]const u8{ "compositions", "utilities", "blocks" };
    var missing: usize = 0;

    for (css_list.list) |entry| {
        const pat = entry.str() orelse continue;

        for (&categories) |cat| {
            if (std.mem.indexOf(u8, pat, cat) == null) continue;

            if (std.mem.endsWith(u8, pat, "/*")) {
                const dir_path = pat[0 .. pat.len - 2];
                var dir = layouts_dir.openDir(dir_path, .{ .iterate = true }) catch continue;
                defer dir.close();
                var iter = dir.iterate();
                while (iter.next() catch null) |fentry| {
                    if (fentry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, fentry.name, ".css")) continue;
                    const basename = fentry.name[0 .. fentry.name.len - 4];
                    missing += checkExample(a, layouts_dir, dir_path, cat, basename);
                }
            } else if (std.mem.endsWith(u8, pat, ".css")) {
                const last_slash = std.mem.lastIndexOfScalar(u8, pat, '/') orelse continue;
                const fname = pat[last_slash + 1 ..];
                const basename = fname[0 .. fname.len - 4];
                const dir_path = pat[0..last_slash];
                missing += checkExample(a, layouts_dir, dir_path, cat, basename);
            }
            break;
        }
    }

    return missing;
}

fn checkExample(a: Allocator, layouts_dir: Dir, dir_path: []const u8, category: []const u8, basename: []const u8) usize {
    const parent_dir = if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |s|
        dir_path[0..s]
    else
        "";
    const example_path = std.fmt.allocPrint(a, "{s}/examples/{s}/{s}.html", .{ parent_dir, category, basename }) catch @panic("OOM");

    layouts_dir.access(example_path, .{}) catch {
        std.log.warn("missing example for pattern: {s}/{s}/{s}.css -> expected {s}", .{ parent_dir, category, basename, example_path });
        return 1;
    };
    return 0;
}

const CssDoc = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    properties: []const CssProp,
    exceptions: []const CssException,
};

const CssProp = struct {
    name: []const u8,
    default: []const u8,
    description: []const u8,
};

const CssException = struct {
    selector: []const u8,
    description: []const u8,
};

fn parseCssDoc(a: Allocator, css_source: []const u8) CssDoc {
    var doc: CssDoc = .{
        .name = "",
        .description = "",
        .url = "",
        .properties = &.{},
        .exceptions = &.{},
    };

    const end = std.mem.indexOf(u8, css_source, "*/") orelse return doc;
    if (!std.mem.startsWith(u8, std.mem.trimLeft(u8, css_source, " \t"), "/*")) return doc;

    var props = std.ArrayList(CssProp){};
    var excepts = std.ArrayList(CssException){};
    var desc_lines = std.ArrayList([]const u8){};
    var in_props = false;
    var in_exceptions = false;

    const comment = css_source[0 .. end + 2];
    var lines_iter = std.mem.splitScalar(u8, comment, '\n');
    var first_content = true;
    while (lines_iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t");
        if (std.mem.startsWith(u8, line, "/*")) line = std.mem.trim(u8, line[2..], " \t*");
        if (std.mem.startsWith(u8, line, "*/")) continue;
        if (std.mem.startsWith(u8, line, "* ")) {
            line = line[2..];
        } else if (std.mem.eql(u8, line, "*")) {
            line = "";
        }
        line = std.mem.trim(u8, line, " \t");

        if (line.len == 0) {
            in_props = false;
            in_exceptions = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "Custom properties:")) {
            in_props = true;
            in_exceptions = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Exceptions:") or std.mem.startsWith(u8, line, "Exception:")) {
            in_exceptions = true;
            in_props = false;
            continue;
        }

        if (in_props) {
            if (std.mem.startsWith(u8, line, "--")) {
                var prop_name: []const u8 = line;
                var prop_default: []const u8 = "";
                var prop_desc: []const u8 = "";

                if (std.mem.indexOf(u8, line, " -- ")) |dash_pos| {
                    prop_name = std.mem.trim(u8, line[0..dash_pos], " \t");
                    prop_desc = line[dash_pos + 4 ..];
                }

                if (std.mem.indexOf(u8, prop_name, "(")) |paren_open| {
                    if (std.mem.lastIndexOfScalar(u8, prop_name, ')')) |paren_close| {
                        prop_default = prop_name[paren_open + 1 .. paren_close];
                        prop_name = std.mem.trim(u8, prop_name[0..paren_open], " \t");
                    }
                }

                props.append(a, .{
                    .name = prop_name,
                    .default = prop_default,
                    .description = prop_desc,
                }) catch @panic("OOM");
            }
            continue;
        }

        if (in_exceptions) {
            var sel: []const u8 = line;
            var exc_desc: []const u8 = "";
            if (std.mem.indexOf(u8, line, " -- ")) |dash_pos| {
                sel = std.mem.trim(u8, line[0..dash_pos], " \t");
                exc_desc = line[dash_pos + 4 ..];
            }
            excepts.append(a, .{
                .selector = sel,
                .description = exc_desc,
            }) catch @panic("OOM");
            continue;
        }

        if (first_content) {
            if (std.mem.endsWith(u8, line, " composition") or
                std.mem.endsWith(u8, line, " utility") or
                std.mem.endsWith(u8, line, " COMPOSITION") or
                std.mem.endsWith(u8, line, " UTILITY"))
            {
                doc.name = line;
            } else {
                doc.name = line;
            }
            first_content = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "Every Layout:") or
            std.mem.startsWith(u8, line, "https://"))
        {
            const url_part = if (std.mem.startsWith(u8, line, "Every Layout:"))
                std.mem.trim(u8, line["Every Layout:".len..], " \t")
            else
                line;
            doc.url = url_part;
            continue;
        }

        desc_lines.append(a, line) catch @panic("OOM");
    }

    if (desc_lines.items.len > 0) {
        var desc_buf = std.ArrayList(u8){};
        for (desc_lines.items, 0..) |dl, idx| {
            if (idx > 0) desc_buf.appendSlice(a, " ") catch @panic("OOM");
            desc_buf.appendSlice(a, dl) catch @panic("OOM");
        }
        doc.description = (desc_buf.toOwnedSlice(a) catch @panic("OOM"));
    }

    doc.properties = props.toOwnedSlice(a) catch @panic("OOM");
    doc.exceptions = excepts.toOwnedSlice(a) catch @panic("OOM");

    return doc;
}

fn generatePatternLibrary(
    a: Allocator,
    layouts_dir: Dir,
    data_dir: Dir,
    layout_name: []const u8,
    output_dir_path: []const u8,
    site_conf: yaml.Value,
    resolver: *const template.Resolver,
) !void {
    const manifest_path = try std.fmt.allocPrint(a, "{s}/layout.yaml", .{layout_name});
    const manifest_src = layouts_dir.readFileAlloc(a, manifest_path, 1 << 20) catch |err|
        fatalFmt("cannot read manifest '{s}': {}", .{ manifest_path, err });
    const manifest = try yaml.parse(a, manifest_src);
    const display_name = if (manifest.get("name")) |v| v.str() orelse layout_name else layout_name;

    // Render a pattern library page as HTML through the template engine
    const renderPatternPage = struct {
        fn render(
            alloc: Allocator,
            out_path: []const u8,
            title: []const u8,
            body_html: []const u8,
            ln: []const u8,
            sc: yaml.Value,
            res: *const template.Resolver,
        ) void {
            const pl_template = res.get("pattern-library.html") orelse
                fatalFmt("pattern-library.html template not found", .{});

            var ctx: template.Context = .{ .dev_mode = true };
            ctx.putVar(alloc, "page.title", title) catch @panic("OOM");
            ctx.putSlot(alloc, "", body_html) catch @panic("OOM");
            _ = ln;

            if (sc == .map) {
                var site_iter = sc.map.iterator();
                while (site_iter.next()) |kv| {
                    const key = std.fmt.allocPrint(alloc, "site.{s}", .{kv.key_ptr.*}) catch @panic("OOM");
                    if (kv.value_ptr.str()) |val| {
                        ctx.putVar(alloc, key, val) catch @panic("OOM");
                    }
                }
            }

            const rendered = template.render(alloc, pl_template, &ctx, res) catch |err|
                fatalFmt("error rendering pattern page '{s}': {}", .{ title, err });
            writeGeneratedFile(out_path, rendered);
        }
    }.render;

    // Overview page
    {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);
        try w.print("<p>Pattern library for the <strong>{s}</strong> layout.</p>\n", .{display_name});

        if (manifest.get("tokens")) |tokens| {
            try w.writeAll("<h2>Token Configuration</h2>\n<ul>\n");
            if (tokens.get("viewport")) |vp| {
                const mn = if (vp.get("min")) |v| v.str() orelse "?" else "?";
                const mx = if (vp.get("max")) |v| v.str() orelse "?" else "?";
                try w.print("<li><strong>Viewport:</strong> {s}px &ndash; {s}px</li>\n", .{ mn, mx });
            }
            try w.writeAll("</ul>\n");
        }

        if (manifest.get("highlights")) |hl| {
            try w.writeAll("<h2>Colour Schemes</h2>\n");
            if (hl.get("default")) |def| {
                const ds = if (def.get("scheme")) |v| v.str() orelse "?" else "?";
                const dm = if (def.get("mode")) |v| v.str() orelse "?" else "?";
                try w.print("<p>Default: <strong>{s}</strong> ({s})</p>\n", .{ ds, dm });
            }
        }

        if (manifest.get("css")) |css_list| {
            try w.writeAll("<h2>CSS Files</h2>\n<ul>\n");
            for (css_list.list) |entry| {
                const pat = entry.str() orelse continue;
                try w.print("<li><code>{s}</code></li>\n", .{pat});
            }
            try w.writeAll("</ul>\n");
        }

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, display_name, body.items, layout_name, site_conf, resolver);
    }

    // Colour page
    if (manifest.get("highlights")) |highlights| {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);

        const schemes = highlights.get("schemes") orelse {
            try w.writeAll("<p>No colour schemes configured for this layout.</p>\n");
            const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/colour/index.html", .{ output_dir_path, layout_name });
            renderPatternPage(a, path, "Colour Tokens", body.items, layout_name, site_conf, resolver);
            return;
        };

        const default_hl = highlights.get("default");
        var default_scheme: ?[]const u8 = null;
        var default_mode: ?[]const u8 = null;
        if (default_hl) |d| {
            default_scheme = if (d.get("scheme")) |v| v.str() else null;
            default_mode = if (d.get("mode")) |v| v.str() else null;
        }

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

            try w.print("<h2>{s}", .{label});
            if (is_default) try w.writeAll(" (default)");
            try w.writeAll("</h2>\n");

            if (variant.get("styles")) |styles| {
                try emitHtmlSwatchTable(a, styles, palette, w, "text", "color-text", "Text");
                try emitHtmlSwatchTable(a, styles, palette, w, "background", "color-bg", "Background");
            }

            if (variant.get("syntax")) |syntax| {
                const syn_map = switch (syntax) {
                    .map => |m| m,
                    else => continue,
                };
                try w.writeAll("<h3>Syntax</h3>\n<table class=\"patterns__swatches\">\n");
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
                try w.writeAll("</tbody></table>\n");
            }
        }

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/colour/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, "Colour Tokens", body.items, layout_name, site_conf, resolver);
    }

    // Typography page
    if (manifest.get("tokens")) |tokens| {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);

        const viewport = tokens.get("viewport");
        const typo = tokens.get("typography");
        if (viewport != null and typo != null) {
            const min_vp = parseFloatValue(viewport.?.get("min"));
            const max_vp = parseFloatValue(viewport.?.get("max"));
            var min_base: f64 = 16.0;
            var max_base: f64 = 16.0;
            if (typo.?.get("base")) |base| {
                const mb = parseFloatValue(base.get("min"));
                const xb = parseFloatValue(base.get("max"));
                if (mb > 0) min_base = mb;
                if (xb > 0) max_base = xb;
            }
            if (typo.?.get("scale") != null and typo.?.get("steps") != null and min_vp > 0 and max_vp > 0) {
                const scale = typo.?.get("scale").?;
                const steps = typo.?.get("steps").?;
                const min_ratio = parseFloatValue(scale.get("min"));
                const max_ratio = parseFloatValue(scale.get("max"));
                const steps_above: i32 = @intCast(parseUintValue(steps.get("above")));
                const steps_below: i32 = @intCast(parseUintValue(steps.get("below")));

                try w.writeAll("<table class=\"patterns__tokens\">\n");
                try w.writeAll("<thead><tr><th>Step</th><th>Property</th><th>Min</th><th>Max</th><th>Sample</th></tr></thead>\n<tbody>\n");
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
                    try w.print("<td>{s}px</td><td>{s}px</td>", .{ min_str, max_str });
                    try w.print("<td><span style=\"font-size:{s}\">Aa</span></td></tr>\n", .{clamp});
                }
                try w.writeAll("</tbody></table>\n");
            }
        } else {
            try w.writeAll("<p>No typography configuration.</p>\n");
        }

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/typography/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, "Typography Tokens", body.items, layout_name, site_conf, resolver);
    }

    // Spacing page
    if (manifest.get("tokens")) |tokens| {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);

        const viewport = tokens.get("viewport");
        const spacing = tokens.get("spacing");
        if (viewport != null and spacing != null) {
            const min_vp = parseFloatValue(viewport.?.get("min"));
            const max_vp = parseFloatValue(viewport.?.get("max"));
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
            if (min_vp > 0 and max_vp > 0) {
                try emitHtmlSpacingSection(a, w, spacing.?, min_vp, max_vp, min_base, max_base);
            }
        } else {
            try w.writeAll("<p>No spacing configuration.</p>\n");
        }

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/tokens/spacing/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, "Spacing Tokens", body.items, layout_name, site_conf, resolver);
    }

    // Compositions page
    if (manifest.get("css")) |css_list| {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);
        try w.writeAll("<p>Layout compositions for arranging content without media queries.</p>\n");
        try emitPatternCategory(a, layouts_dir, css_list, "compositions", w);

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/css/compositions/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, "Compositions", body.items, layout_name, site_conf, resolver);
    }

    // Utilities page
    if (manifest.get("css")) |css_list| {
        var body = std.ArrayList(u8){};
        const w = body.writer(a);
        try w.writeAll("<p>Single-purpose utility classes.</p>\n");
        try emitPatternCategory(a, layouts_dir, css_list, "utilities", w);

        const path = try std.fmt.allocPrint(a, "{s}/patterns/{s}/css/utilities/index.html", .{ output_dir_path, layout_name });
        renderPatternPage(a, path, "Utilities", body.items, layout_name, site_conf, resolver);
    }
}

fn emitHtmlSwatchTable(
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
    try w.print("<h3>{s}</h3>\n<table class=\"patterns__swatches\">\n", .{heading});
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
    try w.writeAll("</tbody></table>\n");
}

fn emitHtmlSpacingSection(
    a: Allocator,
    w: std.ArrayList(u8).Writer,
    spacing: yaml.Value,
    min_vp: f64,
    max_vp: f64,
    min_base: f64,
    max_base: f64,
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

    try w.writeAll("<h2>Base Sizes</h2>\n<table class=\"patterns__tokens\">\n");
    try w.writeAll("<thead><tr><th>Label</th><th>Property</th><th>Min</th><th>Max</th><th>Preview</th></tr></thead>\n<tbody>\n");
    for (sizes[0..size_count]) |sz| {
        const clamp = try clampToString(a, sz.min_size, sz.max_size, min_vp, max_vp);
        var min_buf: [16]u8 = undefined;
        const min_str = std.fmt.bufPrint(&min_buf, "{d:.0}", .{sz.min_size}) catch "?";
        var max_buf: [16]u8 = undefined;
        const max_str = std.fmt.bufPrint(&max_buf, "{d:.0}", .{sz.max_size}) catch "?";
        try w.print("<tr><td>{s}</td><td><code>--space-{s}</code></td>", .{ sz.label, sz.label });
        try w.print("<td>{s}px</td><td>{s}px</td>", .{ min_str, max_str });
        try w.print("<td><span class=\"patterns__spacing-bar\" style=\"--patterns-bar-height:{s}\"></span></td></tr>\n", .{clamp});
    }
    try w.writeAll("</tbody></table>\n");
}

fn emitPatternCategory(
    a: Allocator,
    layouts_dir: Dir,
    css_list: yaml.Value,
    category: []const u8,
    w: std.ArrayList(u8).Writer,
) !void {
    var css_paths = std.ArrayList([]const u8){};

    for (css_list.list) |entry| {
        const pat = entry.str() orelse continue;
        if (std.mem.indexOf(u8, pat, category) == null) continue;

        if (std.mem.endsWith(u8, pat, "/*")) {
            const dir_path = pat[0 .. pat.len - 2];
            var dir = layouts_dir.openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var names = std.ArrayList([]const u8){};
            var iter = dir.iterate();
            while (try iter.next()) |fentry| {
                if (fentry.kind != .file) continue;
                if (!std.mem.endsWith(u8, fentry.name, ".css")) continue;
                try names.append(a, try a.dupe(u8, fentry.name));
            }
            std.mem.sort([]const u8, names.items, {}, struct {
                fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.cmp);
            for (names.items) |name| {
                const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
                try css_paths.append(a, full);
            }
        } else if (std.mem.endsWith(u8, pat, ".css")) {
            try css_paths.append(a, pat);
        }
    }

    if (css_paths.items.len == 0) {
        try w.print("<p>No {s} configured for this layout.</p>\n", .{category});
        return;
    }

    for (css_paths.items) |css_path| {
        const css_source = layouts_dir.readFileAlloc(a, css_path, 1 << 20) catch continue;
        const doc = parseCssDoc(a, css_source);

        const basename = blk: {
            const last_slash = std.mem.lastIndexOfScalar(u8, css_path, '/');
            const fname = if (last_slash) |s| css_path[s + 1 ..] else css_path;
            if (std.mem.endsWith(u8, fname, ".css")) break :blk fname[0 .. fname.len - 4];
            break :blk fname;
        };

        try w.print("<article class=\"pattern\" id=\"{s}\">\n", .{basename});

        if (doc.name.len > 0) {
            try w.print("<h2>{s}</h2>\n", .{doc.name});
        } else {
            try w.print("<h2>{s}</h2>\n", .{basename});
        }

        if (doc.description.len > 0) {
            try w.print("<p>{s}</p>\n", .{doc.description});
        }

        if (doc.url.len > 0) {
            try w.print("<p><a href=\"{s}\">Reference</a></p>\n", .{doc.url});
        }

        if (doc.properties.len > 0) {
            try w.writeAll("<h3>Custom properties</h3>\n");
            try w.writeAll("<table class=\"patterns__props\">\n");
            try w.writeAll("<thead><tr><th>Property</th><th>Default</th><th>Description</th></tr></thead>\n<tbody>\n");
            for (doc.properties) |prop| {
                try w.print("<tr><td><code>{s}</code></td><td><code>{s}</code></td><td>{s}</td></tr>\n", .{
                    prop.name, prop.default, prop.description,
                });
            }
            try w.writeAll("</tbody></table>\n");
        }

        if (doc.exceptions.len > 0) {
            try w.writeAll("<h3>Exceptions</h3>\n");
            try w.writeAll("<table class=\"patterns__exceptions\">\n");
            try w.writeAll("<thead><tr><th>Selector</th><th>Description</th></tr></thead>\n<tbody>\n");
            for (doc.exceptions) |exc| {
                try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>\n", .{
                    exc.selector, exc.description,
                });
            }
            try w.writeAll("</tbody></table>\n");
        }

        // Example: look for matching .html file in examples/ directory
        const example_path = blk: {
            const dir_part = if (std.mem.lastIndexOfScalar(u8, css_path, '/')) |s|
                css_path[0..s]
            else
                "";
            const parent_dir = if (std.mem.lastIndexOfScalar(u8, dir_part, '/')) |s|
                dir_part[0..s]
            else
                "";
            break :blk try std.fmt.allocPrint(a, "{s}/examples/{s}/{s}.html", .{ parent_dir, category, basename });
        };

        if (layouts_dir.readFileAlloc(a, example_path, 1 << 20)) |example_src| {
            try w.writeAll("<h3>Example</h3>\n");
            try w.writeAll("<div class=\"pattern__preview\">\n");
            try w.writeAll(example_src);
            try w.writeAll("\n</div>\n");

            try w.writeAll("<details>\n<summary>Source</summary>\n<pre><code>");
            try emitHtmlEscaped(w, example_src);
            try w.writeAll("</code></pre>\n</details>\n");
        } else |_| {
            std.log.warn("missing example: {s}", .{example_path});
        }

        try w.writeAll("</article>\n");
    }
}

fn emitHtmlEscaped(w: std.ArrayList(u8).Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

fn fatal(msg: []const u8) noreturn {
    std.process.fatal("{s}", .{msg});
}

fn fatalFmt(comptime fmt: []const u8, args: anytype) noreturn {
    std.process.fatal(fmt, args);
}
