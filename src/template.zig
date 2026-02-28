const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Entry = struct {
    values: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    pub fn get(self: *const Entry, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

pub const Context = struct {
    vars: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    collections: std.StringArrayHashMapUnmanaged([]const Entry) = .{},
    dev_mode: bool = false,

    pub fn putVar(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.vars.put(a, key, value);
    }

    pub fn getVar(self: *const Context, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    pub fn putAttr(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.attrs.put(a, key, value);
    }

    pub fn getAttr(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }

    pub fn putSlot(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.slots.put(a, key, value);
    }

    pub fn getSlot(self: *const Context, key: []const u8) ?[]const u8 {
        return self.slots.get(key);
    }

    pub fn hasSlot(self: *const Context, key: []const u8) bool {
        return self.slots.contains(key);
    }

    pub fn putCollection(self: *Context, a: Allocator, name: []const u8, entries: []const Entry) !void {
        try self.collections.put(a, name, entries);
    }

    pub fn getCollection(self: *const Context, name: []const u8) ?[]const Entry {
        return self.collections.get(name);
    }

    pub fn deinit(self: *Context, a: Allocator) void {
        self.vars.deinit(a);
        self.attrs.deinit(a);
        self.slots.deinit(a);
        self.collections.deinit(a);
    }
};

pub const Resolver = struct {
    templates: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    pub fn put(self: *Resolver, a: Allocator, name: []const u8, content: []const u8) !void {
        try self.templates.put(a, name, content);
    }

    pub fn get(self: *const Resolver, name: []const u8) ?[]const u8 {
        return self.templates.get(name);
    }

    pub fn deinit(self: *Resolver, a: Allocator) void {
        self.templates.deinit(a);
    }
};

pub const RenderError = error{
    MalformedElement,
    TemplateNotFound,
    CircularReference,
    DuplicateSlotDefinition,
    OutOfMemory,
};

const max_depth = 50;

pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    return renderTemplate(a, input, ctx, resolver);
}

fn renderTemplate(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    const start = skipWhitespace(input);
    if (!std.mem.startsWith(u8, input[start..], "<x-extend ")) {
        return renderContent(a, input, ctx, resolver, 0);
    }

    var current = input;
    var slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer slots.deinit(a);

    var sit = ctx.slots.iterator();
    while (sit.next()) |entry| {
        try slots.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }

    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    defer visited.deinit(a);

    while (true) {
        const ws = skipWhitespace(current);
        if (!std.mem.startsWith(u8, current[ws..], "<x-extend ")) break;

        const rest = current[ws..];
        const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
        const parent_name = extractAttrValue(rest[0 .. tag_end + 1], "template") orelse
            return error.MalformedElement;

        if (visited.contains(parent_name)) return error.CircularReference;
        try visited.put(a, parent_name, {});

        try parseDefines(a, rest[tag_end + 1 ..], &slots);

        current = resolver.get(parent_name) orelse return error.TemplateNotFound;
    }

    var render_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = ctx.attrs,
        .slots = slots,
        .collections = ctx.collections,
        .dev_mode = ctx.dev_mode,
    };

    return renderContent(a, current, &render_ctx, resolver, 0);
}

fn renderContent(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, depth: usize) RenderError![]const u8 {
    if (depth > max_depth) return error.CircularReference;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "<x-var ") or
            std.mem.startsWith(u8, input[i..], "<x-var/>"))
        {
            const rest = input[i..];
            const end_offset = std.mem.indexOf(u8, rest, "/>") orelse
                return error.MalformedElement;
            const tag = rest[0 .. end_offset + 2];
            const name = extractAttrValue(tag, "name") orelse
                return error.MalformedElement;
            if (ctx.getVar(name)) |value| {
                try appendEscaped(a, &out, value);
            }
            i += end_offset + 2;
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-attr ") or
            std.mem.startsWith(u8, input[i..], "<x-attr/>"))
        {
            const rest = input[i..];
            const end_offset = std.mem.indexOf(u8, rest, "/>") orelse
                return error.MalformedElement;
            const tag = rest[0 .. end_offset + 2];
            const name = extractAttrValue(tag, "name") orelse
                return error.MalformedElement;
            if (ctx.getAttr(name)) |value| {
                try appendEscaped(a, &out, value);
            }
            i += end_offset + 2;
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-slot")) {
            i = try renderSlot(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-include ")) {
            i = try renderInclude(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-for ")) {
            i = try renderFor(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-if ") or
            std.mem.startsWith(u8, input[i..], "<x-if>"))
        {
            i = try renderConditional(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (input[i] == '<' and i + 1 < input.len and
            input[i + 1] != '/' and input[i + 1] != '!')
        {
            const rest = input[i..];
            if (findTagEnd(rest)) |end_offset| {
                const tag = rest[0 .. end_offset + 1];
                if (std.mem.indexOf(u8, tag, "x-var:") != null or
                    std.mem.indexOf(u8, tag, "x-attr:") != null)
                {
                    try renderBoundTag(a, tag, ctx, &out);
                    i += end_offset + 1;
                    continue;
                }
            }
        }

        try out.append(a, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(a);
}

fn renderSlot(a: Allocator, input: []const u8, start: usize, ctx: *const Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';

    if (is_self_closing) {
        const tag = rest[0 .. tag_end + 1];
        const name = extractAttrValue(tag, "name") orelse "";
        if (ctx.getSlot(name)) |content| {
            const rendered = try renderContent(a, content, ctx, resolver, depth);
            defer a.free(rendered);
            try out.appendSlice(a, rendered);
        }
        return start + tag_end + 1;
    }

    const tag = rest[0 .. tag_end + 1];
    const name = extractAttrValue(tag, "name") orelse "";
    const content_start = tag_end + 1;
    const close_tag = std.mem.indexOf(u8, rest[content_start..], "</x-slot>") orelse
        return error.MalformedElement;
    const default_content = rest[content_start .. content_start + close_tag];
    const total_end = content_start + close_tag + "</x-slot>".len;

    if (ctx.getSlot(name)) |content| {
        const rendered = try renderContent(a, content, ctx, resolver, depth);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
    } else {
        const rendered = try renderContent(a, default_content, ctx, resolver, depth);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
    }
    return start + total_end;
}

fn renderInclude(a: Allocator, input: []const u8, start: usize, ctx: *const Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = extractAttrValue(tag, "template") orelse
        return error.MalformedElement;

    var inc_attrs = try parseTagAttrs(a, tag);
    defer inc_attrs.deinit(a);

    var body: []const u8 = "";
    var consumed: usize = tag_end + 1;

    if (!is_self_closing) {
        const content_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[content_start..], "</x-include>") orelse
            return error.MalformedElement;
        body = rest[content_start .. content_start + close];
        consumed = content_start + close + "</x-include>".len;
    }

    const tmpl_content = resolver.get(tmpl_name) orelse return error.TemplateNotFound;

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer child_slots.deinit(a);
    if (body.len > 0) {
        try child_slots.put(a, "", body);
    }

    var child_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = inc_attrs,
        .slots = child_slots,
        .collections = ctx.collections,
        .dev_mode = ctx.dev_mode,
    };

    const rendered = try renderContent(a, tmpl_content, &child_ctx, resolver, depth + 1);
    defer a.free(rendered);
    try out.appendSlice(a, rendered);

    return start + consumed;
}

fn parseTagAttrs(a: Allocator, tag: []const u8) RenderError!std.StringArrayHashMapUnmanaged([]const u8) {
    var attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    errdefer attrs.deinit(a);

    var i: usize = 1;
    while (i < tag.len and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}

    while (i < tag.len) {
        while (i < tag.len and tag[i] == ' ') : (i += 1) {}
        if (i >= tag.len or tag[i] == '/' or tag[i] == '>') break;

        const name_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
        const attr_name = tag[name_start..i];

        if (i < tag.len and tag[i] == '=') {
            i += 1;
            if (i < tag.len and tag[i] == '"') {
                i += 1;
                const val_start = i;
                while (i < tag.len and tag[i] != '"') : (i += 1) {}
                const attr_value = tag[val_start..i];
                if (i < tag.len) i += 1;

                if (!std.mem.eql(u8, attr_name, "template")) {
                    try attrs.put(a, attr_name, attr_value);
                }
            }
        } else {
            if (!std.mem.eql(u8, attr_name, "template")) {
                try attrs.put(a, attr_name, "");
            }
        }
    }

    return attrs;
}

fn renderConditional(a: Allocator, input: []const u8, start: usize, ctx: *const Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    var pos = start;
    var matched = false;

    {
        const rest = input[pos..];
        const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
        const tag = rest[0 .. tag_end + 1];
        const body_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[body_start..], "</x-if>") orelse
            return error.MalformedElement;

        if (evaluateCondition(tag, ctx)) {
            const body = rest[body_start .. body_start + close];
            const rendered = try renderContent(a, body, ctx, resolver, depth);
            defer a.free(rendered);
            try out.appendSlice(a, rendered);
            matched = true;
        }
        pos += body_start + close + "</x-if>".len;
    }

    while (pos < input.len) {
        const ws = skipWhitespace(input[pos..]);
        if (pos + ws >= input.len or !std.mem.startsWith(u8, input[pos + ws ..], "<x-elif ")) break;
        pos += ws;

        const rest = input[pos..];
        const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
        const tag = rest[0 .. tag_end + 1];
        const body_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[body_start..], "</x-elif>") orelse
            return error.MalformedElement;

        if (!matched and evaluateCondition(tag, ctx)) {
            const body = rest[body_start .. body_start + close];
            const rendered = try renderContent(a, body, ctx, resolver, depth);
            defer a.free(rendered);
            try out.appendSlice(a, rendered);
            matched = true;
        }
        pos += body_start + close + "</x-elif>".len;
    }

    {
        const ws = skipWhitespace(input[pos..]);
        if (pos + ws < input.len and std.mem.startsWith(u8, input[pos + ws ..], "<x-else>")) {
            pos += ws + "<x-else>".len;
            const close = std.mem.indexOf(u8, input[pos..], "</x-else>") orelse
                return error.MalformedElement;

            if (!matched) {
                const body = input[pos .. pos + close];
                const rendered = try renderContent(a, body, ctx, resolver, depth);
                defer a.free(rendered);
                try out.appendSlice(a, rendered);
            }
            pos += close + "</x-else>".len;
        }
    }

    return pos;
}

fn evaluateCondition(tag: []const u8, ctx: *const Context) bool {
    if (extractAttrValue(tag, "var")) |name| {
        return evalComparison(tag, ctx.getVar(name));
    }
    if (extractAttrValue(tag, "attr")) |name| {
        return evalComparison(tag, ctx.getAttr(name));
    }
    if (extractAttrValue(tag, "slot")) |name| {
        const exists = ctx.hasSlot(name);
        if (hasBoolAttr(tag, "not-exists")) return !exists;
        return exists;
    }
    return false;
}

fn evalComparison(tag: []const u8, value: ?[]const u8) bool {
    if (extractAttrValue(tag, "equals")) |expected| {
        return if (value) |v| std.mem.eql(u8, v, expected) else false;
    }
    if (extractAttrValue(tag, "not-equals")) |expected| {
        return if (value) |v| !std.mem.eql(u8, v, expected) else true;
    }
    if (hasBoolAttr(tag, "not-exists")) {
        return value == null or (if (value) |v| v.len == 0 else true);
    }
    return if (value) |v| v.len > 0 else false;
}

fn hasBoolAttr(tag: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < tag.len) {
        if (tag[i] == '"') {
            i += 1;
            while (i < tag.len and tag[i] != '"') : (i += 1) {}
            if (i < tag.len) i += 1;
        } else if (tag[i] == ' ' and i + 1 + name.len <= tag.len and
            std.mem.eql(u8, tag[i + 1 .. i + 1 + name.len], name))
        {
            const after = i + 1 + name.len;
            if (after >= tag.len or tag[after] == ' ' or
                tag[after] == '/' or tag[after] == '>')
            {
                return true;
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return false;
}

fn renderFor(a: Allocator, input: []const u8, start: usize, ctx: *const Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
    const tag = rest[0 .. tag_end + 1];

    const item_prefix = blk: {
        const after_for = "<x-for ".len;
        const space = std.mem.indexOfPos(u8, tag, after_for, " ") orelse
            return error.MalformedElement;
        break :blk tag[after_for..space];
    };

    const collection_name = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse
            return error.MalformedElement;
        const after_in = in_tok + 4;
        var end = after_in;
        while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
        break :blk tag[after_in..end];
    };

    const sort_field = extractAttrValue(tag, "sort");
    const order_desc = if (extractAttrValue(tag, "order")) |o|
        std.mem.eql(u8, o, "desc")
    else
        false;

    const body_start = start + tag_end + 1;
    const close_offset = findMatchingClose(input[body_start..], "<x-for ", "</x-for>") orelse
        return error.MalformedElement;
    const body = input[body_start .. body_start + close_offset];
    const after_close = body_start + close_offset + "</x-for>".len;

    const entries = ctx.getCollection(collection_name) orelse return after_close;

    var filtered: std.ArrayList(Entry) = .{};
    defer filtered.deinit(a);
    for (entries) |entry| {
        if (!ctx.dev_mode) {
            if (entry.get("draft")) |d| {
                if (std.mem.eql(u8, d, "true")) continue;
            }
        }
        try filtered.append(a, entry);
    }

    const items = try filtered.toOwnedSlice(a);
    defer a.free(items);

    if (sort_field) |field| {
        const Sort = struct {
            field_name: []const u8,
            descending: bool,

            pub fn lessThan(self_sort: @This(), lhs: Entry, rhs: Entry) bool {
                const a_val = lhs.get(self_sort.field_name) orelse "";
                const b_val = rhs.get(self_sort.field_name) orelse "";
                const cmp = std.mem.order(u8, a_val, b_val);
                if (self_sort.descending) return cmp == .gt;
                return cmp == .lt;
            }
        };
        std.mem.sort(Entry, items, Sort{ .field_name = field, .descending = order_desc }, Sort.lessThan);
    }

    for (items) |entry| {
        var child_ctx: Context = .{
            .attrs = ctx.attrs,
            .slots = ctx.slots,
            .collections = ctx.collections,
            .dev_mode = ctx.dev_mode,
        };

        var child_vars: @TypeOf(ctx.vars) = .{};
        var it = ctx.vars.iterator();
        while (it.next()) |kv| {
            try child_vars.put(a, kv.key_ptr.*, kv.value_ptr.*);
        }

        var allocated_keys: std.ArrayList([]const u8) = .{};
        defer {
            for (allocated_keys.items) |k| a.free(k);
            allocated_keys.deinit(a);
        }

        var entry_it = entry.values.iterator();
        while (entry_it.next()) |kv| {
            const prefixed = try std.fmt.allocPrint(a, "{s}.{s}", .{ item_prefix, kv.key_ptr.* });
            try allocated_keys.append(a, prefixed);
            try child_vars.put(a, prefixed, kv.value_ptr.*);
        }
        child_ctx.vars = child_vars;
        defer child_vars.deinit(a);

        const rendered = try renderContent(a, body, &child_ctx, resolver, depth + 1);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
    }

    return after_close;
}

fn findMatchingClose(input: []const u8, open_tag: []const u8, close_tag: []const u8) ?usize {
    var nesting: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], open_tag)) {
            nesting += 1;
            i += open_tag.len;
        } else if (std.mem.startsWith(u8, input[i..], close_tag)) {
            if (nesting == 0) return i;
            nesting -= 1;
            i += close_tag.len;
        } else {
            i += 1;
        }
    }
    return null;
}

