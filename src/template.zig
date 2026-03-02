const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Entry = struct {
    values: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    pub fn get(self: *const Entry, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

pub const ErrorDetail = struct {
    line: usize = 0,
    column: usize = 0,
    source_file: []const u8 = "",
    message: []const u8 = "",
};

pub const Context = struct {
    vars: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    collections: std.StringArrayHashMapUnmanaged([]const Entry) = .{},
    dev_mode: bool = false,
    err_detail: ?*ErrorDetail = null,

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
    UndefinedVariable,
    OutOfMemory,
};

const max_depth = 50;

pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    var owned_vars: @TypeOf(ctx.vars) = .{};
    defer owned_vars.deinit(a);
    var vit = ctx.vars.iterator();
    while (vit.next()) |kv| {
        try owned_vars.put(a, kv.key_ptr.*, kv.value_ptr.*);
    }
    var mutable_ctx: Context = .{
        .vars = owned_vars,
        .attrs = ctx.attrs,
        .slots = ctx.slots,
        .collections = ctx.collections,
        .dev_mode = ctx.dev_mode,
        .err_detail = ctx.err_detail,
    };
    const result = try renderTemplate(a, input, &mutable_ctx, resolver);
    owned_vars = mutable_ctx.vars;
    return result;
}

fn renderTemplate(a: Allocator, input: []const u8, ctx: *Context, resolver: *const Resolver) RenderError![]const u8 {
    const start = skipWhitespace(input);
    if (!std.mem.startsWith(u8, input[start..], "<x-extend ") and
        !std.mem.startsWith(u8, input[start..], "<x-extend>"))
    {
        return renderContent(a, input, ctx, resolver, 0);
    }

    var current = input;
    var slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer slots.deinit(a);

    var allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (allocs.items) |s| a.free(s);
        allocs.deinit(a);
    }

    var sit = ctx.slots.iterator();
    while (sit.next()) |entry| {
        try slots.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }

    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    defer visited.deinit(a);

    while (true) {
        const ws = skipWhitespace(current);
        if (!std.mem.startsWith(u8, current[ws..], "<x-extend ") and
            !std.mem.startsWith(u8, current[ws..], "<x-extend>")) break;

        const rest = current[ws..];
        const tag_end = findTagEnd(rest) orelse {
            setErrorDetail(ctx, current, ws, "unclosed x-extend tag");
            return error.MalformedElement;
        };
        const parent_name = extractAttrValue(rest[0 .. tag_end + 1], "template") orelse {
            setErrorDetail(ctx, current, ws, "missing 'template' attribute on x-extend");
            return error.MalformedElement;
        };

        if (visited.contains(parent_name)) {
            setErrorDetail(ctx, current, ws, parent_name);
            return error.CircularReference;
        }
        try visited.put(a, parent_name, {});

        try parseDefines(a, rest[tag_end + 1 ..], &slots, &allocs);

        current = resolver.get(parent_name) orelse {
            setErrorDetail(ctx, current, ws, parent_name);
            return error.TemplateNotFound;
        };
    }

    var render_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = ctx.attrs,
        .slots = slots,
        .collections = ctx.collections,
        .dev_mode = ctx.dev_mode,
        .err_detail = ctx.err_detail,
    };

    return renderContent(a, current, &render_ctx, resolver, 0);
}

