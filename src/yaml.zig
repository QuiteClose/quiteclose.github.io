/// Minimal YAML parser supporting maps, lists, quoted/unquoted strings, and comments.
/// All returned slices point into the original input buffer, which must outlive the
/// parsed Value tree. Designed for use with an arena allocator (no deinit needed).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    map: Map,
    list: []const Value,

    pub const Map = std.StringArrayHashMapUnmanaged(Value);

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .map => |m| m.get(key),
            else => null,
        };
    }

    pub fn str(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }
};

const Line = struct {
    indent: usize,
    content: []const u8,
};

pub fn parse(allocator: Allocator, input: []const u8) !Value {
    var line_list: std.ArrayList(Line) = .{};
    defer line_list.deinit(allocator);

    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |raw| {
        const indent = countIndent(raw);
        const trimmed = std.mem.trimRight(u8, raw, " \t\r");
        if (indent >= trimmed.len) continue;
        const after_indent = trimmed[indent..];
        const stripped = std.mem.trimRight(u8, stripComment(after_indent), " \t");
        if (stripped.len == 0) continue;
        try line_list.append(allocator, .{ .indent = indent, .content = stripped });
    }

    var index: usize = 0;
    return parseMap(allocator, line_list.items, &index, 0);
}

fn parseMap(allocator: Allocator, lines: []const Line, index: *usize, base_indent: usize) !Value {
    var map = Value.Map{};

    while (index.* < lines.len and lines[index.*].indent == base_indent) {
        const line = lines[index.*];
        const colon = std.mem.indexOfScalar(u8, line.content, ':') orelse {
            index.* += 1;
            continue;
        };

        const key = std.mem.trimRight(u8, line.content[0..colon], " \t");
        const rest = if (colon + 1 < line.content.len)
            std.mem.trimLeft(u8, line.content[colon + 1 ..], " \t")
        else
            "";

        if (rest.len > 0) {
            if (rest.len >= 2 and rest[0] == '[' and rest[rest.len - 1] == ']') {
                const inner = rest[1 .. rest.len - 1];
                var items: std.ArrayList(Value) = .{};
                if (inner.len > 0) {
                    var split_iter = std.mem.splitScalar(u8, inner, ',');
                    while (split_iter.next()) |item| {
                        const trimmed_item = std.mem.trim(u8, item, " \t");
                        if (trimmed_item.len > 0) {
                            try items.append(allocator, .{ .string = stripQuotes(trimmed_item) });
                        }
                    }
                }
                try map.put(allocator, key, .{ .list = try items.toOwnedSlice(allocator) });
            } else {
                try map.put(allocator, key, .{ .string = stripQuotes(rest) });
            }
            index.* += 1;
        } else {
            index.* += 1;
            if (index.* < lines.len and lines[index.*].indent > base_indent) {
                const child_indent = lines[index.*].indent;
                if (std.mem.startsWith(u8, lines[index.*].content, "- ")) {
                    try map.put(allocator, key, try parseList(allocator, lines, index, child_indent));
                } else {
                    try map.put(allocator, key, try parseMap(allocator, lines, index, child_indent));
                }
            }
        }
    }

    return .{ .map = map };
}

fn parseList(allocator: Allocator, lines: []const Line, index: *usize, base_indent: usize) !Value {
    var items: std.ArrayList(Value) = .{};

    while (index.* < lines.len and
        lines[index.*].indent == base_indent and
        std.mem.startsWith(u8, lines[index.*].content, "- "))
    {
        const val = std.mem.trimLeft(u8, lines[index.*].content[2..], " \t");
        try items.append(allocator, .{ .string = stripQuotes(val) });
        index.* += 1;
    }

    return .{ .list = try items.toOwnedSlice(allocator) };
}

fn countIndent(line: []const u8) usize {
    for (line, 0..) |_, i| {
        if (line[i] != ' ') return i;
    }
    return line.len;
}

fn stripComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '\'' => if (!in_double) {
                in_single = !in_single;
            },
            '"' => if (!in_single) {
                in_double = !in_double;
            },
            '#' => if (!in_single and !in_double) {
                return line[0..i];
            },
            else => {},
        }
    }
    return line;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '\'' and s[s.len - 1] == '\'') or
            (s[0] == '"' and s[s.len - 1] == '"'))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "simple key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\name: hello
        \\value: world
    );
    try std.testing.expectEqualStrings("hello", result.get("name").?.str().?);
    try std.testing.expectEqualStrings("world", result.get("value").?.str().?);
}

test "nested maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\outer:
        \\  inner: value
        \\  deep:
        \\    leaf: found
    );
    try std.testing.expectEqualStrings("value", result.get("outer").?.get("inner").?.str().?);
    try std.testing.expectEqualStrings("found", result.get("outer").?.get("deep").?.get("leaf").?.str().?);
}