fn skipWhitespace(input: []const u8) usize {
    var i: usize = 0;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t' or
        input[i] == '\n' or input[i] == '\r')) : (i += 1)
    {}
    return i;
}

fn parseDefines(a: Allocator, input: []const u8, slots: *std.StringArrayHashMapUnmanaged([]const u8)) RenderError!void {
    var i: usize = 0;
    while (i < input.len) {
        const ws = skipWhitespace(input[i..]);
        i += ws;
        if (i >= input.len) break;

        if (std.mem.startsWith(u8, input[i..], "<x-define ")) {
            const rest = input[i..];
            const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
            const slot_name = extractAttrValue(rest[0 .. tag_end + 1], "slot") orelse
                return error.MalformedElement;
            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], "</x-define>") orelse
                return error.MalformedElement;
            const content = rest[content_start .. content_start + close];
            try slots.put(a, slot_name, content);
            i += content_start + close + "</x-define>".len;
        } else {
            i += 1;
        }
    }
}

fn findTagEnd(input: []const u8) ?usize {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '"') {
            i += 1;
            while (i < input.len and input[i] != '"') : (i += 1) {}
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

fn extractAttrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        if (std.mem.startsWith(u8, tag[i..], name)) {
            const after = i + name.len;
            if (after + 1 < tag.len and tag[after] == '=' and tag[after + 1] == '"') {
                const val_start = after + 2;
                if (std.mem.indexOfScalar(u8, tag[val_start..], '"')) |end| {
                    return tag[val_start .. val_start + end];
                }
            }
        }
        i += 1;
    }
    return null;
}