fn renderContent(a: Allocator, input: []const u8, ctx: *Context, resolver: *const Resolver, depth: usize) RenderError![]const u8 {
    if (depth > max_depth) return error.CircularReference;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var let_allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (let_allocs.items) |s| a.free(s);
        let_allocs.deinit(a);
    }

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "<x-var ") or
            std.mem.startsWith(u8, input[i..], "<x-var/>") or
            std.mem.startsWith(u8, input[i..], "<x-var>"))
        {
            i = try renderVarOrRaw(a, input, i, ctx, resolver, depth, &out, true);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-raw ") or
            std.mem.startsWith(u8, input[i..], "<x-raw/>") or
            std.mem.startsWith(u8, input[i..], "<x-raw>"))
        {
            i = try renderVarOrRaw(a, input, i, ctx, resolver, depth, &out, false);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-let ") or
            std.mem.startsWith(u8, input[i..], "<x-let>"))
        {
            const rest = input[i..];
            const tag_end = findTagEnd(rest) orelse {
                setErrorDetail(ctx, input, i, "unclosed x-let tag");
                return error.MalformedElement;
            };
            const tag = rest[0 .. tag_end + 1];
            const let_name = extractAttrValue(tag, "name") orelse {
                setErrorDetail(ctx, input, i, "missing 'name' attribute on x-let");
                return error.MalformedElement;
            };
            const transform_spec = extractAttrValue(tag, "transform");

            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], "</x-let>") orelse {
                setErrorDetail(ctx, input, i, "unclosed x-let element");
                return error.MalformedElement;
            };
            const body = rest[content_start .. content_start + close];

            const rendered = try renderContent(a, body, ctx, resolver, depth);

            if (transform_spec) |ts| {
                const transformed = try applyTransforms(a, rendered, ts);
                a.free(rendered);
                try let_allocs.append(a, transformed);
                try ctx.putVar(a, let_name, transformed);
            } else {
                try let_allocs.append(a, rendered);
                try ctx.putVar(a, let_name, rendered);
            }

            i += content_start + close + "</x-let>".len;
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-comment")) {
            const rest = input[i..];
            const tag_end = findTagEnd(rest) orelse {
                setErrorDetail(ctx, input, i, "unclosed x-comment tag");
                return error.MalformedElement;
            };
            const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
            if (is_self_closing) {
                i += tag_end + 1;
            } else {
                const close = std.mem.indexOf(u8, rest[tag_end + 1 ..], "</x-comment>") orelse {
                    setErrorDetail(ctx, input, i, "unclosed x-comment element");
                    return error.MalformedElement;
                };
                i += tag_end + 1 + close + "</x-comment>".len;
            }
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<x-attr ") or
            std.mem.startsWith(u8, input[i..], "<x-attr/>"))
        {
            const rest = input[i..];
            const end_offset = std.mem.indexOf(u8, rest, "/>") orelse {
                setErrorDetail(ctx, input, i, "unclosed x-attr tag");
                return error.MalformedElement;
            };
            const tag = rest[0 .. end_offset + 2];
            const name = extractAttrValue(tag, "name") orelse {
                setErrorDetail(ctx, input, i, "missing 'name' attribute on x-attr");
                return error.MalformedElement;
            };
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

        if (std.mem.startsWith(u8, input[i..], "<x-else") or
            std.mem.startsWith(u8, input[i..], "<x-elif "))
        {
            return error.MalformedElement;
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

fn renderSlot(a: Allocator, input: []const u8, start: usize, ctx: *Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse {
        setErrorDetail(ctx, input, start, "unclosed x-slot tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';

    const indent = try a.dupe(u8, detectIndent(out.items));
    defer a.free(indent);

    if (is_self_closing) {
        const tag = rest[0 .. tag_end + 1];
        const name = extractAttrValue(tag, "name") orelse "";
        if (ctx.getSlot(name)) |content| {
            const rendered = try renderContent(a, content, ctx, resolver, depth);
            defer a.free(rendered);
            try appendIndented(a, out, rendered, indent);
        }
        return start + tag_end + 1;
    }

    const tag = rest[0 .. tag_end + 1];
    const name = extractAttrValue(tag, "name") orelse "";
    const content_start = tag_end + 1;
    const close_tag = std.mem.indexOf(u8, rest[content_start..], "</x-slot>") orelse {
        setErrorDetail(ctx, input, start, "unclosed x-slot element");
        return error.MalformedElement;
    };
    const default_content = rest[content_start .. content_start + close_tag];
    const total_end = content_start + close_tag + "</x-slot>".len;

    if (ctx.getSlot(name)) |content| {
        const rendered = try renderContent(a, content, ctx, resolver, depth);
        defer a.free(rendered);
        try appendIndented(a, out, rendered, indent);
    } else {
        const rendered = try renderContent(a, default_content, ctx, resolver, depth);
        defer a.free(rendered);
        try appendIndented(a, out, rendered, indent);
    }
    return start + total_end;
}

fn renderVarOrRaw(a: Allocator, input: []const u8, start: usize, ctx: *Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8), escape: bool) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse {
        setErrorDetail(ctx, input, start, "unclosed tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const close_tag: []const u8 = if (escape) "</x-var>" else "</x-raw>";

    const name = extractAttrValue(tag, "name") orelse {
        setErrorDetail(ctx, input, start, "missing 'name' attribute on x-var/x-raw");
        return error.MalformedElement;
    };
    const transform_spec = extractAttrValue(tag, "transform");

    var consumed: usize = tag_end + 1;
    var default_body: ?[]const u8 = null;

    if (!is_self_closing) {
        const content_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[content_start..], close_tag) orelse {
            setErrorDetail(ctx, input, start, "unclosed x-var/x-raw element");
            return error.MalformedElement;
        };
        default_body = rest[content_start .. content_start + close];
        consumed = content_start + close + close_tag.len;
    }

    var value: []const u8 = "";
    var value_allocated = false;

    if (ctx.getVar(name)) |v| {
        value = v;
    } else if (default_body) |body| {
        value = try renderContent(a, body, ctx, resolver, depth);
        value_allocated = true;
    } else if (transform_spec != null and hasDefaultTransform(transform_spec.?)) {
        // default transform will handle the empty value
    } else {
        setErrorDetail(ctx, input, start, name);
        return error.UndefinedVariable;
    }
    defer if (value_allocated) a.free(value);

    if (transform_spec) |ts| {
        const transformed = try applyTransforms(a, value, ts);
        defer a.free(transformed);
        if (escape) {
            try appendEscaped(a, out, transformed);
        } else {
            try out.appendSlice(a, transformed);
        }
    } else if (value_allocated) {
        try out.appendSlice(a, value);
    } else if (escape) {
        try appendEscaped(a, out, value);
    } else {
        try out.appendSlice(a, value);
    }

    return start + consumed;
}

fn appendIndented(a: Allocator, out: *std.ArrayList(u8), content: []const u8, indent: []const u8) RenderError!void {
    if (content.len == 0) {
        while (out.items.len > 0 and
            (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t'))
        {
            _ = out.pop();
        }
        return;
    }
    if (indent.len == 0) {
        try out.appendSlice(a, content);
        return;
    }
    var first = true;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = content[line_start..i];
            if (first) {
                try out.appendSlice(a, line);
                first = false;
            } else {
                try out.append(a, '\n');
                if (line.len > 0) {
                    try out.appendSlice(a, indent);
                    try out.appendSlice(a, line);
                }
            }
            line_start = i + 1;
        }
    }
}

fn renderInclude(a: Allocator, input: []const u8, start: usize, ctx: *Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse {
        setErrorDetail(ctx, input, start, "unclosed x-include tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = extractAttrValue(tag, "template") orelse {
        setErrorDetail(ctx, input, start, "missing 'template' attribute on x-include");
        return error.MalformedElement;
    };

    var inc_attrs = try parseTagAttrs(a, tag);
    defer inc_attrs.deinit(a);

    var body: []const u8 = "";
    var body_allocated = false;
    var consumed: usize = tag_end + 1;

    if (!is_self_closing) {
        const content_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[content_start..], "</x-include>") orelse {
            setErrorDetail(ctx, input, start, "unclosed x-include element");
            return error.MalformedElement;
        };
        const raw_body = rest[content_start .. content_start + close];
        const strip_result = try stripCommonIndent(a, raw_body);
        body = strip_result.slice;
        body_allocated = strip_result.allocated;
        consumed = content_start + close + "</x-include>".len;
    }
    defer if (body_allocated) a.free(body);

    const tmpl_content = resolver.get(tmpl_name) orelse {
        setErrorDetail(ctx, input, start, tmpl_name);
        return error.TemplateNotFound;
    };

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer child_slots.deinit(a);
    var slot_allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (slot_allocs.items) |s| a.free(s);
        slot_allocs.deinit(a);
    }

    if (body.len > 0) {
        if (std.mem.indexOf(u8, body, "<x-define") != null) {
            try parseIncludeBody(a, body, &child_slots, &slot_allocs);
        } else {
            try child_slots.put(a, "", body);
        }
    }

    var child_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = inc_attrs,
        .slots = child_slots,
        .collections = ctx.collections,
        .dev_mode = ctx.dev_mode,
        .err_detail = ctx.err_detail,
    };

    const indent = try a.dupe(u8, detectIndent(out.items));
    defer a.free(indent);
    const rendered = try renderContent(a, tmpl_content, &child_ctx, resolver, depth + 1);
    defer a.free(rendered);
    try appendIndented(a, out, rendered, indent);

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

fn renderConditional(a: Allocator, input: []const u8, start: usize, ctx: *Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse {
        setErrorDetail(ctx, input, start, "unclosed x-if tag");
        return error.MalformedElement;
    };
    const if_tag = rest[0 .. tag_end + 1];
    const body_start = tag_end + 1;

    const if_close = findMatchingClose(rest[body_start..], "<x-if", "</x-if>") orelse {
        setErrorDetail(ctx, input, start, "unclosed x-if element");
        return error.MalformedElement;
    };
    const full_body = rest[body_start .. body_start + if_close];
    const total_end = start + body_start + if_close + "</x-if>".len;

    var matched = false;

    const first_sep = findConditionalSeparator(full_body, 0);
    const if_body = if (first_sep) |sep| full_body[0..sep.pos] else full_body;

    if (evaluateCondition(if_tag, ctx)) {
        const rendered = try renderContent(a, if_body, ctx, resolver, depth);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
        matched = true;
    }

    if (first_sep) |first| {
        var cursor = first;
        while (true) {
            if (cursor.is_else) {
                const else_body = full_body[cursor.pos + cursor.tag_len ..];
                if (!matched) {
                    const rendered = try renderContent(a, else_body, ctx, resolver, depth);
                    defer a.free(rendered);
                    try out.appendSlice(a, rendered);
                }
                break;
            }
            const elif_tag = full_body[cursor.pos .. cursor.pos + cursor.tag_len];
            const next_start = cursor.pos + cursor.tag_len;
            const next_sep = findConditionalSeparator(full_body, next_start);
            const elif_body = if (next_sep) |ns| full_body[next_start..ns.pos] else full_body[next_start..];

            if (!matched and evaluateCondition(elif_tag, ctx)) {
                const rendered = try renderContent(a, elif_body, ctx, resolver, depth);
                defer a.free(rendered);
                try out.appendSlice(a, rendered);
                matched = true;
            }

            if (next_sep) |ns| {
                cursor = ns;
            } else break;
        }
    }

    return total_end;
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

fn detectIndent(output: []const u8) []const u8 {
    if (output.len == 0) return "";
    var i = output.len;
    while (i > 0) {
        i -= 1;
        if (output[i] == '\n') {
            const after = output[i + 1 ..];
            var ws: usize = 0;
            while (ws < after.len and (after[ws] == ' ' or after[ws] == '\t')) : (ws += 1) {}
            if (ws == after.len) return after;
            return "";
        }
    }
    return "";
}

const IndentResult = struct {
    slice: []const u8,
    allocated: bool,
};

fn stripCommonIndent(a: Allocator, content: []const u8) RenderError!IndentResult {
    if (content.len == 0) return .{ .slice = "", .allocated = false };

    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(a);
    var line_start: usize = 0;
    var j: usize = 0;
    while (j <= content.len) : (j += 1) {
        if (j == content.len or content[j] == '\n') {
            try lines.append(a, content[line_start..j]);
            line_start = j + 1;
        }
    }

    var first_content: usize = 0;
    while (first_content < lines.items.len) : (first_content += 1) {
        if (isContentLine(lines.items[first_content])) break;
    }
    var last_content: usize = lines.items.len;
    while (last_content > first_content) {
        last_content -= 1;
        if (isContentLine(lines.items[last_content])) {
            last_content += 1;
            break;
        }
    }
    if (first_content >= last_content) return .{ .slice = "", .allocated = false };

    const content_lines = lines.items[first_content..last_content];

    var min_indent: ?usize = null;
    for (content_lines) |line| {
        if (!isContentLine(line)) continue;
        var ws: usize = 0;
        while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
        if (min_indent == null or ws < min_indent.?) min_indent = ws;
    }

    const strip = min_indent orelse 0;

    if (strip == 0 and content_lines.len == 1) {
        return .{ .slice = content_lines[0], .allocated = false };
    }
    if (strip == 0) {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(a);
        for (content_lines, 0..) |line, idx| {
            if (idx > 0) try out.append(a, '\n');
            try out.appendSlice(a, line);
        }
        return .{ .slice = try out.toOwnedSlice(a), .allocated = true };
    }

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);
    for (content_lines, 0..) |line, idx| {
        if (idx > 0) try out.append(a, '\n');
        if (isContentLine(line)) {
            if (line.len > strip) {
                try out.appendSlice(a, line[strip..]);
            }
        }
    }

    return .{ .slice = try out.toOwnedSlice(a), .allocated = true };
}

fn isContentLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return true;
    }
    return false;
}