test "lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\items:
        \\  - one
        \\  - two
        \\  - three
    );
    const items = result.get("items").?.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("one", items[0].str().?);
    try std.testing.expectEqualStrings("two", items[1].str().?);
    try std.testing.expectEqualStrings("three", items[2].str().?);
}

test "quoted strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\single: '#ff0000'
        \\double: "hello world"
        \\unquoted: plain text
    );
    try std.testing.expectEqualStrings("#ff0000", result.get("single").?.str().?);
    try std.testing.expectEqualStrings("hello world", result.get("double").?.str().?);
    try std.testing.expectEqualStrings("plain text", result.get("unquoted").?.str().?);
}

test "comments are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\# full line comment
        \\key: value
        \\
        \\# another comment
        \\other: data
    );
    try std.testing.expectEqualStrings("value", result.get("key").?.str().?);
    try std.testing.expectEqualStrings("data", result.get("other").?.str().?);
}

test "hash inside quotes is not a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\colour: '#002b36'
    );
    try std.testing.expectEqualStrings("#002b36", result.get("colour").?.str().?);
}

test "scheme file structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try std.fs.cwd().readFileAlloc(a, "data/colours/solarized.yaml", 1 << 20);
    const result = try parse(a, input);

    const light = result.get("light").?;
    try std.testing.expectEqualStrings("Solarized Light", light.get("meta").?.get("name").?.str().?);
    try std.testing.expectEqualStrings("#002b36", light.get("palette").?.get("base03").?.str().?);
    try std.testing.expectEqualStrings("blue", light.get("styles").?.get("text").?.get("link").?.str().?);
    try std.testing.expectEqualStrings("green", light.get("syntax").?.get("keyword").?.str().?);
    try std.testing.expectEqualStrings("cyan", light.get("syntax").?.get("constant").?.str().?);
    try std.testing.expectEqualStrings("base00", light.get("syntax").?.get("variable").?.str().?);
    try std.testing.expectEqualStrings("base00", light.get("syntax").?.get("punctuation").?.str().?);

    const dark = result.get("dark").?;
    try std.testing.expectEqualStrings("Solarized Dark", dark.get("meta").?.get("name").?.str().?);
    try std.testing.expectEqualStrings("#002b36", dark.get("palette").?.get("base3").?.str().?);
}

test "all scheme files parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schemes = [_][]const u8{
        "borland", "crt", "dune", "github", "gruvbox",
        "rosepine", "solarized", "srcery", "tomorrow",
    };
    for (schemes) |name| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "data/colours/{s}.yaml", .{name}) catch unreachable;
        const input = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
        const result = try parse(a, input);

        const light = result.get("light") orelse return error.MissingLight;
        const dark = result.get("dark") orelse return error.MissingDark;

        _ = light.get("meta").?.get("name").?.str() orelse return error.MissingLightName;
        _ = dark.get("meta").?.get("name").?.str() orelse return error.MissingDarkName;
        _ = light.get("palette") orelse return error.MissingLightPalette;
        _ = dark.get("palette") orelse return error.MissingDarkPalette;
        _ = light.get("styles") orelse return error.MissingLightStyles;
        _ = dark.get("styles") orelse return error.MissingDarkStyles;
        _ = light.get("syntax") orelse return error.MissingLightSyntax;
        _ = dark.get("syntax") orelse return error.MissingDarkSyntax;
    }
}

test "inline lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\values: [1, 2, 3]
        \\single: [only]
        \\empty: []
        \\normal: plain value
    );
    const values = result.get("values").?.list;
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("1", values[0].str().?);
    try std.testing.expectEqualStrings("2", values[1].str().?);
    try std.testing.expectEqualStrings("3", values[2].str().?);

    const single = result.get("single").?.list;
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("only", single[0].str().?);

    const empty = result.get("empty").?.list;
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try std.testing.expectEqualStrings("plain value", result.get("normal").?.str().?);
}

test "layout manifest structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = try std.fs.cwd().readFileAlloc(a, "styles/default/layout.yaml", 1 << 20);
    const result = try parse(a, input);

    try std.testing.expectEqualStrings("Default", result.get("name").?.str().?);

    const css = result.get("css").?.list;
    try std.testing.expectEqualStrings("_core/reset.css", css[0].str().?);

    const highlights = result.get("highlights").?;
    const default_scheme = highlights.get("default").?;
    try std.testing.expectEqualStrings("solarized", default_scheme.get("scheme").?.str().?);
    try std.testing.expectEqualStrings("dark", default_scheme.get("mode").?.str().?);

    const schemes = highlights.get("schemes").?.list;
    try std.testing.expect(schemes.len == 18);
    try std.testing.expectEqualStrings("borland.light", schemes[0].str().?);
    try std.testing.expectEqualStrings("crt.dark", schemes[schemes.len - 1].str().?);
}