fn appendEscaped(a: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, c),
        }
    }
}

fn renderBoundTag(a: Allocator, tag: []const u8, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    var i: usize = 0;
    while (i < tag.len) {
        if (i > 0 and tag[i] == ' ' and i + 1 < tag.len) {
            const after_space = tag[i + 1 ..];
            const binding = if (std.mem.startsWith(u8, after_space, "x-var:"))
                Binding{ .prefix_len = 6, .lookup = .variable }
            else if (std.mem.startsWith(u8, after_space, "x-attr:"))
                Binding{ .prefix_len = 7, .lookup = .attribute }
            else
                null;

            if (binding) |b| {
                i += 1; // skip space
                i += b.prefix_len;
                const attr_start = i;
                while (i < tag.len and tag[i] != '=') : (i += 1) {}
                const html_attr = tag[attr_start..i];
                i += 2; // skip '="'
                const var_start = i;
                while (i < tag.len and tag[i] != '"') : (i += 1) {}
                const ref_name = tag[var_start..i];
                i += 1; // skip closing '"'

                const value = switch (b.lookup) {
                    .variable => ctx.getVar(ref_name),
                    .attribute => ctx.getAttr(ref_name),
                };

                if (value) |v| {
                    try out.append(a, ' ');
                    try out.appendSlice(a, html_attr);
                    try out.appendSlice(a, "=\"");
                    try appendEscaped(a, out, v);
                    try out.append(a, '"');
                }
                continue;
            }
        }
        try out.append(a, tag[i]);
        i += 1;
    }
}