fn reindent(a: Allocator, content: []const u8, indent: []const u8) RenderError![]const u8 {
    if (content.len == 0 or indent.len == 0) return try a.dupe(u8, content);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = content[line_start..i];
            if (line_start > 0) try out.append(a, '\n');
            if (line.len > 0) {
                try out.appendSlice(a, indent);
                try out.appendSlice(a, line);
            }
            line_start = i + 1;
        }
    }

    return out.toOwnedSlice(a);
}

fn renderFor(a: Allocator, input: []const u8, start: usize, ctx: *Context, resolver: *const Resolver, depth: usize, out: *std.ArrayList(u8)) RenderError!usize {
    const rest = input[start..];
    const tag_end = findTagEnd(rest) orelse {
        setErrorDetail(ctx, input, start, "unclosed x-for tag");
        return error.MalformedElement;
    };
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

    const loop_alias: ?[]const u8 = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse break :blk null;
        const as_tok = std.mem.indexOfPos(u8, tag, in_tok + 4, " as ") orelse break :blk null;
        const after_as = as_tok + 4;
        var alias_end = after_as;
        while (alias_end < tag.len and tag[alias_end] != ' ' and
            tag[alias_end] != '>' and tag[alias_end] != '/') : (alias_end += 1)
        {}
        if (alias_end > after_as) break :blk tag[after_as..alias_end];
        break :blk null;
    };

    const sort_field = extractAttrValue(tag, "sort");
    const order_desc = if (extractAttrValue(tag, "order")) |o|
        std.mem.eql(u8, o, "desc")
    else
        false;

    const limit_val = if (extractAttrValue(tag, "limit")) |v|
        std.fmt.parseInt(usize, v, 10) catch return error.MalformedElement
    else
        null;
    const offset_val = if (extractAttrValue(tag, "offset")) |v|
        std.fmt.parseInt(usize, v, 10) catch return error.MalformedElement
    else
        null;

    const body_start = start + tag_end + 1;
    const close_offset = findMatchingClose(input[body_start..], "<x-for ", "</x-for>") orelse {
        setErrorDetail(ctx, input, start, "unclosed x-for element");
        return error.MalformedElement;
    };
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

    const off = if (offset_val) |o| @min(o, items.len) else 0;
    const sliced = items[off..];
    const final = if (limit_val) |l| sliced[0..@min(l, sliced.len)] else sliced;

    for (final, 0..) |entry, idx| {
        var child_ctx: Context = .{
            .attrs = ctx.attrs,
            .slots = ctx.slots,
            .collections = ctx.collections,
            .dev_mode = ctx.dev_mode,
            .err_detail = ctx.err_detail,
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

        if (loop_alias) |alias| {
            const idx_key = try std.fmt.allocPrint(a, "{s}.index", .{alias});
            try allocated_keys.append(a, idx_key);
            const idx_str = try std.fmt.allocPrint(a, "{d}", .{idx});
            try allocated_keys.append(a, idx_str);
            try child_vars.put(a, idx_key, idx_str);

            const num_key = try std.fmt.allocPrint(a, "{s}.number", .{alias});
            try allocated_keys.append(a, num_key);
            const num_str = try std.fmt.allocPrint(a, "{d}", .{idx + 1});
            try allocated_keys.append(a, num_str);
            try child_vars.put(a, num_key, num_str);
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

const Separator = struct { pos: usize, tag_len: usize, is_else: bool };

fn findConditionalSeparator(body: []const u8, from: usize) ?Separator {
    var depth: usize = 0;
    var i = from;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "<x-if")) {
            depth += 1;
            i += "<x-if".len;
        } else if (std.mem.startsWith(u8, body[i..], "</x-if>")) {
            if (depth == 0) return null;
            depth -= 1;
            i += "</x-if>".len;
        } else if (depth == 0 and std.mem.startsWith(u8, body[i..], "<x-elif ")) {
            const tag_end = findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = false };
        } else if (depth == 0 and std.mem.startsWith(u8, body[i..], "<x-else")) {
            const tag_end = findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = true };
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

fn computeLineCol(input: []const u8, pos: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const limit = @min(pos, input.len);
    for (input[0..limit]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

fn setErrorDetail(ctx: *Context, input: []const u8, pos: usize, message: []const u8) void {
    if (ctx.err_detail) |ed| {
        const lc = computeLineCol(input, pos);
        ed.line = lc.line;
        ed.column = lc.column;
        ed.message = message;
    }
}

fn parseDefines(a: Allocator, input: []const u8, slots: *std.StringArrayHashMapUnmanaged([]const u8), allocs: *std.ArrayList([]const u8)) RenderError!void {
    var i: usize = 0;
    while (i < input.len) {
        const ws = skipWhitespace(input[i..]);
        i += ws;
        if (i >= input.len) break;

        if (std.mem.startsWith(u8, input[i..], "<x-define ")) {
            const rest = input[i..];
            const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
            const slot_name = extractAttrValue(rest[0 .. tag_end + 1], "name") orelse
                extractAttrValue(rest[0 .. tag_end + 1], "slot") orelse
                return error.MalformedElement;
            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], "</x-define>") orelse
                return error.MalformedElement;
            const raw_content = rest[content_start .. content_start + close];
            const result = try stripCommonIndent(a, raw_content);
            if (result.allocated) {
                try allocs.append(a, result.slice);
            }
            try slots.put(a, slot_name, result.slice);
            i += content_start + close + "</x-define>".len;
        } else {
            i += 1;
        }
    }
}

fn parseIncludeBody(
    a: Allocator,
    body: []const u8,
    slots: *std.StringArrayHashMapUnmanaged([]const u8),
    allocs: *std.ArrayList([]const u8),
) RenderError!void {
    var anon_parts: std.ArrayList(u8) = .{};
    errdefer anon_parts.deinit(a);

    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "<x-define ") or
            std.mem.startsWith(u8, body[i..], "<x-define>"))
        {
            const rest = body[i..];
            const tag_end = findTagEnd(rest) orelse return error.MalformedElement;
            const tag = rest[0 .. tag_end + 1];
            const slot_name = extractAttrValue(tag, "name") orelse
                extractAttrValue(tag, "slot") orelse
                return error.MalformedElement;

            if (slots.contains(slot_name)) return error.DuplicateSlotDefinition;

            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], "</x-define>") orelse
                return error.MalformedElement;
            const raw_content = rest[content_start .. content_start + close];
            const result = try stripCommonIndent(a, raw_content);
            if (result.allocated) {
                try allocs.append(a, result.slice);
            }
            try slots.put(a, slot_name, result.slice);
            i += content_start + close + "</x-define>".len;
        } else {
            try anon_parts.append(a, body[i]);
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, anon_parts.items, " \t\r\n");
    if (trimmed.len > 0) {
        const anon_copy = try a.dupe(u8, trimmed);
        try allocs.append(a, anon_copy);
        try slots.put(a, "", anon_copy);
    }

    anon_parts.deinit(a);
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