const Binding = struct {
    prefix_len: usize,
    lookup: enum { variable, attribute },
};

// ---------------------------------------------------------------------------
// x-var tests
// ---------------------------------------------------------------------------

test "var_basic" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "title", "Home");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<p><x-var name=\"title\" /></p>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<p>Home</p>", result);
}

test "var_missing" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<p><x-var name=\"title\" /></p>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<p></p>", result);
}

test "var_html_escaped" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "title", "Tom & Jerry");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<p><x-var name=\"title\" /></p>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<p>Tom &amp; Jerry</p>", result);
}

test "var_dotted_path" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "data.site.title", "QuiteClose");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<p><x-var name=\"data.site.title\" /></p>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<p>QuiteClose</p>", result);
}

test "var_attr_basic" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "data.site.url", "https://quiteclose.github.io");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<a x-var:href=\"data.site.url\">link</a>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<a href=\"https://quiteclose.github.io\">link</a>", result);
}

test "var_attr_missing_omits" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<a x-var:href=\"url\">link</a>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<a>link</a>", result);
}

// ---------------------------------------------------------------------------
// x-slot / x-define tests
// ---------------------------------------------------------------------------

test "slot_named" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putSlot(a, "main", "<p>Hello</p>");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<div><x-slot name=\"main\" /></div>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div><p>Hello</p></div>", result);
}

test "slot_default_anonymous" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putSlot(a, "", "<p>Body</p>");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<main><x-slot /></main>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<main><p>Body</p></main>", result);
}

test "slot_with_default_content_unfilled" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<head><x-slot name=\"scripts\"><script src=\"/default.js\"></script></x-slot></head>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<head><script src=\"/default.js\"></script></head>",
        result,
    );
}

test "slot_with_default_content_filled" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putSlot(a, "scripts", "<script src=\"/custom.js\"></script>");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<head><x-slot name=\"scripts\"><script src=\"/default.js\"></script></x-slot></head>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<head><script src=\"/custom.js\"></script></head>",
        result,
    );
}

test "slot_unfilled_renders_empty" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<div><x-slot name=\"sidebar\" /></div>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div></div>", result);
}

// ---------------------------------------------------------------------------
// x-extend tests
// ---------------------------------------------------------------------------

test "extend_basic" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "base.html",
        \\<html><head><x-slot name="head" /></head><body><x-slot name="body" /></body></html>
    );

    const child =
        \\<x-extend template="base.html">
        \\<x-define slot="head"><title>Hi</title></x-define>
        \\<x-define slot="body"><p>Hello</p></x-define>
    ;

    const result = try render(a, child, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings(
        "<html><head><title>Hi</title></head><body><p>Hello</p></body></html>",
        result,
    );
}