fn hasDefaultTransform(transform_spec: []const u8) bool {
    var pipe_iter = std.mem.splitScalar(u8, transform_spec, '|');
    while (pipe_iter.next()) |t| {
        if (std.mem.startsWith(u8, t, "default:") or std.mem.eql(u8, t, "default")) {
            return true;
        }
    }
    return false;
}

fn applyTransforms(a: Allocator, value: []const u8, transform_spec: []const u8) RenderError![]u8 {
    var current = try a.dupe(u8, value);
    errdefer a.free(current);

    var pipe_iter = std.mem.splitScalar(u8, transform_spec, '|');
    while (pipe_iter.next()) |transform| {
        if (transform.len == 0) continue;

        var colon_iter = std.mem.splitScalar(u8, transform, ':');
        const name = colon_iter.next().?;

        const next = try applyOneTransform(a, current, name, &colon_iter);
        if (next.ptr != current.ptr) {
            a.free(current);
        }
        current = next;
    }

    return current;
}

fn applyOneTransform(a: Allocator, value: []const u8, name: []const u8, args: *std.mem.SplitIterator(u8, .scalar)) RenderError![]u8 {
    if (std.mem.eql(u8, name, "upper")) {
        const buf = try a.alloc(u8, value.len);
        for (buf, value) |*b, c| {
            b.* = std.ascii.toUpper(c);
        }
        return buf;
    }
    if (std.mem.eql(u8, name, "lower")) {
        const buf = try a.alloc(u8, value.len);
        for (buf, value) |*b, c| {
            b.* = std.ascii.toLower(c);
        }
        return buf;
    }
    if (std.mem.eql(u8, name, "capitalize")) {
        const buf = try a.alloc(u8, value.len);
        var prev_space = true;
        for (buf, value) |*b, c| {
            if (prev_space and std.ascii.isAlphabetic(c)) {
                b.* = std.ascii.toUpper(c);
            } else {
                b.* = c;
            }
            prev_space = c == ' ' or c == '\t' or c == '\n';
        }
        return buf;
    }
    if (std.mem.eql(u8, name, "trim")) {
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        return try a.dupe(u8, trimmed);
    }
    if (std.mem.eql(u8, name, "slugify")) {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(a);
        var prev_hyphen = true;
        for (value) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try out.append(a, std.ascii.toLower(c));
                prev_hyphen = false;
            } else if (!prev_hyphen) {
                try out.append(a, '-');
                prev_hyphen = true;
            }
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
            _ = out.pop();
        }
        return try out.toOwnedSlice(a);
    }
    if (std.mem.eql(u8, name, "truncate")) {
        const n_str = args.next() orelse return error.MalformedElement;
        const n = std.fmt.parseInt(usize, n_str, 10) catch return error.MalformedElement;
        if (value.len <= n) return try a.dupe(u8, value);
        const buf = try a.alloc(u8, n + 3);
        @memcpy(buf[0..n], value[0..n]);
        @memcpy(buf[n .. n + 3], "...");
        return buf;
    }
    if (std.mem.eql(u8, name, "replace")) {
        const old = args.next() orelse return error.MalformedElement;
        const new = args.next() orelse "";
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < value.len) {
            if (old.len > 0 and i + old.len <= value.len and
                std.mem.eql(u8, value[i .. i + old.len], old))
            {
                try out.appendSlice(a, new);
                i += old.len;
            } else {
                try out.append(a, value[i]);
                i += 1;
            }
        }
        return try out.toOwnedSlice(a);
    }
    if (std.mem.eql(u8, name, "default")) {
        const def = args.next() orelse "";
        if (value.len == 0) return try a.dupe(u8, def);
        return try a.dupe(u8, value);
    }
    return error.MalformedElement;
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

fn renderBoundTag(a: Allocator, tag: []const u8, ctx: *Context, out: *std.ArrayList(u8)) RenderError!void {
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

test "var_missing_is_error" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const result = render(a, "<p><x-var name=\"title\" /></p>", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
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

    const result = try render(a, "<x-if var=\"title\">YES<x-else />NO</x-if>", &ctx, &resolver);
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
        \\<x-if var="mode" equals="dev">DEV<x-elif var="mode" equals="staging" />STG<x-else />PROD</x-if>
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
    try resolver.put(a, "comp.html", "<x-if attr=\"variant\">STYLED<x-else />PLAIN</x-if>");

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
// Slot indentation tests
// ---------------------------------------------------------------------------

test "indent_single_line" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<body>\n  <main>\n    <x-slot />\n  </main>\n</body>";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"\">\n<h1>Hello</h1>\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<body>\n  <main>\n    <h1>Hello</h1>\n  </main>\n</body>", result);
}

test "indent_multi_line" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<body>\n  <main>\n    <x-slot />\n  </main>\n</body>";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"\">\n<h1>Title</h1>\n<p>Text</p>\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<body>\n  <main>\n    <h1>Title</h1>\n    <p>Text</p>\n  </main>\n</body>", result);
}

test "indent_nested_structure" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<body>\n  <main>\n    <x-slot />\n  </main>\n</body>";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"\">\n<div>\n  <h1>Title</h1>\n</div>\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<body>\n  <main>\n    <div>\n      <h1>Title</h1>\n    </div>\n  </main>\n</body>", result);
}

test "indent_include_body" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const component = "<section>\n  <x-slot />\n</section>";
    try resolver.put(a, "box.html", component);

    const input = "<main>\n  <x-include template=\"box.html\">\n    <h1>Title</h1>\n    <p>Text</p>\n  </x-include>\n</main>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, input, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<main>\n  <section>\n    <h1>Title</h1>\n    <p>Text</p>\n  </section>\n</main>", result);
}

test "indent_named_slots_different_levels" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<div>\n  <x-slot name=\"a\" />\n  <nav>\n    <x-slot name=\"b\" />\n  </nav>\n</div>";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"a\">\n<h1>Header</h1>\n</x-define>\n<x-define slot=\"b\">\n<ul>\n  <li>One</li>\n</ul>\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<div>\n  <h1>Header</h1>\n  <nav>\n    <ul>\n      <li>One</li>\n    </ul>\n  </nav>\n</div>", result);
}

test "indent_zero_level_slot" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<x-slot />";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"\">\n  <h1>Title</h1>\n  <p>Text</p>\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<h1>Title</h1>\n<p>Text</p>", result);
}

test "indent_empty_content" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);

    const tmpl = "<body>\n  <x-slot />\n</body>";
    try resolver.put(a, "layout.html", tmpl);

    const page = "<x-extend template=\"layout.html\">\n<x-define slot=\"\">\n</x-define>";
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, page, &ctx, &resolver);
    defer a.free(result);

    try testing.expectEqualStrings("<body>\n\n</body>", result);
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

    const expected = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\" />\n<title>Welcome</title>\n<link rel=\"stylesheet\" href=\"/css/default.css\" />\n</head>\n<body>\n<nav class=\"site-nav\"><ul>\n<li><a href=\"/\">Home</a></li><li><a href=\"/about/\">About</a></li>\n</ul></nav>\n<main><h1>Welcome</h1>\n\n<article><h2><a href=\"/posts/first/\">First Post</a></h2></article><article><h2><a href=\"/posts/second/\">Second Post</a></h2></article></main>\n<footer>&copy; QuiteClose</footer>\n</body>\n</html>";

    try testing.expectEqualStrings(expected, result);
}

// ---------------------------------------------------------------------------
// x-raw tests
// ---------------------------------------------------------------------------

test "raw_basic" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello");
    const result = try render(a, "<x-raw name=\"v\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "raw_html_not_escaped" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "<strong>bold &amp; stuff</strong>");
    const result = try render(a, "<x-raw name=\"v\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<strong>bold &amp; stuff</strong>", result);
}

test "raw_missing_is_error" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    const result = render(a, "before<x-raw name=\"missing\" />after", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
}

test "raw_in_for_loop" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "html", "<em>one</em>");
    try entries[1].values.put(a, "html", "<em>two</em>");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a, "<x-for item in items><x-raw name=\"item.html\" /></x-for>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<em>one</em><em>two</em>", result);
}

// --- Nesting tests ---

test "nested_if_both_true" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "a", "yes");
    try ctx.putVar(a, "b", "yes");

    const result = try render(a,
        \\<x-if var="a">OUTER-<x-if var="b">INNER</x-if></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("OUTER-INNER", result);
}