test "extend_three_levels" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "base.html",
        \\<html><x-slot name="body" /></html>
    );
    try resolver.put(a, "with-chrome.html",
        \\<x-extend template="base.html">
        \\<x-define slot="body"><header /><main><x-slot name="content" /></main></x-define>
    );

    const page =
        \\<x-extend template="with-chrome.html">
        \\<x-define slot="content"><p>Page</p></x-define>
    ;

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings(
        "<html><header /><main><p>Page</p></main></html>",
        result,
    );
}

test "extend_circular_is_error" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "a.html",
        \\<x-extend template="b.html">
        \\<x-define slot="x">A</x-define>
    );
    try resolver.put(a, "b.html",
        \\<x-extend template="a.html">
        \\<x-define slot="x">B</x-define>
    );

    const result = render(a, "<x-extend template=\"a.html\">\n<x-define slot=\"x\">C</x-define>", &ctx, &resolver);
    try testing.expectError(error.CircularReference, result);
}

// ---------------------------------------------------------------------------
// x-include / x-attr tests
// ---------------------------------------------------------------------------

test "include_simple" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "banner.html", "<p>Welcome</p>");

    const result = try render(a, "<div><x-include template=\"banner.html\" /></div>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div><p>Welcome</p></div>", result);
}

test "include_with_body" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "wrapper.html", "<div class=\"wrapper\"><x-slot /></div>");

    const result = try render(a, "<x-include template=\"wrapper.html\"><p>Content</p></x-include>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div class=\"wrapper\"><p>Content</p></div>", result);
}

test "include_with_attrs" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "greeting.html", "<p>Hello, <x-attr name=\"who\" /></p>");

    const result = try render(a, "<x-include template=\"greeting.html\" who=\"World\" />", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<p>Hello, World</p>", result);
}

test "include_with_attrs_and_body" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "quote.html",
        \\<blockquote><x-slot /><cite><x-attr name="author" /></cite></blockquote>
    );

    const result = try render(
        a,
        "<x-include template=\"quote.html\" author=\"Dr. King\">I have a dream.</x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<blockquote>I have a dream.<cite>Dr. King</cite></blockquote>",
        result,
    );
}

test "include_attr_context" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "button.html",
        \\<button class="button" x-attr:data-variant="variant"><x-slot /></button>
    );

    const result = try render(
        a,
        "<x-include template=\"button.html\" variant=\"primary\">Click</x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<button class=\"button\" data-variant=\"primary\">Click</button>",
        result,
    );
}

test "include_nested" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "inner.html", "<em>inner</em>");
    try resolver.put(a, "outer.html", "<div><x-include template=\"inner.html\" /></div>");

    const result = try render(a, "<x-include template=\"outer.html\" />", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div><em>inner</em></div>", result);
}

test "include_circular_is_error" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "loop.html", "<x-include template=\"loop.html\" />");

    const result = render(a, "<x-include template=\"loop.html\" />", &ctx, &resolver);
    try testing.expectError(error.CircularReference, result);
}

test "include_attr_scope_isolation" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "child.html", "[<x-attr name=\"color\" />]");
    try resolver.put(a, "parent.html", "<x-include template=\"child.html\" />");

    const result = try render(
        a,
        "<x-include template=\"parent.html\" color=\"red\" />",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("[]", result);
}

// ---------------------------------------------------------------------------
// x-if / x-elif / x-else tests
// ---------------------------------------------------------------------------

test "if_var_exists_true" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "title", "Home");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<x-if var=\"title\">YES</x-if>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("YES", result);
}

test "if_var_exists_false" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<x-if var=\"title\">YES</x-if>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("", result);
}