test "nested_if_inner_false_with_else" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "a", "yes");

    const result = try render(a,
        \\<x-if var="a"><x-if var="b">B<x-else />NOT-B</x-if></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("NOT-B", result);
}

test "nested_if_outer_false" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "b", "yes");

    const result = try render(a,
        \\<x-if var="a"><x-if var="b">INNER</x-if><x-else />NOT-A</x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("NOT-A", result);
}

test "nested_if_with_elif" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "a", "yes");
    try ctx.putVar(a, "c", "yes");

    const result = try render(a,
        \\<x-if var="a"><x-if var="b">B<x-elif var="c" />C<x-else />D</x-if></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("C", result);
}

test "nested_elif_with_inner_chain" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "b", "yes");
    try ctx.putVar(a, "d", "yes");

    const result = try render(a,
        \\<x-if var="a">A<x-elif var="b" /><x-if var="c">C<x-elif var="d" />D</x-if></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("D", result);
}

test "nested_else_with_inner_chain" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "c", "yes");

    const result = try render(a,
        \\<x-if var="a">A<x-else /><x-if var="b">B<x-else />FALLBACK</x-if></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("FALLBACK", result);
}

test "nested_for_loops" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var groups: [2]Entry = .{ .{}, .{} };
    try groups[0].values.put(a, "name", "G1");
    try groups[1].values.put(a, "name", "G2");
    defer for (&groups) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "groups", groups[0..]);

    var items: [2]Entry = .{ .{}, .{} };
    try items[0].values.put(a, "val", "x");
    try items[1].values.put(a, "val", "y");
    defer for (&items) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", items[0..]);

    const result = try render(a,
        \\<x-for g in groups>[<x-var name="g.name" />:<x-for i in items><x-var name="i.val" /></x-for>]</x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("[G1:xy][G2:xy]", result);
}

test "nested_if_in_for" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [3]Entry = .{ .{}, .{}, .{} };
    try entries[0].values.put(a, "name", "Alice");
    try entries[0].values.put(a, "active", "true");
    try entries[1].values.put(a, "name", "Bob");
    try entries[2].values.put(a, "name", "Carol");
    try entries[2].values.put(a, "active", "true");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "people", entries[0..]);

    const result = try render(a,
        \\<x-for p in people><x-if var="p.active" equals="true"><x-var name="p.name" /><x-else />-</x-if></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Alice-Carol", result);
}

test "complex_nesting_if_for_if" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "show", "yes");

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "name", "one");
    try entries[0].values.put(a, "highlight", "true");
    try entries[1].values.put(a, "name", "two");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-if var="show"><x-for item in items><x-if var="item.highlight" equals="true">[<x-var name="item.name" />]<x-else /><x-var name="item.name" /></x-if></x-for></x-if>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("[one]two", result);
}

// ---------------------------------------------------------------------------
// Malformed template / error tests
// ---------------------------------------------------------------------------

test "error_extend_missing_template" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-extend template=\"nonexistent.html\"><x-define slot=\"content\">body</x-define></x-extend>", &ctx, &resolver);
    try testing.expectError(error.TemplateNotFound, result);
}

test "error_include_missing_template" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-include template=\"nonexistent.html\" />", &ctx, &resolver);
    try testing.expectError(error.TemplateNotFound, result);
}

test "error_orphan_else" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-else />content", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_orphan_elif" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-elif var=\"x\" />content", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_unclosed_if" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-if var=\"x\">body", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_unclosed_for" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-for item in items>body", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_unclosed_slot" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-slot name=\"s\">default", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_var_no_name" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-var />", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_raw_no_name" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-raw />", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_for_no_in" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-for item>body</x-for>", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "unfilled_slot_renders_default" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "parent.html", "<div><x-slot name=\"content\">fallback</x-slot></div>");

    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-extend template=\"parent.html\"></x-extend>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<div>fallback</div>", result);
}

test "unfilled_slot_self_closing_empty" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "parent.html", "<div><x-slot name=\"content\" /></div>");

    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-extend template=\"parent.html\"></x-extend>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<div></div>", result);
}

test "error_extend_no_template_attr" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-extend><x-define slot=\"content\">body</x-define></x-extend>", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_include_no_template_attr" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-include />", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// x-comment tests
// ---------------------------------------------------------------------------

test "comment_block_stripped" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-comment>this should not appear</x-comment>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "comment_self_closing_stripped" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-comment />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "comment_nested_elements_not_rendered" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "title", "Hello");

    const result = try render(a, "<x-comment><x-var name=\"title\" />should not appear</x-comment>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "comment_surrounding_content_preserved" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "before<x-comment>hidden</x-comment>after", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("beforeafter", result);
}

test "error_unclosed_comment" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-comment>no closing tag", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// x-var / x-raw default value + strict mode tests
// ---------------------------------------------------------------------------

test "var_default_used_when_missing" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-var name=\"page.author\">Anonymous</x-var>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Anonymous", result);
}

test "var_default_not_used_when_exists" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "page.author", "QuiteClose");

    const result = try render(a, "<x-var name=\"page.author\">Anonymous</x-var>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("QuiteClose", result);
}

test "raw_default_used_when_missing" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-raw name=\"content\"><p>No content</p></x-raw>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<p>No content</p>", result);
}

test "raw_default_not_used_when_exists" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "content", "<p>Real content</p>");

    const result = try render(a, "<x-raw name=\"content\"><p>No content</p></x-raw>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<p>Real content</p>", result);
}

test "var_default_with_nested_elements" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "fallback_name", "World");

    const result = try render(a, "<x-var name=\"greeting\">Hello <x-var name=\"fallback_name\" /></x-var>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello World", result);
}

test "var_empty_default_no_error" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "before<x-var name=\"x\"></x-var>after", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("beforeafter", result);
}

test "var_default_value_is_not_escaped" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-var name=\"x\"><em>bold</em></x-var>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<em>bold</em>", result);
}

test "var_existing_value_is_escaped" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "x", "<em>bold</em>");

    const result = try render(a, "<x-var name=\"x\">default</x-var>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("&lt;em&gt;bold&lt;/em&gt;", result);
}

test "strict_var_exists_no_error" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "title", "Home");

    const result = try render(a, "<x-var name=\"title\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Home", result);
}

test "strict_raw_missing_is_error" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-raw name=\"missing\" />", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
}

test "attr_binding_optional_on_missing" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<a x-var:href=\"url\">link</a>", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("<a>link</a>", result);
}

test "error_unclosed_var_block" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-var name=\"x\">no close", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_unclosed_raw_block" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-raw name=\"x\">no close", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_var_block_no_name" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-var>fallback</x-var>", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// x-for loop alias (as keyword) + index/number + limit/offset tests
// ---------------------------------------------------------------------------

test "for_as_index_and_number" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [3]Entry = .{ .{}, .{}, .{} };
    try entries[0].values.put(a, "name", "A");
    try entries[1].values.put(a, "name", "B");
    try entries[2].values.put(a, "name", "C");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items as loop><x-var name="loop.index" />:<x-var name="loop.number" />:<x-var name="item.name" />,</x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("0:1:A,1:2:B,2:3:C,", result);
}

test "for_as_coexists_with_item_prefix" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "label", "X");
    try entries[1].values.put(a, "label", "Y");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "things", entries[0..]);

    const result = try render(a,
        \\<x-for thing in things as i>#<x-var name="i.number" />:<x-var name="thing.label" /> </x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("#1:X #2:Y ", result);
}

test "for_without_as_backward_compatible" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "v", "a");
    try entries[1].values.put(a, "v", "b");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("ab", result);
}

test "for_nested_loops_independent_aliases" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var rows: [2]Entry = .{ .{}, .{} };
    try rows[0].values.put(a, "name", "R");
    try rows[1].values.put(a, "name", "S");
    defer for (&rows) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "rows", rows[0..]);

    var cols: [2]Entry = .{ .{}, .{} };
    try cols[0].values.put(a, "name", "X");
    try cols[1].values.put(a, "name", "Y");
    defer for (&cols) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "cols", cols[0..]);

    const result = try render(a,
        \\<x-for row in rows as outer><x-for col in cols as inner><x-var name="outer.number" />.<x-var name="inner.number" /> </x-for></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("1.1 1.2 2.1 2.2 ", result);
}

test "for_limit_only" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [5]Entry = .{ .{}, .{}, .{}, .{}, .{} };
    try entries[0].values.put(a, "v", "1");
    try entries[1].values.put(a, "v", "2");
    try entries[2].values.put(a, "v", "3");
    try entries[3].values.put(a, "v", "4");
    try entries[4].values.put(a, "v", "5");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items limit="2"><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("12", result);
}

test "for_offset_only" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [5]Entry = .{ .{}, .{}, .{}, .{}, .{} };
    try entries[0].values.put(a, "v", "1");
    try entries[1].values.put(a, "v", "2");
    try entries[2].values.put(a, "v", "3");
    try entries[3].values.put(a, "v", "4");
    try entries[4].values.put(a, "v", "5");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items offset="2"><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("345", result);
}

test "for_limit_and_offset" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [5]Entry = .{ .{}, .{}, .{}, .{}, .{} };
    try entries[0].values.put(a, "v", "1");
    try entries[1].values.put(a, "v", "2");
    try entries[2].values.put(a, "v", "3");
    try entries[3].values.put(a, "v", "4");
    try entries[4].values.put(a, "v", "5");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items limit="2" offset="1"><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("23", result);
}

test "for_offset_beyond_items" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "v", "1");
    try entries[1].values.put(a, "v", "2");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items offset="10"><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "for_limit_zero" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "v", "1");
    try entries[1].values.put(a, "v", "2");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items limit="0"><x-var name="item.v" /></x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "for_all_attrs_combined" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [5]Entry = .{ .{}, .{}, .{}, .{}, .{} };
    try entries[0].values.put(a, "name", "E");
    try entries[1].values.put(a, "name", "A");
    try entries[2].values.put(a, "name", "D");
    try entries[3].values.put(a, "name", "B");
    try entries[4].values.put(a, "name", "C");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "items", entries[0..]);

    const result = try render(a,
        \\<x-for item in items as loop sort="name" limit="3" offset="1"><x-var name="loop.number" />:<x-var name="item.name" /> </x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("1:B 2:C 3:D ", result);
}

test "error_for_limit_non_numeric" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a,
        \\<x-for item in items limit="abc">body</x-for>
    , &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// Transform tests
// ---------------------------------------------------------------------------

test "transform_upper" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello");

    const result = try render(a, "<x-var name=\"v\" transform=\"upper\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("HELLO", result);
}

test "transform_lower" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "HELLO");

    const result = try render(a, "<x-var name=\"v\" transform=\"lower\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "transform_capitalize" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello world");

    const result = try render(a, "<x-var name=\"v\" transform=\"capitalize\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello World", result);
}

test "transform_slugify" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "Hello World!");

    const result = try render(a, "<x-var name=\"v\" transform=\"slugify\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello-world", result);
}

test "transform_truncate" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "Hello World");

    const result = try render(a, "<x-var name=\"v\" transform=\"truncate:5\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello...", result);
}

test "transform_truncate_short_unchanged" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "Hi");

    const result = try render(a, "<x-var name=\"v\" transform=\"truncate:5\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hi", result);
}

test "transform_replace" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "a-b-c");

    const result = try render(a, "<x-var name=\"v\" transform=\"replace:-: \" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("a b c", result);
}

test "transform_default_on_missing" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-var name=\"missing\" transform=\"default:Anonymous\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Anonymous", result);
}

test "transform_trim" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "  hello  ");

    const result = try render(a, "<x-var name=\"v\" transform=\"trim\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "transform_chain_replace_capitalize" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello-world");

    const result = try render(a, "<x-var name=\"v\" transform=\"replace:-: |capitalize\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello World", result);
}

test "transform_chain_three" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "  Hello World  ");

    const result = try render(a, "<x-var name=\"v\" transform=\"trim|lower|slugify\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello-world", result);
}

test "transform_on_raw" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello");

    const result = try render(a, "<x-raw name=\"v\" transform=\"upper\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("HELLO", result);
}

test "transform_on_var_escapes_after" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "a&b");

    const result = try render(a, "<x-var name=\"v\" transform=\"upper\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("A&amp;B", result);
}

test "transform_empty_value" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "");

    const result = try render(a, "<x-var name=\"v\" transform=\"upper\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("", result);
}

test "error_transform_truncate_non_numeric" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello");

    const result = render(a, "<x-var name=\"v\" transform=\"truncate:abc\" />", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_transform_unknown" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "v", "hello");

    const result = render(a, "<x-var name=\"v\" transform=\"nonexistent\" />", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// x-let tests
// ---------------------------------------------------------------------------

test "let_basic_capture" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-let name=\"x\">hello</x-let><x-var name=\"x\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "let_capture_with_nested_elements" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "name", "World");

    const result = try render(a, "<x-let name=\"greeting\">Hello <x-var name=\"name\" />!</x-let><x-var name=\"greeting\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello World!", result);
}

test "let_capture_with_transform" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-let name=\"slug\" transform=\"slugify\">Hello World</x-let><x-var name=\"slug\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("hello-world", result);
}