test "if_var_equals" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "mode", "development");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-if var=\"mode\" equals=\"development\">DEV</x-if>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("DEV", result);
}

test "if_var_equals_false" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "mode", "production");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-if var=\"mode\" equals=\"development\">DEV</x-if>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("", result);
}

test "if_var_not_exists" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<x-if var=\"title\" not-exists>MISSING</x-if>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("MISSING", result);
}

test "if_else" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(a, "<x-if var=\"title\">YES</x-if><x-else>NO</x-else>", &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("NO", result);
}

test "if_elif_else" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "mode", "staging");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const input =
        \\<x-if var="mode" equals="dev">DEV</x-if><x-elif var="mode" equals="staging">STG</x-elif><x-else>PROD</x-else>
    ;

    const result = try render(a, input, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("STG", result);
}

test "if_attr" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "comp.html", "<x-if attr=\"variant\">STYLED</x-if><x-else>PLAIN</x-else>");

    const result = try render(
        a,
        "<x-include template=\"comp.html\" variant=\"primary\" />",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("STYLED", result);
}

test "if_slot_exists" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putSlot(a, "sidebar", "<nav>links</nav>");

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-if slot=\"sidebar\"><aside><x-slot name=\"sidebar\" /></aside></x-if>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("<aside><nav>links</nav></aside>", result);
}

// ---------------------------------------------------------------------------
// x-for tests
// ---------------------------------------------------------------------------

test "for_data_list" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "label", "Home");
    try entries[0].values.put(a, "url", "/");
    try entries[1].values.put(a, "label", "About");
    try entries[1].values.put(a, "url", "/about/");
    defer for (&entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "data.site.nav", entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for item in data.site.nav><a x-var:href=\"item.url\"><x-var name=\"item.label\" /></a></x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<a href=\"/\">Home</a><a href=\"/about/\">About</a>",
        result,
    );
}

test "for_pages" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "title", "First Post");
    try entries[0].values.put(a, "x-path", "/posts/first/");
    try entries[1].values.put(a, "title", "Second Post");
    try entries[1].values.put(a, "x-path", "/posts/second/");
    defer for (&entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "pages.posts", entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for post in pages.posts><li><a x-var:href=\"post.x-path\"><x-var name=\"post.title\" /></a></li></x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings(
        "<li><a href=\"/posts/first/\">First Post</a></li><li><a href=\"/posts/second/\">Second Post</a></li>",
        result,
    );
}

test "for_sorted" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [3]Entry = .{ .{}, .{}, .{} };
    try entries[0].values.put(a, "title", "Cherry");
    try entries[1].values.put(a, "title", "Apple");
    try entries[2].values.put(a, "title", "Banana");
    defer for (&entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "data.fruits", entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for item in data.fruits sort=\"title\"><x-var name=\"item.title\" />,</x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("Apple,Banana,Cherry,", result);
}

test "for_sorted_desc" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [3]Entry = .{ .{}, .{}, .{} };
    try entries[0].values.put(a, "title", "Cherry");
    try entries[1].values.put(a, "title", "Apple");
    try entries[2].values.put(a, "title", "Banana");
    defer for (&entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "data.fruits", entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for item in data.fruits sort=\"title\" order=\"desc\"><x-var name=\"item.title\" />,</x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("Cherry,Banana,Apple,", result);
}