test "let_usable_in_subsequent_content" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-let name=\"who\">World</x-let>Hello <x-var name=\"who\" />!", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("Hello World!", result);
}

test "let_chained_transforms" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-let name=\"v\" transform=\"trim|upper\">  hello  </x-let><x-var name=\"v\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("HELLO", result);
}

test "let_in_for_scoped_to_iteration" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var entries: [2]Entry = .{ .{}, .{} };
    try entries[0].values.put(a, "name", "alice");
    try entries[1].values.put(a, "name", "bob");
    defer for (&entries) |*e| e.values.deinit(a);
    try ctx.putCollection(a, "users", entries[0..]);

    const result = try render(a,
        \\<x-for user in users><x-let name="upper_name" transform="upper"><x-var name="user.name" /></x-let><x-var name="upper_name" /> </x-for>
    , &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("ALICE BOB ", result);
}

test "let_overrides_existing_var" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);
    try ctx.putVar(a, "x", "old");

    const result = try render(a, "<x-let name=\"x\">new</x-let><x-var name=\"x\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("new", result);
}

test "let_visible_to_include" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "show.html", "<x-var name=\"computed\" />");
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = try render(a, "<x-let name=\"computed\">DERIVED</x-let><x-include template=\"show.html\" />", &ctx, &resolver);
    defer a.free(result);
    try testing.expectEqualStrings("DERIVED", result);
}

test "error_let_no_name" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-let>body</x-let>", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

test "error_let_unclosed" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-let name=\"x\">no close", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
}

// ---------------------------------------------------------------------------
// Named slots in x-include
// ---------------------------------------------------------------------------

test "include_named_slot_single" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html", "<div><h2><x-slot name=\"title\" /></h2></div>");

    const result = try render(
        a,
        "<x-include template=\"card.html\"><x-define name=\"title\">My Title</x-define></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<div><h2>My Title</h2></div>", result);
}

test "include_named_slot_plus_anonymous" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html", "<div><h2><x-slot name=\"title\" /></h2><x-slot /></div>");

    const result = try render(
        a,
        "<x-include template=\"card.html\"><x-define name=\"title\">Card Title</x-define><p>Body content</p></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<div><h2>Card Title</h2><p>Body content</p></div>", result);
}

test "include_multiple_named_slots" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "page.html", "<header><x-slot name=\"header\" /></header><main><x-slot name=\"body\" /></main>");

    const result = try render(
        a,
        "<x-include template=\"page.html\"><x-define name=\"header\">Nav</x-define><x-define name=\"body\"><p>Content</p></x-define></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<header>Nav</header><main><p>Content</p></main>", result);
}

test "include_named_slot_only_no_anonymous" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "widget.html", "<div><x-slot name=\"icon\" /> <x-slot name=\"label\" /></div>");

    const result = try render(
        a,
        "<x-include template=\"widget.html\"><x-define name=\"icon\">*</x-define><x-define name=\"label\">Save</x-define></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<div>* Save</div>", result);
}

test "include_named_slot_default_used" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html", "<div><h2><x-slot name=\"title\">Default Title</x-slot></h2><x-slot /></div>");

    const result = try render(
        a,
        "<x-include template=\"card.html\"><p>Just body</p></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<div><h2>Default Title</h2><p>Just body</p></div>", result);
}

test "include_named_slot_default_overridden" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html", "<div><h2><x-slot name=\"title\">Default Title</x-slot></h2><x-slot /></div>");

    const result = try render(
        a,
        "<x-include template=\"card.html\"><x-define name=\"title\">Custom Title</x-define><p>Body</p></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);
    try testing.expectEqualStrings("<div><h2>Custom Title</h2><p>Body</p></div>", result);
}

test "include_named_slots_with_attrs" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html",
        \\<div class="card" x-attr:data-variant="variant">
        \\  <h2><x-slot name="title" /></h2>
        \\  <x-slot />
        \\</div>
    );

    const result = try render(
        a,
        "<x-include template=\"card.html\" variant=\"featured\"><x-define name=\"title\">Featured</x-define><p>Content</p></x-include>",
        &ctx,
        &resolver,
    );
    defer a.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "data-variant=\"featured\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Featured") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<p>Content</p>") != null);
}

test "include_duplicate_define_is_error" {
    const a = testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);

    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    try resolver.put(a, "card.html", "<div><x-slot name=\"title\" /></div>");

    const result = render(
        a,
        "<x-include template=\"card.html\"><x-define name=\"title\">First</x-define><x-define name=\"title\">Second</x-define></x-include>",
        &ctx,
        &resolver,
    );
    try testing.expectError(error.DuplicateSlotDefinition, result);
}

// ---------------------------------------------------------------------------
// ErrorDetail tests
// ---------------------------------------------------------------------------

test "error_detail_undefined_variable" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var detail: ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &detail };
    defer ctx.deinit(a);

    const result = render(a, "<p><x-var name=\"missing\" /></p>", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqual(@as(usize, 1), detail.line);
    try testing.expectEqualStrings("missing", detail.message);
}

test "error_detail_malformed_element" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var detail: ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &detail };
    defer ctx.deinit(a);

    const result = render(a, "<p><x-var /></p>", &ctx, &resolver);
    try testing.expectError(error.MalformedElement, result);
    try testing.expectEqual(@as(usize, 1), detail.line);
    try testing.expect(detail.message.len > 0);
}

test "error_detail_line_after_newlines" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var detail: ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &detail };
    defer ctx.deinit(a);

    const result = render(a, "<p>one</p>\n<p>two</p>\n<p><x-var name=\"gone\" /></p>", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqual(@as(usize, 3), detail.line);
}

test "error_detail_column" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var detail: ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &detail };
    defer ctx.deinit(a);

    const result = render(a, "abc<x-var name=\"x\" />", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqual(@as(usize, 1), detail.line);
    try testing.expectEqual(@as(usize, 4), detail.column);
}

test "error_detail_message_includes_name" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var detail: ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &detail };
    defer ctx.deinit(a);

    const result = render(a, "<x-var name=\"page.author\" />", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqualStrings("page.author", detail.message);
}

test "error_detail_null_still_returns_error" {
    const a = testing.allocator;
    var resolver: Resolver = .{};
    defer resolver.deinit(a);
    var ctx: Context = .{};
    defer ctx.deinit(a);

    const result = render(a, "<x-var name=\"missing\" />", &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
}