test "for_excludes_drafts" {
    const a = testing.allocator;
    var ctx: Context = .{ .dev_mode = false };
    defer ctx.deinit(a);

    var entries: [3]Entry = .{ .{}, .{}, .{} };
    try entries[0].values.put(a, "title", "Published");
    try entries[1].values.put(a, "title", "Draft");
    try entries[1].values.put(a, "draft", "true");
    try entries[2].values.put(a, "title", "Also Published");
    defer for (&entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "pages.posts", entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for post in pages.posts><x-var name=\"post.title\" />,</x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("Published,Also Published,", result);
}

test "for_nested_shadow" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var outer_entries: [2]Entry = .{ .{}, .{} };
    try outer_entries[0].values.put(a, "name", "A");
    try outer_entries[1].values.put(a, "name", "B");
    defer for (&outer_entries) |*e| e.values.deinit(a);

    var inner_entries: [2]Entry = .{ .{}, .{} };
    try inner_entries[0].values.put(a, "name", "1");
    try inner_entries[1].values.put(a, "name", "2");
    defer for (&inner_entries) |*e| e.values.deinit(a);

    try ctx.putCollection(a, "data.rows", outer_entries[0..]);
    try ctx.putCollection(a, "data.cols", inner_entries[0..]);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = try render(
        a,
        "<x-for row in data.rows><x-for col in data.cols><x-var name=\"row.name\" /><x-var name=\"col.name\" />,</x-for></x-for>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expectEqualStrings("A1,A2,B1,B2,", result);
}

// ---------------------------------------------------------------------------
// Integration test: full page render
// ---------------------------------------------------------------------------

test "integration_full_page" {
    const a = testing.allocator;

    // base.html: outer shell with slots for title, head, and content
    const base_tmpl =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8" />
        \\<title><x-slot name="title">Untitled</x-slot></title>
        \\<x-slot name="head" />
        \\</head>
        \\<body>
        \\<x-slot name="content" />
        \\</body>
        \\</html>
    ;

    // page.html: extends base, fills content with nav + main slot
    const page_tmpl =
        \\<x-extend template="base.html">
        \\<x-define slot="content">
        \\<x-include template="nav.html" class="site-nav" />
        \\<main><x-slot name="main">No content.</x-slot></main>
        \\<footer>&copy; <x-var name="site.author" /></footer>
        \\</x-define>
    ;

    // nav.html: component that renders links from a data collection
    const nav_tmpl =
        \\<nav x-attr:class="class"><ul>
        \\<x-for link in data.nav><li><a x-var:href="link.url"><x-var name="link.label" /></a></li></x-for>
        \\</ul></nav>
    ;

    // content page: extends page.html, fills title and main
    const content_page =
        \\<x-extend template="page.html">
        \\<x-define slot="title"><x-var name="page.title" /></x-define>
        \\<x-define slot="head"><link rel="stylesheet" href="/css/default.css" /></x-define>
        \\<x-define slot="main">
        \\<h1><x-var name="page.title" /></h1>
        \\<x-if var="page.subtitle"><p class="subtitle"><x-var name="page.subtitle" /></p></x-if>
        \\<x-for post in pages.posts><article><h2><a x-var:href="post.x-path"><x-var name="post.title" /></a></h2></article></x-for>
        \\</x-define>
    ;

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "base.html", base_tmpl);
    try resolver.put(a, "page.html", page_tmpl);
    try resolver.put(a, "nav.html", nav_tmpl);

    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "site.author", "QuiteClose");
    try ctx.putVar(a, "page.title", "Welcome");

    // nav data
    var nav_entries: [2]Entry = .{ .{}, .{} };
    try nav_entries[0].values.put(a, "label", "Home");
    try nav_entries[0].values.put(a, "url", "/");
    try nav_entries[1].values.put(a, "label", "About");
    try nav_entries[1].values.put(a, "url", "/about/");
    defer for (&nav_entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "data.nav", nav_entries[0..]);

    // posts collection
    var post_entries: [2]Entry = .{ .{}, .{} };
    try post_entries[0].values.put(a, "title", "First Post");
    try post_entries[0].values.put(a, "x-path", "/posts/first/");
    try post_entries[1].values.put(a, "title", "Second Post");
    try post_entries[1].values.put(a, "x-path", "/posts/second/");
    defer for (&post_entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "pages.posts", post_entries[0..]);

    const result = try render(a, content_page, &ctx, &resolver);
    defer a.free(result);

    const expected = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\" />\n<title>Welcome</title>\n<link rel=\"stylesheet\" href=\"/css/default.css\" />\n</head>\n<body>\n\n<nav class=\"site-nav\"><ul>\n<li><a href=\"/\">Home</a></li><li><a href=\"/about/\">About</a></li>\n</ul></nav>\n<main>\n<h1>Welcome</h1>\n\n<article><h2><a href=\"/posts/first/\">First Post</a></h2></article><article><h2><a href=\"/posts/second/\">Second Post</a></h2></article>\n</main>\n<footer>&copy; QuiteClose</footer>\n\n</body>\n</html>";

    try testing.expectEqualStrings(expected, result);
}
