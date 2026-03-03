const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// AST Types
// ============================================================

const Tag = enum {
    // blocks
    para,
    heading,
    section,
    thematic_break,
    code_block,
    block_quote,
    div,
    bullet_list,
    ordered_list,
    task_list,
    definition_list,
    list_item,
    task_list_item,
    definition_list_item,
    term,
    definition,
    table,
    caption,
    row,
    cell,
    raw_block,
    footnote,
    reference_definition,
    // inline
    str,
    soft_break,
    hard_break,
    non_breaking_space,
    emph,
    strong,
    verbatim,
    link,
    image,
    span,
    mark,
    superscript,
    subscript,
    insert,
    delete,
    double_quoted,
    single_quoted,
    inline_math,
    display_math,
    raw_inline,
    url,
    email,
    footnote_reference,
    symb,
    escape,
    left_single_quote,
    right_single_quote,
    left_double_quote,
    right_double_quote,
    ellipsis,
    em_dash,
    en_dash,
};

const Attr = struct {
    key: []const u8,
    value: []const u8,
};

const SourcePos = struct {
    line: u32,
    col: u32,
    offset: u32,
};

const Node = struct {
    tag: Tag,
    children: []const Node = &.{},
    text: []const u8 = "",
    level: u8 = 0,
    id: ?[]const u8 = null,
    classes: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    reference: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    tight: bool = false,
    checked: ?bool = null,
    head: bool = false,
    cell_align: CellAlign = .default,
    style: ?[]const u8 = null,
    start_pos: ?SourcePos = null,
    end_pos: ?SourcePos = null,

    const CellAlign = enum { default, left, right, center };
};

// ============================================================
// Public API
// ============================================================

pub fn toHtml(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    var p = Parser.init(a, input);
    const doc = p.parseDoc() catch return a.dupe(u8, "");
    var out: std.ArrayList(u8) = .{};
    renderNode(a, &out, doc) catch return a.dupe(u8, "");
    return out.toOwnedSlice(a);
}

pub fn toAst(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    return toAstOpts(a, input, false);
}

pub fn toAstOpts(a: Allocator, input: []const u8, sourcepos: bool) Allocator.Error![]const u8 {
    var p = Parser.init(a, input);
    if (sourcepos) p.track_pos = true;
    const doc = p.parseDoc() catch return a.dupe(u8, "");
    var out: std.ArrayList(u8) = .{};
    renderAstNode(a, &out, doc, 0, true) catch return a.dupe(u8, "");
    return out.toOwnedSlice(a);
}

fn renderAstNode(a: Allocator, out: *std.ArrayList(u8), node: Node, indent: usize, is_root: bool) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.append(a, ' ');

    // Tag name (root section → "doc")
    const tag_name = if (is_root and node.tag == .section)
        "doc"
    else
        @tagName(node.tag);
    try out.appendSlice(a, tag_name);

    // Source position
    if (node.start_pos) |sp| {
        if (node.end_pos) |ep| {
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                " ({d}:{d}:{d}-{d}:{d}:{d})",
                .{ sp.line, sp.col, sp.offset, ep.line, ep.col, ep.offset },
            ));
        }
    }

    // Node-specific properties (matching djot.js output order)
    switch (node.tag) {
        .str, .verbatim, .raw_inline, .raw_block, .code_block, .footnote_reference, .symb => {
            if (node.tag == .symb) {
                if (node.text.len > 0) {
                    try out.appendSlice(a, " alias=");
                    try appendJsonStr(a, out, node.text);
                }
            } else if (node.text.len > 0) {
                try out.appendSlice(a, " text=");
                try appendJsonStr(a, out, node.text);
            }
        },
        .heading => {
            try out.appendSlice(a, try std.fmt.allocPrint(a, " level={d}", .{node.level}));
        },
        .bullet_list => {
            try out.appendSlice(a, if (node.tight) " tight=true" else " tight=false");
            if (node.style) |s| {
                try out.appendSlice(a, " style=");
                try appendJsonStr(a, out, s);
            }
        },
        .ordered_list => {
            try out.appendSlice(a, if (node.tight) " tight=true" else " tight=false");
        },
        .task_list_item => {
            if (node.checked) |checked| {
                try out.appendSlice(a, if (checked) " checked=true" else " checked=false");
            }
        },
        .link, .image, .url, .email => {
            if (node.destination) |dest| {
                try out.appendSlice(a, " destination=");
                try appendJsonStr(a, out, dest);
            }
            if (node.reference) |ref| {
                if (ref.len > 0) {
                    try out.appendSlice(a, " reference=");
                    try appendJsonStr(a, out, ref);
                }
            }
        },
        .row => {
            try out.appendSlice(a, if (node.head) " head=true" else " head=false");
        },
        .cell => {
            try out.appendSlice(a, if (node.head) " head=true" else " head=false");
            const align_str = switch (node.cell_align) {
                .default => " align=\"default\"",
                .left => " align=\"left\"",
                .right => " align=\"right\"",
                .center => " align=\"center\"",
            };
            try out.appendSlice(a, align_str);
        },
        else => {},
    }

    // Inline code lang
    if (node.lang) |lang| {
        try out.appendSlice(a, " lang=");
        try appendJsonStr(a, out, lang);
    }

    // User attributes (id, class, key=value)
    if (node.id) |id| {
        try out.appendSlice(a, " id=");
        try appendJsonStr(a, out, id);
    }
    if (node.classes) |cls| {
        try out.appendSlice(a, " class=");
        try appendJsonStr(a, out, cls);
    }
    for (node.attrs) |attr| {
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.append(a, '=');
        try appendJsonStr(a, out, attr.value);
    }

    try out.append(a, '\n');

    // Children
    for (node.children) |child| {
        try renderAstNode(a, out, child, indent + 2, false);
    }
}

fn appendJsonStr(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

// ============================================================
// Block Parser
// ============================================================

const RefDef = struct {
    url: []const u8,
    attrs: ?BlockAttrs = null,
};

const Parser = struct {
    a: Allocator,
    input: []const u8,
    lines: []const []const u8 = &.{},
    line_offsets: []const u32 = &.{},
    pos: usize = 0,
    ref_defs: std.StringArrayHashMapUnmanaged(RefDef) = .{},
    auto_refs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    ids_used: std.StringArrayHashMapUnmanaged(void) = .{},
    footnote_defs: std.StringArrayHashMapUnmanaged([]const Node) = .{},
    footnote_order: std.ArrayList([]const u8) = .{},
    end_marker: ?[]const u8 = null,
    track_pos: bool = false,
    base_offset: u32 = 0,
    base_line: u32 = 1,
    col_offsets: []const u32 = &.{},

    fn init(a: Allocator, input: []const u8) Parser {
        var p = Parser{ .a = a, .input = input };
        p.splitLines() catch {};
        return p;
    }

    fn splitLines(self: *Parser) !void {
        var list: std.ArrayList([]const u8) = .{};
        var offsets: std.ArrayList(u32) = .{};
        var offset: u32 = 0;
        var it = std.mem.splitScalar(u8, self.input, '\n');
        while (it.next()) |line| {
            try list.append(self.a, line);
            try offsets.append(self.a, offset);
            offset += @intCast(line.len + 1); // +1 for newline
        }
        if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
            _ = list.pop();
            _ = offsets.pop();
        }
        self.lines = try list.toOwnedSlice(self.a);
        self.line_offsets = try offsets.toOwnedSlice(self.a);
    }

    /// Create a SourcePos for a position in the input.
    /// col is 1-based within the sub-parser's line; col=0 means "end of previous line".
    /// col_offsets adjusts the displayed column for sub-parsers whose lines are
    /// stripped substrings of the parent's lines.
    fn makePos(self: *Parser, line_idx: usize, col: u32) SourcePos {
        const col_adj: u32 = if (line_idx < self.col_offsets.len) self.col_offsets[line_idx] else 0;
        const display_col = col + col_adj;
        const offset = if (line_idx < self.line_offsets.len) blk: {
            if (col == 0) {
                break :blk if (self.line_offsets[line_idx] > 0)
                    self.line_offsets[line_idx] - 1
                else
                    0;
            }
            break :blk self.line_offsets[line_idx] + col - 1;
        } else if (self.line_offsets.len > 0)
            self.line_offsets[self.line_offsets.len - 1] + @as(u32, @intCast(self.lines[self.lines.len - 1].len))
        else
            0;
        return .{
            .line = self.base_line + @as(u32, @intCast(line_idx)),
            .col = display_col,
            .offset = self.base_offset + offset,
        };
    }

    fn endOfInputPos(self: *Parser) SourcePos {
        const total: u32 = @intCast(self.input.len);
        if (self.lines.len == 0) return .{ .line = self.base_line, .col = 0, .offset = self.base_offset + total };
        return .{
            .line = self.base_line + @as(u32, @intCast(self.lines.len)),
            .col = 0,
            .offset = self.base_offset + total,
        };
    }

    fn parseDoc(self: *Parser) !Node {
        const blocks = try self.parseBlocks();
        const with_sections = try self.wrapSections(blocks);
        const resolved = try self.resolveReferences(with_sections);

        if (self.footnote_order.items.len > 0) {
            var all: std.ArrayList(Node) = .{};
            for (resolved) |n| try all.append(self.a, n);
            try all.append(self.a, try self.buildFootnoteSection());
            return .{ .tag = .section, .children = try all.toOwnedSlice(self.a) };
        }

        return .{ .tag = .section, .children = resolved };
    }

    fn parseBlocks(self: *Parser) anyerror![]const Node {
        return self.parseBlocksUntil(null);
    }

    fn parseBlocksUntil(self: *Parser, end_marker: ?[]const u8) anyerror![]const Node {
        const prev_marker = self.end_marker;
        self.end_marker = end_marker;
        defer self.end_marker = prev_marker;
        var children: std.ArrayList(Node) = .{};
        var pending_attrs: ?BlockAttrs = null;

        while (self.pos < self.lines.len) {
            const line = self.lines[self.pos];

            if (isBlank(line)) {
                self.pos += 1;
                pending_attrs = null; // blank line clears pending block attrs
                continue;
            }

            // Check for closing fence (for fenced divs)
            if (end_marker) |marker| {
                if (countLeadingChar(line, ':') >= marker.len and
                    isBlank(std.mem.trimLeft(u8, line, ":")))
                {
                    self.pos += 1;
                    break;
                }
            }

            // Try block attribute (single-line or multi-line)
            if (try self.tryBlockAttr()) |ba| {
                pending_attrs = mergeBlockAttrs(self.a, pending_attrs, ba) catch ba;
                continue;
            }

            var node: Node = undefined;

            if (try self.tryHeading()) |h| {
                node = h;
            } else if (self.tryThematicBreak()) |tb| {
                node = tb;
            } else if (try self.tryCodeBlock()) |cb| {
                node = cb;
            } else if (try self.tryBlockQuote()) |bq| {
                node = bq;
            } else if (try self.tryFencedDiv()) |fd| {
                node = fd;
            } else if (try self.tryRefDef(pending_attrs)) |_| {
                pending_attrs = null;
                continue;
            } else if (try self.tryFootnoteDef()) |_| {
                continue;
            } else if (try self.tryDefinitionList()) |dl| {
                node = dl;
            } else if (try self.tryBulletList()) |bl| {
                node = bl;
            } else if (try self.tryOrderedList()) |ol| {
                node = ol;
            } else if (try self.tryTable()) |tbl| {
                node = tbl;
            } else {
                node = try self.parseParagraph();
            }

            if (pending_attrs) |ba| {
                node = applyBlockAttrs(node, ba);
                pending_attrs = null;
            }

            try children.append(self.a, node);
        }

        return children.toOwnedSlice(self.a);
    }

    fn tryBlockAttr(self: *Parser) !?BlockAttrs {
        const line = self.lines[self.pos];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len < 1 or trimmed[0] != '{') return null;

        // Single-line: attrs must occupy the entire line
        if (trimmed[trimmed.len - 1] == '}') {
            if (parseAttrsFromStr(self.a, trimmed)) |ba| {
                self.pos += 1;
                return ba;
            }
        }

        // Multi-line: first line starts with {, continuation lines are indented,
        // last continuation line must end with }
        const indent = indentOf(line);
        var full_text: std.ArrayList(u8) = .{};
        try full_text.appendSlice(self.a, trimmed);
        var lines_consumed: usize = 1;

        while (self.pos + lines_consumed < self.lines.len) {
            const next = self.lines[self.pos + lines_consumed];
            if (isBlank(next)) break;
            const next_indent = indentOf(next);
            if (next_indent <= indent) break;
            try full_text.append(self.a, '\n');
            try full_text.appendSlice(self.a, std.mem.trim(u8, next, " \t"));
            lines_consumed += 1;

            if (parseAttrsFromStr(self.a, full_text.items)) |ba| {
                self.pos += lines_consumed;
                return ba;
            }
        }

        return null;
    }

    fn isClosingFence(self: *const Parser, line: []const u8) bool {
        const marker = self.end_marker orelse return false;
        return countLeadingChar(line, ':') >= marker.len and
            isBlank(std.mem.trimLeft(u8, line, ":"));
    }

    fn parseParagraph(self: *Parser) !Node {
        const para_start_line = self.pos;
        var text_lines: std.ArrayList([]const u8) = .{};
        while (self.pos < self.lines.len) {
            const line = self.lines[self.pos];
            if (isBlank(line)) break;
            if (self.isClosingFence(line)) break;
            try text_lines.append(self.a, std.mem.trimLeft(u8, line, " \t"));
            self.pos += 1;
        }
        const inlines = try parseInlines(self.a, text_lines.items);

        var para = Node{ .tag = .para, .children = inlines };
        if (self.track_pos) {
            const first_col = self.contentCol(para_start_line);
            para.start_pos = self.makePos(para_start_line, first_col);
            para.end_pos = self.makePos(self.pos, 0);

            // Assign positions to inline str nodes
            self.assignInlinePositions(inlines, text_lines.items, para_start_line);
        }
        return para;
    }

    fn contentCol(self: *Parser, line_idx: usize) u32 {
        if (line_idx >= self.lines.len) return 1;
        const full_line = self.lines[line_idx];
        const trimmed = std.mem.trimLeft(u8, full_line, " \t");
        return @intCast(full_line.len - trimmed.len + 1);
    }

    fn assignInlinePositions(self: *Parser, nodes: []const Node, text_lines: []const []const u8, start_line: usize) void {
        if (!self.track_pos) return;
        const src = joinLines(self.a, text_lines) catch return;

        var src_offset: usize = 0;
        for (nodes) |*node_const| {
            const node = @constCast(node_const);
            if (node.tag == .str and node.text.len > 0) {
                // Find this text in the joined source
                const idx = std.mem.indexOf(u8, src[src_offset..], node.text) orelse continue;
                const abs_idx = src_offset + idx;

                // Map abs_idx to a line in text_lines
                var line_offset: usize = 0;
                var mapped_ti: usize = 0;
                for (text_lines, 0..) |tl, ti| {
                    if (abs_idx < line_offset + tl.len) {
                        mapped_ti = ti;
                        break;
                    }
                    line_offset += tl.len + 1;
                }
                const col_in_text = abs_idx - line_offset;
                const orig_line = start_line + mapped_ti;
                const col = self.contentCol(orig_line) + @as(u32, @intCast(col_in_text));

                node.start_pos = self.makePos(orig_line, col);
                node.end_pos = self.makePos(orig_line, col + @as(u32, @intCast(node.text.len)) - 1);

                src_offset = abs_idx + node.text.len;
            }
        }
    }

    fn tryHeading(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const trimmed = std.mem.trimLeft(u8, line, " ");
        const hashes = countLeadingChar(trimmed, '#');
        if (hashes == 0 or hashes > 6) return null;
        if (hashes >= trimmed.len) {
            // Just hashes, next line is content
        } else if (trimmed[hashes] != ' ' and trimmed[hashes] != '\t') {
            return null;
        }

        self.pos += 1;

        // Content after hashes
        var content_lines: std.ArrayList([]const u8) = .{};
        const after_hashes = std.mem.trim(u8, trimmed[hashes..], " \t");
        if (after_hashes.len > 0) {
            try content_lines.append(self.a, after_hashes);
        }

        // Continuation lines
        while (self.pos < self.lines.len) {
            const next = self.lines[self.pos];
            if (isBlank(next)) break;
            // Check for other block types that terminate the heading
            if (isThematicBreak(next) or isCodeFence(next) != null or
                startsBlockQuote(next) or isFencedDivStart(next) != null)
                break;
            if (parseBulletMarker(next) != null or parseOrderedMarker(next) != null)
                break;
            if (tryParseBlockAttr(next) != null) break;
            const next_trimmed = std.mem.trimLeft(u8, next, " ");
            const next_hashes = countLeadingChar(next_trimmed, '#');
            if (next_hashes == hashes and next_hashes < next_trimmed.len and
                (next_trimmed[next_hashes] == ' ' or next_trimmed[next_hashes] == '\t'))
            {
                // Same-level heading continuation: strip prefix
                try content_lines.append(self.a, std.mem.trim(u8, next_trimmed[next_hashes..], " \t"));
            } else if (next_hashes > 0 and next_hashes <= 6 and next_hashes != hashes and
                (next_hashes >= next_trimmed.len or next_trimmed[next_hashes] == ' ' or next_trimmed[next_hashes] == '\t'))
            {
                // Different-level heading: break
                break;
            } else {
                try content_lines.append(self.a, next);
            }
            self.pos += 1;
        }

        const inlines = try parseInlines(self.a, content_lines.items);
        return .{
            .tag = .heading,
            .level = @intCast(hashes),
            .children = inlines,
        };
    }

    fn tryThematicBreak(self: *Parser) ?Node {
        const line = self.lines[self.pos];
        if (!isThematicBreak(line)) return null;
        self.pos += 1;
        return .{ .tag = .thematic_break };
    }

    fn tryCodeBlock(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const fence_info = isCodeFence(line) orelse return null;
        self.pos += 1;

        var content: std.ArrayList(u8) = .{};
        while (self.pos < self.lines.len) {
            const l = self.lines[self.pos];
            self.pos += 1;
            // Check for closing fence
            const close_char = countLeadingChar(std.mem.trimLeft(u8, l, " "), fence_info.char);
            if (close_char >= fence_info.len and
                isBlank(std.mem.trimLeft(u8, std.mem.trimLeft(u8, l, " ")[close_char..], &[_]u8{ fence_info.char })))
            {
                break;
            }
            // Strip leading indent
            var stripped = l;
            var indent_remaining = fence_info.indent;
            while (indent_remaining > 0 and stripped.len > 0 and stripped[0] == ' ') {
                stripped = stripped[1..];
                indent_remaining -= 1;
            }
            try content.appendSlice(self.a, stripped);
            try content.append(self.a, '\n');
        }

        const lang = fence_info.lang;
        if (lang != null and lang.?[0] == '=') {
            return .{
                .tag = .raw_block,
                .text = try content.toOwnedSlice(self.a),
                .lang = lang.?[1..],
            };
        }
        return .{
            .tag = .code_block,
            .text = try content.toOwnedSlice(self.a),
            .lang = lang,
        };
    }

    fn tryBlockQuote(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        if (!startsBlockQuote(line)) return null;

        var inner_lines: std.ArrayList([]const u8) = .{};
        while (self.pos < self.lines.len) {
            const l = self.lines[self.pos];
            if (startsBlockQuote(l)) {
                try inner_lines.append(self.a, stripBlockQuotePrefix(l));
                self.pos += 1;
            } else if (!isBlank(l) and inner_lines.items.len > 0 and
                !isBlank(inner_lines.items[inner_lines.items.len - 1]) and
                !self.isClosingFence(l))
            {
                // Lazy continuation (but not div closing fences)
                try inner_lines.append(self.a, l);
                self.pos += 1;
            } else {
                break;
            }
        }

        // Recursively parse inner content
        const inner_text = try joinLines(self.a, inner_lines.items);
        var inner_parser = Parser.init(self.a, inner_text);
        inner_parser.ref_defs = self.ref_defs;
        inner_parser.auto_refs = self.auto_refs;
        inner_parser.ids_used = self.ids_used;
        inner_parser.footnote_defs = self.footnote_defs;
        inner_parser.footnote_order = self.footnote_order;
        const inner_blocks = try inner_parser.parseBlocks();
        self.ref_defs = inner_parser.ref_defs;
        self.auto_refs = inner_parser.auto_refs;
        self.ids_used = inner_parser.ids_used;
        self.footnote_defs = inner_parser.footnote_defs;
        self.footnote_order = inner_parser.footnote_order;

        // Add IDs to headings inside block quotes (no section wrapping)
        const tagged = try self.addHeadingIds(inner_blocks);
        return .{ .tag = .block_quote, .children = tagged };
    }

    fn tryFencedDiv(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const div_info = isFencedDivStart(line) orelse return null;
        self.pos += 1;

        const blocks = try self.parseBlocksUntil(div_info.fence);

        var node = Node{ .tag = .div, .children = blocks };
        if (div_info.class) |cls| {
            node.classes = cls;
        }
        return node;
    }

    fn tryRefDef(self: *Parser, pending_attrs: ?BlockAttrs) !?void {
        const line = self.lines[self.pos];
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len < 4 or trimmed[0] != '[') return null;

        const close_bracket = std.mem.indexOfScalar(u8, trimmed[1..], ']') orelse return null;
        if (close_bracket + 2 >= trimmed.len or trimmed[close_bracket + 2] != ':') return null;
        const label = trimmed[1 .. close_bracket + 1];
        var dest_text = std.mem.trim(u8, trimmed[close_bracket + 3 ..], " \t");

        if (label.len > 0 and label[0] == '^') return null;

        self.pos += 1;

        // Collect continuation lines (indented) for multi-line URLs
        var dest_parts: std.ArrayList([]const u8) = .{};
        if (dest_text.len > 0) try dest_parts.append(self.a, dest_text);
        while (self.pos < self.lines.len) {
            const next = self.lines[self.pos];
            if (isBlank(next)) break;
            if (next.len == 0 or (next[0] != ' ' and next[0] != '\t')) break;
            // Check if it's another ref def
            const next_trimmed = std.mem.trimLeft(u8, next, " ");
            if (next_trimmed.len > 0 and next_trimmed[0] == '[') break;
            try dest_parts.append(self.a, std.mem.trim(u8, next, " \t"));
            self.pos += 1;
        }

        if (dest_parts.items.len == 0) {
            dest_text = "";
        } else if (dest_parts.items.len == 1) {
            dest_text = dest_parts.items[0];
        } else {
            var buf: std.ArrayList(u8) = .{};
            for (dest_parts.items) |part| try buf.appendSlice(self.a, part);
            dest_text = try buf.toOwnedSlice(self.a);
        }

        try self.ref_defs.put(self.a, label, .{ .url = dest_text, .attrs = pending_attrs });
        return {};
    }

    fn tryFootnoteDef(self: *Parser) !?void {
        const line = self.lines[self.pos];
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len < 5 or !std.mem.startsWith(u8, trimmed, "[^")) return null;

        const close = std.mem.indexOfScalar(u8, trimmed[2..], ']') orelse return null;
        if (close + 3 >= trimmed.len or trimmed[close + 3] != ':') return null;

        const label = trimmed[2 .. close + 2];
        const rest = std.mem.trim(u8, trimmed[close + 4 ..], " \t");

        self.pos += 1;

        var content_lines: std.ArrayList([]const u8) = .{};
        if (rest.len > 0) try content_lines.append(self.a, rest);
        while (self.pos < self.lines.len) {
            const l = self.lines[self.pos];
            if (isBlank(l)) {
                // Blank line: include if next non-blank is indented
                var lookahead = self.pos + 1;
                while (lookahead < self.lines.len and isBlank(self.lines[lookahead])) : (lookahead += 1) {}
                if (lookahead < self.lines.len and
                    self.lines[lookahead].len > 0 and
                    (self.lines[lookahead][0] == ' ' or self.lines[lookahead][0] == '\t'))
                {
                    try content_lines.append(self.a, "");
                    self.pos += 1;
                } else break;
            } else if (l.len > 0 and (l[0] == ' ' or l[0] == '\t')) {
                try content_lines.append(self.a, std.mem.trimLeft(u8, l, " \t"));
                self.pos += 1;
            } else break;
        }

        const inner_text = try joinLines(self.a, content_lines.items);
        var inner_parser = Parser.init(self.a, inner_text);
        inner_parser.ref_defs = self.ref_defs;
        inner_parser.ids_used = self.ids_used;
        const inner_blocks = try inner_parser.parseBlocks();
        self.ref_defs = inner_parser.ref_defs;
        self.ids_used = inner_parser.ids_used;
        try self.footnote_defs.put(self.a, label, inner_blocks);

        return {};
    }

    fn tryBulletList(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const first_info = parseBulletMarker(line) orelse return null;
        const list_indent = first_info.indent;
        const marker_char = first_info.marker;
        const list_start_line = self.pos;

        var items: std.ArrayList(Node) = .{};
        var is_tight = true;
        var saw_blank_between = false;

        while (self.pos < self.lines.len) {
            const cur = self.lines[self.pos];
            const cur_li = parseBulletMarker(cur) orelse break;
            if (cur_li.indent != list_indent or cur_li.marker != marker_char) break;

            if (saw_blank_between) is_tight = false;
            saw_blank_between = false;

            const item_start_line = self.pos;
            const content_col = cur_li.content_col;
            // Collect paragraph lines (before first blank) and block lines (after first blank)
            var para_lines: std.ArrayList([]const u8) = .{};
            var para_orig_lines: std.ArrayList(usize) = .{};
            var para_col_offsets: std.ArrayList(u32) = .{};
            try para_lines.append(self.a, cur_li.rest);
            try para_orig_lines.append(self.a, self.pos);
            try para_col_offsets.append(self.a, @intCast(content_col));
            self.pos += 1;

            var block_lines: std.ArrayList([]const u8) = .{};
            var item_saw_blank = false;

            // Phase 1: collect paragraph continuation (before any blank line)
            while (self.pos < self.lines.len and !item_saw_blank) {
                const next = self.lines[self.pos];
                if (isBlank(next)) {
                    item_saw_blank = true;
                    self.pos += 1;
                    continue;
                }

                // Check for any list marker at same indent (sibling or different list)
                if (parseBulletMarker(next)) |next_li| {
                    if (next_li.indent <= list_indent) break;
                }
                if (parseOrderedMarker(next)) |next_ol| {
                    if (next_ol.indent <= list_indent) break;
                }

                // Lazy or indented continuation — stays in paragraph
                const next_indent = countIndent(next);
                const strip: u32 = if (next_indent >= content_col) @intCast(content_col) else @intCast(next_indent);
                try para_lines.append(self.a, next[strip..]);
                try para_orig_lines.append(self.a, self.pos);
                try para_col_offsets.append(self.a, strip);
                self.pos += 1;
            }

            // Phase 2: collect block continuation (after blank line, properly indented)
            var last_was_blank = true; // blank line triggered Phase 2
            while (self.pos < self.lines.len and item_saw_blank) {
                const next = self.lines[self.pos];
                if (isBlank(next)) {
                    try block_lines.append(self.a, "");
                    self.pos += 1;
                    last_was_blank = true;
                    continue;
                }

                const next_indent = countIndent(next);
                if (next_indent > list_indent) {
                    const is_marker = parseBulletMarker(next) != null or parseOrderedMarker(next) != null;
                    const strip = if (is_marker)
                        @min(next_indent, list_indent + 1)
                    else
                        @min(next_indent, content_col);
                    try block_lines.append(self.a, next[strip..]);
                    self.pos += 1;
                    last_was_blank = false;
                    continue;
                }
                // Lazy continuation: non-indented, non-blank line immediately
                // following a non-blank line, that doesn't start a new block
                if (!last_was_blank and !isNewBlockStart(next)) {
                    try block_lines.append(self.a, std.mem.trimLeft(u8, next, " \t"));
                    self.pos += 1;
                    last_was_blank = false;
                    continue;
                }
                break;
            }

            // Trim trailing blanks from block_lines
            while (block_lines.items.len > 0 and
                isBlank(block_lines.items[block_lines.items.len - 1]))
            {
                _ = block_lines.pop();
            }

            // Build inner blocks
            var inner_blocks_list: std.ArrayList(Node) = .{};

            // Detect task list item from raw text before parsing
            var is_task = false;
            var task_checked = false;
            if (para_lines.items.len > 0) {
                const first_line = para_lines.items[0];
                if (std.mem.startsWith(u8, first_line, "[ ] ") or
                    std.mem.startsWith(u8, first_line, "[x] ") or
                    std.mem.startsWith(u8, first_line, "[X] "))
                {
                    is_task = true;
                    task_checked = first_line[1] != ' ';
                    para_lines.items[0] = first_line[4..];
                }
            }

            // Parse paragraph from para_lines
            const para_text = try joinLines(self.a, para_lines.items);
            if (para_text.len > 0) {
                var para_parser = Parser.init(self.a, para_text);
                para_parser.ref_defs = self.ref_defs;
                para_parser.auto_refs = self.auto_refs;
                para_parser.ids_used = self.ids_used;
                if (self.track_pos and para_orig_lines.items.len > 0) {
                    para_parser.track_pos = true;
                    const first_orig = para_orig_lines.items[0];
                    const first_col_off = para_col_offsets.items[0];
                    para_parser.base_line = self.base_line + @as(u32, @intCast(first_orig));
                    para_parser.base_offset = self.base_offset +
                        (if (first_orig < self.line_offsets.len) self.line_offsets[first_orig] else 0) +
                        first_col_off;
                    para_parser.col_offsets = try para_col_offsets.toOwnedSlice(self.a);
                }
                const para_blocks = try para_parser.parseBlocks();
                self.ref_defs = para_parser.ref_defs;
                self.auto_refs = para_parser.auto_refs;
                self.ids_used = para_parser.ids_used;
                for (para_blocks) |b| try inner_blocks_list.append(self.a, b);
            }

            // Parse block content from block_lines
            if (block_lines.items.len > 0) {
                const block_text = try joinLines(self.a, block_lines.items);
                var block_parser = Parser.init(self.a, block_text);
                block_parser.ref_defs = self.ref_defs;
                block_parser.auto_refs = self.auto_refs;
                block_parser.ids_used = self.ids_used;
                const extra_blocks = try block_parser.parseBlocks();
                self.ref_defs = block_parser.ref_defs;
                self.auto_refs = block_parser.auto_refs;
                self.ids_used = block_parser.ids_used;
                for (extra_blocks) |b| try inner_blocks_list.append(self.a, b);
            }

            const inner_blocks = try inner_blocks_list.toOwnedSlice(self.a);

            const item_sp = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null;
            const item_ep = if (self.track_pos) blk: {
                const ep_col: u32 = if (self.pos >= self.lines.len) 0 else 1;
                break :blk self.makePos(self.pos, ep_col);
            } else null;
            if (is_task) {
                try items.append(self.a, .{
                    .tag = .task_list_item,
                    .children = inner_blocks,
                    .checked = task_checked,
                    .start_pos = item_sp,
                    .end_pos = item_ep,
                });
            } else {
                try items.append(self.a, .{
                    .tag = .list_item,
                    .children = inner_blocks,
                    .start_pos = item_sp,
                    .end_pos = item_ep,
                });
            }

            // List is loose if any item has multiple paragraphs or block-level content after a blank
            if (item_saw_blank and block_lines.items.len > 0) {
                // Item has block content after a blank → check for multi-paragraph
                var para_count: usize = 0;
                for (inner_blocks) |b| {
                    if (b.tag == .para) para_count += 1;
                }
                if (para_count > 1) is_tight = false;
            }
            // Or blank between items (blank not consumed by block content)
            if (item_saw_blank and block_lines.items.len == 0) {
                saw_blank_between = true;
            }
        }

        var has_task = false;
        for (items.items) |item| {
            if (item.tag == .task_list_item) {
                has_task = true;
                break;
            }
        }

        const list_tag: Tag = if (has_task) .task_list else .bullet_list;
        const list_sp = if (self.track_pos) self.makePos(list_start_line, @intCast(list_indent + 1)) else null;
        const list_ep = if (self.track_pos) self.makePos(self.pos, 0) else null;
        const marker_str: []const u8 = switch (marker_char) {
            '-' => "-",
            '+' => "+",
            '*' => "*",
            else => "-",
        };
        return .{
            .tag = list_tag,
            .children = try items.toOwnedSlice(self.a),
            .tight = is_tight,
            .style = marker_str,
            .start_pos = list_sp,
            .end_pos = list_ep,
        };
    }

    fn tryOrderedList(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const first_info = parseOrderedMarker(line) orelse return null;
        const list_indent = first_info.indent;

        // Track possible styles (may narrow from ambiguous to specific)
        var possible_styles: [2]?ListStyle = first_info.styles;
        var n_possible: u2 = first_info.n_styles;

        var items: std.ArrayList(Node) = .{};
        var is_tight = true;
        var saw_blank_between = false;

        while (self.pos < self.lines.len) {
            const cur = self.lines[self.pos];
            const cur_ol = parseOrderedMarker(cur) orelse break;
            if (cur_ol.indent != list_indent) break;

            // Check style compatibility: new item must share at least one style
            var compatible = false;
            for (0..cur_ol.n_styles) |si| {
                const s = cur_ol.styles[si] orelse continue;
                for (0..n_possible) |pi| {
                    if (possible_styles[pi] == s) { compatible = true; break; }
                }
                if (compatible) break;
            }
            if (!compatible and items.items.len > 0) break;

            // Narrow styles to intersection
            if (items.items.len > 0) {
                var new_styles: [2]?ListStyle = .{ null, null };
                var new_n: u2 = 0;
                for (0..n_possible) |pi| {
                    const ps = possible_styles[pi] orelse continue;
                    for (0..cur_ol.n_styles) |si| {
                        if (cur_ol.styles[si] == ps) {
                            new_styles[new_n] = ps;
                            new_n += 1;
                            break;
                        }
                    }
                }
                if (new_n > 0) {
                    possible_styles = new_styles;
                    n_possible = new_n;
                }
            }

            if (saw_blank_between and items.items.len > 0) is_tight = false;
            saw_blank_between = false;

            const content_col = cur_ol.content_col;
            var para_lines: std.ArrayList([]const u8) = .{};
            try para_lines.append(self.a, cur_ol.rest);
            self.pos += 1;

            var block_lines: std.ArrayList([]const u8) = .{};
            var item_saw_blank = false;

            // Phase 1: paragraph continuation (before blank)
            while (self.pos < self.lines.len and !item_saw_blank) {
                const next = self.lines[self.pos];
                if (isBlank(next)) {
                    item_saw_blank = true;
                    saw_blank_between = true;
                    self.pos += 1;
                    continue;
                }

                if (parseOrderedMarker(next)) |next_ol| {
                    if (next_ol.indent == list_indent) break;
                }

                const next_indent = countIndent(next);
                if (next_indent >= content_col) {
                    try para_lines.append(self.a, next[content_col..]);
                } else {
                    try para_lines.append(self.a, next[next_indent..]);
                }
                self.pos += 1;
            }

            // Phase 2: block continuation (after blank)
            while (self.pos < self.lines.len and item_saw_blank) {
                const next = self.lines[self.pos];
                if (isBlank(next)) {
                    try block_lines.append(self.a, "");
                    self.pos += 1;
                    continue;
                }

                const next_indent = countIndent(next);
                if (next_indent > list_indent) {
                    const is_marker = parseBulletMarker(next) != null or parseOrderedMarker(next) != null;
                    const strip = if (is_marker)
                        @min(next_indent, list_indent + 1)
                    else
                        @min(next_indent, content_col);
                    try block_lines.append(self.a, next[strip..]);
                    self.pos += 1;
                    continue;
                }
                break;
            }

            while (block_lines.items.len > 0 and
                isBlank(block_lines.items[block_lines.items.len - 1]))
            {
                _ = block_lines.pop();
            }

            var inner_blocks_list: std.ArrayList(Node) = .{};

            const para_text = try joinLines(self.a, para_lines.items);
            if (para_text.len > 0) {
                var para_parser = Parser.init(self.a, para_text);
                para_parser.ref_defs = self.ref_defs;
                para_parser.auto_refs = self.auto_refs;
                para_parser.ids_used = self.ids_used;
                const para_blocks = try para_parser.parseBlocks();
                self.ref_defs = para_parser.ref_defs;
                self.auto_refs = para_parser.auto_refs;
                self.ids_used = para_parser.ids_used;
                for (para_blocks) |b| try inner_blocks_list.append(self.a, b);
            }

            if (block_lines.items.len > 0) {
                const block_text = try joinLines(self.a, block_lines.items);
                var block_parser = Parser.init(self.a, block_text);
                block_parser.ref_defs = self.ref_defs;
                block_parser.auto_refs = self.auto_refs;
                block_parser.ids_used = self.ids_used;
                const extra_blocks = try block_parser.parseBlocks();
                self.ref_defs = block_parser.ref_defs;
                self.auto_refs = block_parser.auto_refs;
                self.ids_used = block_parser.ids_used;
                for (extra_blocks) |b| try inner_blocks_list.append(self.a, b);
            }

            const inner_blocks = try inner_blocks_list.toOwnedSlice(self.a);
            try items.append(self.a, .{ .tag = .list_item, .children = inner_blocks });
        }

        const final_style = possible_styles[0] orelse .decimal;
        const resolved_start = getListStart(first_info.marker_text, final_style);
        var ol_attrs: std.ArrayList(Attr) = .{};
        if (resolved_start != 1) {
            var start_buf: [20]u8 = undefined;
            const start_str = std.fmt.bufPrint(&start_buf, "{}", .{resolved_start}) catch "1";
            try ol_attrs.append(self.a, .{ .key = "start", .value = try self.a.dupe(u8, start_str) });
        }
        if (final_style.htmlType()) |t| {
            try ol_attrs.append(self.a, .{ .key = "type", .value = t });
        }
        return .{
            .tag = .ordered_list,
            .children = try items.toOwnedSlice(self.a),
            .tight = is_tight,
            .attrs = try ol_attrs.toOwnedSlice(self.a),
        };
    }

    fn tryDefinitionList(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len < 2 or trimmed[0] != ':' or (trimmed[1] != ' ' and trimmed[1] != '\t')) return null;

        var items: std.ArrayList(Node) = .{};

        while (self.pos < self.lines.len) {
            const cur = self.lines[self.pos];
            const cur_trimmed = std.mem.trimLeft(u8, cur, " ");
            if (cur_trimmed.len < 2 or cur_trimmed[0] != ':' or (cur_trimmed[1] != ' ' and cur_trimmed[1] != '\t')) break;

            const marker_indent = @as(usize, @intCast(cur.len - cur_trimmed.len));
            const content_indent = marker_indent + 2;
            const first_content = cur_trimmed[2..];
            self.pos += 1;

            // Gather all item content lines (term + definition body).
            // The first line is the text after `: `. Subsequent lines continue
            // if indented past the marker or blank.
            var content_lines: std.ArrayList([]const u8) = .{};
            try content_lines.append(self.a, first_content);

            while (self.pos < self.lines.len) {
                const next = self.lines[self.pos];
                if (isBlank(next)) {
                    self.pos += 1;
                    // Blank lines: keep if next non-blank is indented
                    var blanks: usize = 1;
                    while (self.pos < self.lines.len and isBlank(self.lines[self.pos])) {
                        self.pos += 1;
                        blanks += 1;
                    }
                    if (self.pos >= self.lines.len) break;
                    const peek = self.lines[self.pos];
                    if (countIndent(peek) >= content_indent) {
                        var b: usize = 0;
                        while (b < blanks) : (b += 1) try content_lines.append(self.a, "");
                        continue;
                    }
                    break;
                }
                const ni = countIndent(next);
                if (ni >= content_indent) {
                    try content_lines.append(self.a, next[content_indent..]);
                    self.pos += 1;
                } else if (ni > marker_indent and ni < content_indent) {
                    // Continuation of term (indented past marker but less than content)
                    try content_lines.append(self.a, std.mem.trimLeft(u8, next, " \t"));
                    self.pos += 1;
                } else {
                    break;
                }
            }

            // Parse gathered content as blocks, then extract term
            const content_text = try joinLines(self.a, content_lines.items);
            var inner_parser = Parser.init(self.a, content_text);
            inner_parser.ref_defs = self.ref_defs;
            inner_parser.auto_refs = self.auto_refs;
            inner_parser.ids_used = self.ids_used;
            const all_blocks = try inner_parser.parseBlocks();
            self.ref_defs = inner_parser.ref_defs;
            self.auto_refs = inner_parser.auto_refs;
            self.ids_used = inner_parser.ids_used;

            // djot.js pattern: first paragraph becomes <dt>, rest becomes <dd>
            var term_node: Node = undefined;
            var def_blocks: []const Node = &.{};
            if (all_blocks.len > 0 and all_blocks[0].tag == .para) {
                term_node = .{ .tag = .term, .children = all_blocks[0].children };
                def_blocks = all_blocks[1..];
            } else {
                term_node = .{ .tag = .term, .children = &.{} };
                def_blocks = all_blocks;
            }

            var item_children: std.ArrayList(Node) = .{};
            try item_children.append(self.a, term_node);
            try item_children.append(self.a, .{ .tag = .definition, .children = def_blocks });
            try items.append(self.a, .{
                .tag = .definition_list_item,
                .children = try item_children.toOwnedSlice(self.a),
            });
        }

        if (items.items.len == 0) return null;
        return .{
            .tag = .definition_list,
            .children = try items.toOwnedSlice(self.a),
        };
    }

    fn tryTable(self: *Parser) !?Node {
        const line = self.lines[self.pos];
        if (!isTableRow(line)) return null;

        var raw_rows: std.ArrayList([]const u8) = .{};
        while (self.pos < self.lines.len) {
            const l = self.lines[self.pos];
            if (!isTableRow(l)) break;
            try raw_rows.append(self.a, l);
            self.pos += 1;
        }

        var aligns: std.ArrayList([]const Node.CellAlign) = .{};
        var head_above: std.ArrayList(bool) = .{};
        for (raw_rows.items) |r| {
            if (isTableSep(r)) {
                const parsed = try parseSepAligns(self.a, r);
                try aligns.append(self.a, parsed);
                try head_above.append(self.a, true);
            } else {
                try aligns.append(self.a, &.{});
                try head_above.append(self.a, false);
            }
        }

        var is_head_row: std.ArrayList(bool) = .{};
        for (raw_rows.items, 0..) |_, idx| {
            if (head_above.items[idx]) {
                try is_head_row.append(self.a, false);
            } else {
                const next_is_sep = (idx + 1 < head_above.items.len and head_above.items[idx + 1]);
                try is_head_row.append(self.a, next_is_sep);
            }
        }

        var rows: std.ArrayList(Node) = .{};
        var current_aligns: []const Node.CellAlign = &.{};
        for (raw_rows.items, 0..) |r, idx| {
            if (head_above.items[idx]) {
                current_aligns = aligns.items[idx];
                continue;
            }
            // For header rows, look ahead to get separator alignment
            const effective_aligns = if (is_head_row.items[idx])
                (if (idx + 1 < aligns.items.len) aligns.items[idx + 1] else current_aligns)
            else
                current_aligns;
            const cells = try parseTableRowWithAlign(self.a, r, effective_aligns, is_head_row.items[idx]);
            try rows.append(self.a, .{ .tag = .row, .children = cells });
        }

        // Scan for captions after the table. Multiple captions can appear
        // separated by blank lines; the last one wins (matches djot.js).
        var cap_lines: std.ArrayList([]const u8) = .{};
        while (self.pos < self.lines.len) {
            var look = self.pos;
            while (look < self.lines.len and isBlank(self.lines[look])) : (look += 1) {}
            if (look >= self.lines.len) break;
            const trimmed = std.mem.trimLeft(u8, self.lines[look], " \t");
            if (trimmed.len > 1 and trimmed[0] == '^' and trimmed[1] == ' ') {
                cap_lines.items.len = 0;
                self.pos = look;
                try cap_lines.append(self.a, std.mem.trim(u8, trimmed[2..], " \t"));
                self.pos += 1;
                while (self.pos < self.lines.len) {
                    const l = self.lines[self.pos];
                    if (isBlank(l)) break;
                    if (isTableRow(l)) break;
                    try cap_lines.append(self.a, std.mem.trim(u8, l, " \t"));
                    self.pos += 1;
                }
            } else break;
        }

        var table_children: std.ArrayList(Node) = .{};
        if (cap_lines.items.len > 0) {
            const cap_inlines = try parseInlines(self.a, cap_lines.items);
            try table_children.append(self.a, .{ .tag = .caption, .children = cap_inlines });
        }
        for (rows.items) |r| try table_children.append(self.a, r);

        return .{ .tag = .table, .children = try table_children.toOwnedSlice(self.a) };
    }

    fn registerExplicitIds(self: *Parser, blocks: []const Node) !void {
        for (blocks) |block| {
            if (block.id) |id| {
                try self.ids_used.put(self.a, id, {});
            }
            if (block.children.len > 0) {
                try self.registerExplicitIds(block.children);
            }
        }
    }

    fn wrapSections(self: *Parser, blocks: []const Node) ![]const Node {
        try self.registerExplicitIds(blocks);

        var result: std.ArrayList(Node) = .{};
        var section_stack: std.ArrayList(SectionInfo) = .{};
        defer section_stack.deinit(self.a);

        for (blocks) |block| {
            if (block.tag == .heading) {
                const level = block.level;

                // Close sections with level >= current
                while (section_stack.items.len > 0) {
                    const top = &section_stack.items[section_stack.items.len - 1];
                    if (top.level >= level) {
                        const sec = try self.closeSection(top);
                        _ = section_stack.pop();
                        if (section_stack.items.len > 0) {
                            try section_stack.items[section_stack.items.len - 1].children.append(self.a, sec);
                        } else {
                            try result.append(self.a, sec);
                        }
                    } else break;
                }

                // Generate heading ID
                const heading_text = getNodeText(block);
                const heading_id = block.id orelse try self.generateId(heading_text);

                // Register auto-reference for this heading
                const dest = try std.fmt.allocPrint(self.a, "#{s}", .{heading_id});
                try self.auto_refs.put(self.a, heading_text, dest);

                // Open new section
                var sec_info = SectionInfo{
                    .level = level,
                    .id = heading_id,
                    .attrs = block.attrs,
                    .classes = block.classes,
                };
                // Add the heading node (without section wrapper) as first child
                var heading_node = block;
                heading_node.id = null;
                heading_node.attrs = &.{};
                heading_node.classes = null;
                try sec_info.children.append(self.a, heading_node);

                try section_stack.append(self.a, sec_info);
            } else {
                if (section_stack.items.len > 0) {
                    try section_stack.items[section_stack.items.len - 1].children.append(self.a, block);
                } else {
                    try result.append(self.a, block);
                }
            }
        }

        // Close remaining sections
        while (section_stack.items.len > 0) {
            const top = &section_stack.items[section_stack.items.len - 1];
            const sec = try self.closeSection(top);
            _ = section_stack.pop();
            if (section_stack.items.len > 0) {
                try section_stack.items[section_stack.items.len - 1].children.append(self.a, sec);
            } else {
                try result.append(self.a, sec);
            }
        }

        return result.toOwnedSlice(self.a);
    }

    const SectionInfo = struct {
        level: u8,
        id: []const u8 = "",
        children: std.ArrayList(Node) = .{},
        attrs: []const Attr = &.{},
        classes: ?[]const u8 = null,
    };

    fn addHeadingIds(self: *Parser, blocks: []const Node) ![]const Node {
        var result: std.ArrayList(Node) = .{};
        for (blocks) |block| {
            if (block.tag == .heading and block.id == null) {
                var h = block;
                const text = getNodeText(block);
                h.id = try self.generateId(text);
                try result.append(self.a, h);
            } else {
                try result.append(self.a, block);
            }
        }
        return result.toOwnedSlice(self.a);
    }

    fn closeSection(self: *Parser, info: *SectionInfo) !Node {
        return .{
            .tag = .section,
            .id = info.id,
            .level = info.level,
            .children = try info.children.toOwnedSlice(self.a),
            .attrs = info.attrs,
            .classes = info.classes,
        };
    }

    fn generateId(self: *Parser, text: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        var prev_hyphen = true;
        for (text) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try buf.append(self.a, c);
                prev_hyphen = false;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '-' or c == '_') {
                if (!prev_hyphen and buf.items.len > 0) {
                    try buf.append(self.a, '-');
                    prev_hyphen = true;
                }
            }
        }
        // Trim trailing hyphen
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
            _ = buf.pop();
        }

        var base_id = try buf.toOwnedSlice(self.a);
        if (base_id.len == 0) {
            base_id = try std.fmt.allocPrint(self.a, "s-{d}", .{self.ids_used.count() + 1});
        }

        // Deduplicate
        if (!self.ids_used.contains(base_id)) {
            try self.ids_used.put(self.a, base_id, {});
            return base_id;
        }

        var counter: usize = 1;
        while (true) : (counter += 1) {
            const candidate = try std.fmt.allocPrint(self.a, "{s}-{d}", .{ base_id, counter });
            if (!self.ids_used.contains(candidate)) {
                try self.ids_used.put(self.a, candidate, {});
                return candidate;
            }
        }
    }

    fn resolveReferences(self: *Parser, nodes: []const Node) ![]const Node {
        var result: std.ArrayList(Node) = .{};
        for (nodes) |node| {
            var n = node;
            if ((n.tag == .link or n.tag == .image) and n.destination == null) {
                if (n.reference) |ref| {
                    const raw_label = if (ref.len > 0) ref else (getPlainText(self.a, n) catch "");
                    const label = normalizeLabel(self.a, raw_label) catch raw_label;
                    if (self.ref_defs.get(label)) |def| {
                        n.destination = def.url;
                        if (def.attrs) |ba| {
                            n = mergeRefAttrs(n, ba, self.a);
                        }
                    } else if (self.auto_refs.get(label)) |dest| {
                        n.destination = dest;
                    }
                }
            }
            if (n.tag == .footnote_reference) {
                const label = n.text;
                var found = false;
                for (self.footnote_order.items) |existing| {
                    if (std.mem.eql(u8, existing, label)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.footnote_order.append(self.a, label);
                }
                var fn_num: usize = 0;
                for (self.footnote_order.items, 1..) |existing, idx| {
                    if (std.mem.eql(u8, existing, label)) {
                        fn_num = idx;
                        break;
                    }
                }
                const num_str = try std.fmt.allocPrint(self.a, "{d}", .{fn_num});
                const fn_id = try std.fmt.allocPrint(self.a, "fnref{d}", .{fn_num});
                const href = try std.fmt.allocPrint(self.a, "#fn{d}", .{fn_num});
                n.text = num_str;
                n.id = fn_id;
                n.destination = href;
            }
            if (n.children.len > 0) {
                n.children = try self.resolveReferences(n.children);
            }
            try result.append(self.a, n);
        }
        return result.toOwnedSlice(self.a);
    }

    fn buildFootnoteSection(self: *Parser) !Node {
        var items: std.ArrayList(Node) = .{};
        var fn_idx: usize = 0;
        while (fn_idx < self.footnote_order.items.len) : (fn_idx += 1) {
            const label = self.footnote_order.items[fn_idx];
            const raw_content = self.footnote_defs.get(label) orelse &.{};
            const content = try self.resolveReferences(raw_content);
            const idx = items.items.len + 1;
            const fn_id = try std.fmt.allocPrint(self.a, "fn{d}", .{idx});
            const backref = try std.fmt.allocPrint(self.a, "#fnref{d}", .{idx});
            var fn_children: std.ArrayList(Node) = .{};
            const backlink = Node{
                .tag = .link,
                .destination = backref,
                .text = "\u{21a9}\u{fe0e}",
                .attrs = &.{.{ .key = "role", .value = "doc-backlink" }},
            };
            for (content, 0..) |block, i| {
                if (i == content.len - 1 and block.tag == .para) {
                    var new_kids: std.ArrayList(Node) = .{};
                    for (block.children) |c| try new_kids.append(self.a, c);
                    try new_kids.append(self.a, backlink);
                    try fn_children.append(self.a, .{
                        .tag = .para,
                        .children = try new_kids.toOwnedSlice(self.a),
                    });
                } else {
                    try fn_children.append(self.a, block);
                }
            }
            if (content.len == 0 or content[content.len - 1].tag != .para) {
                try fn_children.append(self.a, .{
                    .tag = .para,
                    .children = try self.a.dupe(Node, &.{backlink}),
                });
            }
            try items.append(self.a, .{
                .tag = .list_item,
                .id = fn_id,
                .children = try fn_children.toOwnedSlice(self.a),
            });
        }

        return .{
            .tag = .footnote,
            .children = try items.toOwnedSlice(self.a),
            .attrs = &.{.{ .key = "role", .value = "doc-endnotes" }},
        };
    }
};

// ============================================================
// Inline Parser
// ============================================================

fn parseInlines(a: Allocator, lines: []const []const u8) ![]const Node {
    if (lines.len == 0) return &.{};
    const src = try joinLines(a, lines);
    return parseInlineContent(a, src);
}

const InlineItem = union(enum) {
    node: Node,
    opener: OpenerInfo,
    pending_attrs: BlockAttrs,
};

const OpenerInfo = struct {
    char: u8,
    item_idx: usize,
    src_pos: usize,
    marked: bool = false,
};

fn parseInlineContent(a: Allocator, src: []const u8) anyerror![]const Node {
    var items: std.ArrayList(InlineItem) = .{};
    var openers: std.ArrayList(OpenerInfo) = .{};
    var pos: usize = 0;
    var text_start: usize = 0;

    while (pos < src.len) {
        const c = src[pos];
        switch (c) {
            '\\' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 >= src.len) {
                    try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                    pos += 1;
                } else {
                    const next = src[pos + 1];
                    if (next == '\n') {
                        stripTrailingSpacesFromLastStr(&items);
                        try items.append(a, .{ .node = .{ .tag = .hard_break } });
                        pos += 2;
                    } else if (next == ' ' or next == '\t') {
                        var skip = pos + 1;
                        while (skip < src.len and (src[skip] == ' ' or src[skip] == '\t')) skip += 1;
                        if (skip < src.len and src[skip] == '\n') {
                            stripTrailingSpacesFromLastStr(&items);
                            try items.append(a, .{ .node = .{ .tag = .hard_break } });
                            pos = skip + 1;
                        } else if (next == ' ') {
                            try items.append(a, .{ .node = .{ .tag = .non_breaking_space } });
                            pos += 2;
                        } else {
                            try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                            pos += 1;
                        }
                    } else if (isEscapable(next)) {
                        try items.append(a, .{ .node = .{ .tag = .str, .text = src[pos + 1 .. pos + 2] } });
                        pos += 2;
                    } else {
                        try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                        pos += 1;
                    }
                }
                text_start = pos;
            },
            '`' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                const tick_len = countRunAt(src, pos, '`');
                const after = pos + tick_len;
                if (findClosingTicks(src, after, tick_len)) |close_pos| {
                    const raw = src[after..close_pos];
                    const content = trimVerbatimContent(raw);
                    const after_close = close_pos + tick_len;
                    if (after_close < src.len and src[after_close] == '{' and
                        after_close + 1 < src.len and src[after_close + 1] == '=')
                    {
                        const fmt_end = std.mem.indexOfScalarPos(u8, src, after_close, '}');
                        if (fmt_end) |fe| {
                            const format = src[after_close + 2 .. fe];
                            if (format.len > 0 and std.mem.indexOfScalar(u8, format, ' ') == null) {
                                try items.append(a, .{ .node = .{ .tag = .raw_inline, .text = content, .lang = format } });
                                pos = fe + 1;
                            } else {
                                try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                                pos = after_close;
                            }
                        } else {
                            try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                            pos = after_close;
                        }
                    } else {
                        try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                        pos = after_close;
                    }
                } else {
                    // Unclosed verbatim: implicitly close at end of content
                    const content = trimVerbatimContent(src[after..]);
                    try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                    pos = src.len;
                }
                text_start = pos;
            },
            '\n' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try items.append(a, .{ .node = .{ .tag = .soft_break } });
                pos += 1;
                text_start = pos;
            },
            '*', '_' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleEmphDelimiter(a, &items, &openers, src, &pos, c, false);
                text_start = pos;
            },
            '{' => {
                // Check for marked opener {_ or {* or {+ {- {= or attribute
                if (pos + 1 < src.len) {
                    const next = src[pos + 1];
                    if (next == '_' or next == '*') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        pos += 1;
                        try handleEmphDelimiter(a, &items, &openers, src, &pos, next, true);
                        text_start = pos;
                        continue;
                    } else if (next == '+' or next == '-' or next == '=') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        try handleBracedSpan(a, &items, &openers, src, &pos);
                        text_start = pos;
                        continue;
                    } else if (next == '~' or next == '^') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        try handleBracedSpan(a, &items, &openers, src, &pos);
                        text_start = pos;
                        continue;
                    } else if (next == '\'' or next == '"') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        pos += 1;
                        try handleSmartQuote(a, &items, &openers, src, &pos, next, true);
                        text_start = pos;
                        continue;
                    }
                }
                // Try inline attributes: word{.class} or standalone {.class}
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (parseInlineAttrs(a, src, pos)) |parsed| {
                    try applyInlineAttrs(a, &items, parsed.attrs);
                    pos = parsed.end;
                } else {
                    try addTextItem(a, &items, "{");
                    pos += 1;
                }
                text_start = pos;
            },
            '[' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                // Check for footnote reference [^label]
                if (pos + 1 < src.len and src[pos + 1] == '^') {
                    if (findMatchingBracket(src, pos)) |close| {
                        const label = src[pos + 2 .. close];
                        try items.append(a, .{ .node = .{
                            .tag = .footnote_reference,
                            .text = label,
                        } });
                        pos = close + 1;
                        text_start = pos;
                        continue;
                    }
                }
                try openers.append(a, .{
                    .char = '[',
                    .item_idx = items.items.len,
                    .src_pos = pos,
                });
                try items.append(a, .{ .node = .{ .tag = .str, .text = "[" } });
                pos += 1;
                text_start = pos;
            },
            '!' => {
                if (pos + 1 < src.len and src[pos + 1] == '[') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    try openers.append(a, .{
                        .char = '!',
                        .item_idx = items.items.len,
                        .src_pos = pos,
                    });
                    try items.append(a, .{ .node = .{ .tag = .str, .text = "![" } });
                    pos += 2;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            ']' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleCloseBracket(a, &items, &openers, src, &pos);
                text_start = pos;
            },
            '<' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (try handleAutolink(a, &items, src, &pos)) {
                    text_start = pos;
                } else {
                    try addTextItem(a, &items, "<");
                    pos += 1;
                    text_start = pos;
                }
            },
            '^' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (try handleBracedClose(a, &items, &openers, '^', pos)) {
                        pos += 2;
                        text_start = pos;
                        continue;
                    }
                }
                try handleSuperSubscript(a, &items, &openers, src, &pos, '^', .superscript);
                text_start = pos;
            },
            '~' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (try handleBracedClose(a, &items, &openers, '~', pos)) {
                        pos += 2;
                        text_start = pos;
                        continue;
                    }
                }
                try handleSuperSubscript(a, &items, &openers, src, &pos, '~', .subscript);
                text_start = pos;
            },
            '$' => {
                // Math: $`code` or $$`code`
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                var dollar_count: usize = 1;
                if (pos + 1 < src.len and src[pos + 1] == '$') dollar_count = 2;
                const tick_start = pos + dollar_count;
                if (tick_start < src.len and src[tick_start] == '`') {
                    const tick_len = countRunAt(src, tick_start, '`');
                    const content_start = tick_start + tick_len;
                    if (findClosingTicks(src, content_start, tick_len)) |close_pos| {
                        const content = src[content_start..close_pos];
                        const tag: Tag = if (dollar_count == 2) .display_math else .inline_math;
                        try items.append(a, .{ .node = .{ .tag = tag, .text = content } });
                        pos = close_pos + tick_len;
                        text_start = pos;
                        continue;
                    }
                }
                try addTextItem(a, &items, src[pos .. pos + dollar_count]);
                pos += dollar_count;
                text_start = pos;
            },
            ':' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (handleSymbol(a, &items, src, &pos)) {
                    text_start = pos;
                } else {
                    pos += 1;
                    text_start = pos - 1; // include `:` in next text run
                }
            },
            '"' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleSmartQuote(a, &items, &openers, src, &pos, '"', false);
                text_start = pos;
            },
            '\'' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleSmartQuote(a, &items, &openers, src, &pos, '\'', false);
                text_start = pos;
            },
            '-', '+', '=' => {
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    if (try handleBracedClose(a, &items, &openers, c, pos)) {
                        pos += 2;
                    } else {
                        try addTextItem(a, &items, src[pos .. pos + 2]);
                        pos += 2;
                    }
                    text_start = pos;
                } else if (c == '-' and pos + 1 < src.len and src[pos + 1] == '-') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    var dash_count: usize = 0;
                    var dp = pos;
                    while (dp < src.len and src[dp] == '-') : (dp += 1) dash_count += 1;
                    // If the dash sequence ends right before '}', reserve one dash
                    // for a potential braced span closer (-})
                    if (dp < src.len and src[dp] == '}' and dash_count >= 2) {
                        dash_count -= 1;
                        dp -= 1;
                    }
                    try emitDashes(a, &items, dash_count);
                    pos = dp;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            '.' => {
                if (pos + 2 < src.len and src[pos + 1] == '.' and src[pos + 2] == '.') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    try items.append(a, .{ .node = .{ .tag = .ellipsis } });
                    pos += 3;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            else => {
                pos += 1;
            },
        }
    }

    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);

    // Trim trailing whitespace from last str
    trimTrailingWhitespace(&items);

    return resolveItems(a, items.items);
}

fn stripTrailingSpacesFromLastStr(items: *std.ArrayList(InlineItem)) void {
    if (items.items.len == 0) return;
    switch (items.items[items.items.len - 1]) {
        .node => |*n| {
            if (n.tag == .str) {
                n.text = std.mem.trimRight(u8, n.text, " \t");
                if (n.text.len == 0) _ = items.pop();
            }
        },
        else => {},
    }
}

fn handleBracedClose(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    char: u8,
    _: usize,
) !bool {
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == char and op.marked) {
            if (op.item_idx + 1 < items.items.len) {
                const tag: Tag = switch (char) {
                    '-' => .delete,
                    '+' => .insert,
                    '=' => .mark,
                    '~' => .subscript,
                    '^' => .superscript,
                    else => .span,
                };
                const children = try collectChildren(a, items, op.item_idx);
                try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                openers.items.len = i;
                return true;
            }
        }
    }
    return false;
}

fn applyInlineAttrs(a: Allocator, items: *std.ArrayList(InlineItem), attrs: BlockAttrs) !void {
    if (attrs.id == null and attrs.classes == null and attrs.attrs.len == 0) return;
    try items.append(a, .{ .pending_attrs = attrs });
}

fn addTextItem(a: Allocator, items: *std.ArrayList(InlineItem), text: []const u8) !void {
    // Merge with previous text node if possible
    if (items.items.len > 0) {
        switch (items.items[items.items.len - 1]) {
            .node => |*n| {
                if (n.tag == .str) {
                    if (n.text.ptr + n.text.len == text.ptr) {
                        n.text = n.text.ptr[0 .. n.text.len + text.len];
                        return;
                    }
                }
            },
            else => {},
        }
    }
    try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
}

fn trimTrailingWhitespace(items: *std.ArrayList(InlineItem)) void {
    while (items.items.len > 0) {
        switch (items.items[items.items.len - 1]) {
            .node => |*n| {
                if (n.tag == .str) {
                    n.text = std.mem.trimRight(u8, n.text, " \t");
                    if (n.text.len == 0) {
                        _ = items.pop();
                        continue;
                    }
                }
                break;
            },
            else => break,
        }
    }
}

fn handleEmphDelimiter(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    src: []const u8,
    pos: *usize,
    char: u8,
    marked: bool,
) !void {
    const p = pos.*;

    // Check for marked closer: _} or *}
    if (!marked and p + 1 < src.len and src[p + 1] == '}') {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '*') .strong else .emph;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 2;
                    return;
                }
            }
        }
        // _} with no matching {_ opener → treat both as text
        try addTextItem(a, items, src[p .. p + 2]);
        pos.* = p + 2;
        return;
    }

    // Regular close: only match the most recent opener of the same type
    const can_close = canCloseDelim(src, p) and !marked;
    if (can_close) {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked == marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '*') .strong else .emph;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 1;
                    return;
                }
                break;
            }
        }
    }

    // Open (marked openers always open regardless of surrounding chars)
    const can_open = marked or canOpenDelim(src, p);
    if (can_open) {
        const idx = items.items.len;
        try openers.append(a, .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
            .marked = marked,
        });
        try items.append(a, .{ .opener = .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
            .marked = marked,
        } });
        pos.* = p + 1;
        return;
    }

    // Treat as text
    try addTextItem(a, items, src[p .. p + 1]);
    pos.* = p + 1;
}

fn handleBracedSpan(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    src: []const u8,
    pos: *usize,
) !void {
    const p = pos.*;
    const delim = src[p + 1];
    const idx = items.items.len;
    try openers.append(a, .{
        .char = delim,
        .item_idx = idx,
        .src_pos = p,
        .marked = true,
    });
    try items.append(a, .{ .opener = .{
        .char = delim,
        .item_idx = idx,
        .src_pos = p,
        .marked = true,
    } });
    pos.* = p + 2;
}

fn handleCloseBracket(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    src: []const u8,
    pos: *usize,
) !void {
    const p = pos.*;

    // Check for braced span closers: +} -} =}
    if (p + 1 < src.len and src[p + 1] == '}') {
        // Not a bracket closer, skip
    }

    // Look for [ or ! opener
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == '[' or op.char == '!') {
            // Found bracket opener
            const children = try collectChildren(a, items, op.item_idx);
            const is_image = op.char == '!';
            pos.* = p + 1;

            // Check what follows: (url), [ref], {attrs}, or nothing
            if (pos.* < src.len and src[pos.*] == '(') {
                // Inline link/image
                if (findMatchingParen(src, pos.*)) |close_paren| {
                    const raw_dest = src[pos.* + 1 .. close_paren];
                    const dest = processUrl(a, raw_dest) catch raw_dest;
                    if (is_image) {
                        try items.append(a, .{ .node = .{
                            .tag = .image,
                            .children = children,
                            .destination = dest,
                        } });
                    } else {
                        try items.append(a, .{ .node = .{
                            .tag = .link,
                            .children = children,
                            .destination = dest,
                        } });
                    }
                    pos.* = close_paren + 1;
                    openers.items.len = i;
                    return;
                }
            } else if (pos.* < src.len and src[pos.*] == '[') {
                // Reference link
                if (findMatchingBracket(src, pos.*)) |close_ref| {
                    const ref_label = src[pos.* + 1 .. close_ref];
                    if (is_image) {
                        try items.append(a, .{ .node = .{
                            .tag = .image,
                            .children = children,
                            .reference = ref_label,
                        } });
                    } else {
                        try items.append(a, .{ .node = .{
                            .tag = .link,
                            .children = children,
                            .reference = ref_label,
                        } });
                    }
                    pos.* = close_ref + 1;
                    openers.items.len = i;
                    return;
                }
            } else if (pos.* < src.len and src[pos.*] == '{') {
                // Span with attributes: [text]{.class}
                if (parseInlineAttrs(a, src, pos.*)) |parsed| {
                    var span_node = Node{
                        .tag = .span,
                        .children = children,
                    };
                    span_node = applyBlockAttrs(span_node, parsed.attrs);
                    try items.append(a, .{ .node = span_node });
                    pos.* = parsed.end;
                    openers.items.len = i;
                    return;
                }
            }

            // No valid link/ref/attr follows - treat as text
            // Put back the bracket text and children
            var restored: std.ArrayList(InlineItem) = .{};
            const bracket_text: []const u8 = if (is_image) "![" else "[";
            try restored.append(a, .{ .node = .{ .tag = .str, .text = bracket_text } });
            for (children) |child| try restored.append(a, .{ .node = child });
            try restored.append(a, .{ .node = .{ .tag = .str, .text = "]" } });

            // Replace items from op.item_idx to end with restored
            items.items.len = op.item_idx;
            for (restored.items) |item| try items.append(a, item);
            openers.items.len = i;
            return;
        }
    }

    // No matching opener
    try addTextItem(a, items, "]");
    pos.* = p + 1;
}

fn handleAutolink(a: Allocator, items: *std.ArrayList(InlineItem), src: []const u8, pos: *usize) !bool {
    const p = pos.*;
    const rest = src[p + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
    const content = rest[0..close];

    if (std.mem.startsWith(u8, content, "http://") or
        std.mem.startsWith(u8, content, "https://") or
        std.mem.startsWith(u8, content, "ftp://"))
    {
        try items.append(a, .{ .node = .{ .tag = .url, .text = content } });
        pos.* = p + 1 + close + 1;
        return true;
    }

    if (std.mem.indexOfScalar(u8, content, '@') != null and
        std.mem.indexOfScalar(u8, content, ' ') == null)
    {
        try items.append(a, .{ .node = .{ .tag = .email, .text = content } });
        pos.* = p + 1 + close + 1;
        return true;
    }

    return false;
}

fn handleSuperSubscript(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    src: []const u8,
    pos: *usize,
    char: u8,
    tag: Tag,
) !void {
    const p = pos.*;

    // Try to close first
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == char) {
            if (op.item_idx + 1 < items.items.len) {
                const children = try collectChildren(a, items, op.item_idx);
                try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                openers.items.len = i;
                pos.* = p + 1;
                return;
            }
        }
    }

    // Try to open
    if (canOpenDelim(src, p)) {
        const idx = items.items.len;
        try openers.append(a, .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
        });
        try items.append(a, .{ .opener = .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
        } });
        pos.* = p + 1;
        return;
    }

    try addTextItem(a, items, src[p .. p + 1]);
    pos.* = p + 1;
}

// Math is handled inline via $` and $$` backtick verbatim syntax

fn handleSymbol(a: Allocator, items: *std.ArrayList(InlineItem), src: []const u8, pos: *usize) bool {
    const p = pos.*;
    const start = p + 1;
    if (start >= src.len) return false;
    const end = std.mem.indexOfScalarPos(u8, src, start, ':') orelse return false;
    if (end == start) return false;
    const name = src[start..end];
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '+') return false;
    }
    items.append(a, .{ .node = .{ .tag = .symb, .text = name } }) catch return false;
    pos.* = end + 1;
    return true;
}

fn emitDashes(a: Allocator, items: *std.ArrayList(InlineItem), count: usize) !void {
    if (count <= 1) {
        if (count == 1) try addTextItem(a, items, "-");
        return;
    }
    const all_em = count % 3 == 0;
    const all_en = count % 2 == 0;
    var remaining = count;
    while (remaining > 0) {
        if (all_em) {
            try items.append(a, .{ .node = .{ .tag = .em_dash } });
            remaining -= 3;
        } else if (all_en) {
            try items.append(a, .{ .node = .{ .tag = .en_dash } });
            remaining -= 2;
        } else if (remaining >= 3 and (remaining % 2 != 0 or remaining > 4)) {
            try items.append(a, .{ .node = .{ .tag = .em_dash } });
            remaining -= 3;
        } else if (remaining >= 2) {
            try items.append(a, .{ .node = .{ .tag = .en_dash } });
            remaining -= 2;
        } else {
            try addTextItem(a, items, "-");
            remaining -= 1;
        }
    }
}

fn canOpenSingleQuote(src: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = src[pos - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r' or
        prev == '"' or prev == '\'' or prev == '-' or prev == '(' or prev == '[';
}

fn handleSmartQuote(
    a: Allocator,
    items: *std.ArrayList(InlineItem),
    openers: *std.ArrayList(OpenerInfo),
    src: []const u8,
    pos: *usize,
    char: u8,
    marked: bool,
) !void {
    const p = pos.*;

    // Check for marked closer: '} or "}
    if (!marked and p + 1 < src.len and src[p + 1] == '}') {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 2;
                    return;
                }
                break;
            }
        }
        // '} with no matching {' or empty content → emit closing quote, consume }
        const text: []const u8 = if (char == '\'') "\u{2019}" else "\u{201d}";
        try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
        pos.* = p + 2;
        return;
    }

    const can_close = !marked and p > 0 and src[p - 1] != ' ' and src[p - 1] != '\t' and
        src[p - 1] != '\n' and src[p - 1] != '\r';
    const can_open = if (marked)
        true
    else if (p + 1 < src.len and src[p + 1] != ' ' and src[p + 1] != '\t' and
        src[p + 1] != '\n' and src[p + 1] != '\r')
        (if (char == '\'') canOpenSingleQuote(src, p) else true)
    else
        false;

    if (can_close) {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and !op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 1;
                    return;
                }
                break;
            }
        }
    }

    if (can_open) {
        const idx = items.items.len;
        try openers.append(a, .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
            .marked = marked,
        });
        try items.append(a, .{ .opener = .{
            .char = char,
            .item_idx = idx,
            .src_pos = p,
            .marked = marked,
        } });
    } else {
        const text: []const u8 = if (char == '\'') "\u{2019}" else "\u{201c}";
        try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
    }
    pos.* = p + 1;
}

fn collectChildren(a: Allocator, items: *std.ArrayList(InlineItem), opener_idx: usize) ![]const Node {
    var children: std.ArrayList(Node) = .{};
    for (items.items[opener_idx + 1 ..]) |item| {
        switch (item) {
            .node => |n| try children.append(a, n),
            .opener => |op| {
                const text = try openerText(a, op);
                try children.append(a, .{ .tag = .str, .text = text });
            },
            .pending_attrs => |attrs| {
                try applyAttrsToResolved(a, &children, attrs);
            },
        }
    }
    items.items.len = opener_idx;
    return children.toOwnedSlice(a);
}

const single_char_strings = blk: {
    var strs: [256][]const u8 = undefined;
    for (0..256) |i| strs[i] = &[_]u8{@intCast(i)};
    break :blk strs;
};

fn openerText(_: Allocator, op: OpenerInfo) ![]const u8 {
    if (op.marked) return switch (op.char) {
        '-' => "{-",
        '+' => "{+",
        '=' => "{=",
        '*' => "{*",
        '_' => "{_",
        '~' => "{~",
        '^' => "{^",
        '\'' => "\u{2018}",
        '"' => "\u{201c}",
        else => single_char_strings[op.char],
    };
    return switch (op.char) {
        '!' => "![",
        '"' => "\u{201c}",
        '\'' => "\u{2019}",
        else => single_char_strings[op.char],
    };
}

fn resolveItems(a: Allocator, items: []const InlineItem) ![]const Node {
    var nodes: std.ArrayList(Node) = .{};
    for (items) |item| {
        switch (item) {
            .node => |n| try nodes.append(a, n),
            .opener => |op| {
                const text = try openerText(a, op);
                try nodes.append(a, .{ .tag = .str, .text = text });
            },
            .pending_attrs => |attrs| {
                try applyAttrsToResolved(a, &nodes, attrs);
            },
        }
    }
    return nodes.toOwnedSlice(a);
}

/// Apply inline attributes to the last resolved node. Openers have already
/// been converted to text nodes at this point, so "last word" extraction
/// gathers backwards across consecutive str nodes to capture unmatched
/// delimiters that became text (e.g. `*` before `b` in `*b{attrs}`).
fn applyAttrsToResolved(a: Allocator, nodes: *std.ArrayList(Node), attrs: BlockAttrs) !void {
    if (nodes.items.len == 0) return;
    const last = &nodes.items[nodes.items.len - 1];
    switch (last.tag) {
        .str => {
            const text = last.text;
            if (text.len == 0) return;
            var word_start = text.len;
            while (word_start > 0 and text[word_start - 1] != ' ' and
                text[word_start - 1] != '\t' and text[word_start - 1] != '\n')
            {
                word_start -= 1;
            }
            if (word_start == text.len) return;

            // When the entire str is the word, look back for more str nodes
            // that are part of the same unbroken run (no whitespace)
            var gather_start = nodes.items.len - 1;
            if (word_start == 0) {
                while (gather_start > 0) {
                    const prev = nodes.items[gather_start - 1];
                    if (prev.tag != .str) break;
                    const pt = prev.text;
                    if (pt.len == 0) break;
                    const last_ch = pt[pt.len - 1];
                    if (last_ch == ' ' or last_ch == '\t' or last_ch == '\n') break;
                    gather_start -= 1;
                    // Check if only a suffix of this str is non-whitespace
                    var ws = pt.len;
                    while (ws > 0 and pt[ws - 1] != ' ' and pt[ws - 1] != '\t' and pt[ws - 1] != '\n') {
                        ws -= 1;
                    }
                    if (ws > 0) {
                        // Partial: this str has whitespace, so the word starts mid-node
                        word_start = ws;
                        break;
                    }
                }
            }

            var span_children: std.ArrayList(Node) = .{};
            if (gather_start < nodes.items.len - 1 or word_start > 0) {
                // Partial first node
                if (word_start > 0) {
                    const first_text = nodes.items[gather_start].text;
                    try span_children.append(a, .{ .tag = .str, .text = first_text[word_start..] });
                    for (nodes.items[gather_start + 1 ..]) |n| try span_children.append(a, n);
                } else {
                    for (nodes.items[gather_start..]) |n| try span_children.append(a, n);
                }
            } else {
                try span_children.append(a, .{ .tag = .str, .text = text[word_start..] });
            }

            var span_node = Node{
                .tag = .span,
                .children = try span_children.toOwnedSlice(a),
            };
            span_node = applyBlockAttrs(span_node, attrs);

            if (word_start > 0 and gather_start < nodes.items.len - 1) {
                nodes.items[gather_start].text = nodes.items[gather_start].text[0..word_start];
                nodes.items.len = gather_start + 1;
                try nodes.append(a, span_node);
            } else if (word_start > 0) {
                last.text = text[0..word_start];
                try nodes.append(a, span_node);
            } else {
                nodes.items.len = gather_start;
                try nodes.append(a, span_node);
            }
        },
        .span, .link, .image, .emph, .strong, .verbatim, .mark,
        .superscript, .subscript, .insert, .delete,
        .double_quoted, .single_quoted,
        => {
            nodes.items[nodes.items.len - 1] = applyBlockAttrs(last.*, attrs);
        },
        else => {},
    }
}

fn canOpenDelim(src: []const u8, pos: usize) bool {
    if (pos + 1 >= src.len) return false;
    const next = src[pos + 1];
    if (next == ' ' or next == '\t' or next == '\n' or next == '\r') return false;
    return true;
}

fn canCloseDelim(src: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    const prev = src[pos - 1];
    if (prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r') return false;
    return true;
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '"', '\'', '~', '^', ':', '<', '>', '$', '%', '=' => true,
        else => false,
    };
}

fn countRunAt(src: []const u8, pos: usize, char: u8) usize {
    var count: usize = 0;
    var i = pos;
    while (i < src.len and src[i] == char) : (i += 1) count += 1;
    return count;
}

fn findClosingTicks(src: []const u8, start: usize, count: usize) ?usize {
    var i = start;
    while (i < src.len) {
        if (src[i] == '`') {
            const run = countRunAt(src, i, '`');
            if (run == count) return i;
            i += run;
        } else {
            i += 1;
        }
    }
    return null;
}

fn trimVerbatimContent(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;
    if (raw.len >= 2 and raw[0] == ' ' and raw[1] == '`') start = 1;
    if (end > start + 1 and raw[end - 1] == ' ' and raw[end - 2] == '`') end -= 1;
    return raw[start..end];
}

fn findMatchingParen(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '(') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '(') depth += 1;
        if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingBracket(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '[') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '[') depth += 1;
        if (src[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn processUrl(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_processing = std.mem.indexOfScalar(u8, raw, '\n') != null or
        std.mem.indexOfScalar(u8, raw, '\\') != null;
    if (!needs_processing) return raw;
    var buf: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\n') {
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        } else if (raw[i] == '\\' and i + 1 < raw.len and isEscapable(raw[i + 1])) {
            try buf.append(a, raw[i + 1]);
            i += 2;
        } else {
            try buf.append(a, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}

fn normalizeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_normalization = for (raw) |c| {
        if (c == '\n' or c == '\r' or c == '\t') break true;
    } else false;
    if (!needs_normalization) return raw;
    var buf: std.ArrayList(u8) = .{};
    var in_ws = false;
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws and buf.items.len > 0) {
                try buf.append(a, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(a, c);
            in_ws = false;
        }
    }
    const items = buf.items;
    if (items.len > 0 and items[items.len - 1] == ' ') {
        buf.items.len -= 1;
    }
    return buf.toOwnedSlice(a);
}

fn getPlainText(a: Allocator, node: Node) ![]const u8 {
    if (node.text.len > 0) return node.text;
    var buf: std.ArrayList(u8) = .{};
    for (node.children) |child| {
        switch (child.tag) {
            .str => try buf.appendSlice(a, child.text),
            .soft_break => try buf.append(a, ' '),
            else => {
                if (child.children.len > 0) {
                    const sub = try getPlainText(a, child);
                    try buf.appendSlice(a, sub);
                }
            },
        }
    }
    return buf.toOwnedSlice(a);
}

// ============================================================
// HTML Renderer
// ============================================================

fn renderNode(a: Allocator, out: *std.ArrayList(u8), node: Node) anyerror!void {
    switch (node.tag) {
        .section => {
            if (node.level > 0) {
                try out.appendSlice(a, "<section");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try renderNode(a, out, child);
                try out.appendSlice(a, "</section>\n");
            } else {
                for (node.children) |child| try renderNode(a, out, child);
            }
        },
        .para => {
            try out.appendSlice(a, "<p");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</p>\n");
        },
        .heading => {
            const tag = switch (node.level) {
                1 => "h1",
                2 => "h2",
                3 => "h3",
                4 => "h4",
                5 => "h5",
                else => "h6",
            };
            try out.appendSlice(a, "<");
            try out.appendSlice(a, tag);
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</");
            try out.appendSlice(a, tag);
            try out.appendSlice(a, ">\n");
        },
        .thematic_break => {
            try out.appendSlice(a, "<hr");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
        },
        .code_block => {
            try out.appendSlice(a, "<pre");
            // Attrs go on pre
            try renderFilteredAttrs(a, out, node, true);
            try out.appendSlice(a, "><code");
            if (node.lang) |lang| {
                try out.appendSlice(a, " class=\"language-");
                try appendAttrEscaped(a, out, lang);
                try out.appendSlice(a, "\"");
            }
            try out.appendSlice(a, ">");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</code></pre>\n");
        },
        .block_quote => {
            try out.appendSlice(a, "<blockquote");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</blockquote>\n");
        },
        .div => {
            try out.appendSlice(a, "<div");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</div>\n");
        },
        .bullet_list => {
            try out.appendSlice(a, "<ul");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderListItem(a, out, child, node.tight);
            try out.appendSlice(a, "</ul>\n");
        },
        .ordered_list => {
            try out.appendSlice(a, "<ol");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderListItem(a, out, child, node.tight);
            try out.appendSlice(a, "</ol>\n");
        },
        .task_list => {
            try out.appendSlice(a, "<ul class=\"task-list\"");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderListItem(a, out, child, node.tight);
            try out.appendSlice(a, "</ul>\n");
        },
        .list_item => {
            try out.appendSlice(a, "<li");
            if (node.id) |id| {
                try out.appendSlice(a, " id=\"");
                try appendAttrEscaped(a, out, id);
                try out.appendSlice(a, "\"");
            }
            try out.appendSlice(a, ">\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</li>\n");
        },
        .task_list_item => {
            try out.appendSlice(a, "<li>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</li>\n");
        },
        .definition_list => {
            try out.appendSlice(a, "<dl>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</dl>\n");
        },
        .definition_list_item => {
            for (node.children) |child| try renderNode(a, out, child);
        },
        .term => {
            try out.appendSlice(a, "<dt>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</dt>\n");
        },
        .definition => {
            try out.appendSlice(a, "<dd>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</dd>\n");
        },
        .table => {
            try out.appendSlice(a, "<table>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</table>\n");
        },
        .caption => {
            try out.appendSlice(a, "<caption>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</caption>\n");
        },
        .row => {
            try out.appendSlice(a, "<tr>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</tr>\n");
        },
        .cell => {
            const cell_tag: []const u8 = if (node.head) "th" else "td";
            try out.appendSlice(a, "<");
            try out.appendSlice(a, cell_tag);
            if (node.cell_align != .default) {
                try out.appendSlice(a, " style=\"text-align: ");
                try out.appendSlice(a, @tagName(node.cell_align));
                try out.appendSlice(a, ";\"");
            }
            try out.appendSlice(a, ">");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</");
            try out.appendSlice(a, cell_tag);
            try out.appendSlice(a, ">\n");
        },
        .footnote => {
            try out.appendSlice(a, "<section role=\"doc-endnotes\">\n<hr>\n<ol>\n");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</ol>\n</section>\n");
        },
        .str => {
            try appendEscaped(a, out, node.text);
        },
        .soft_break => {
            try out.append(a, '\n');
        },
        .hard_break => {
            try out.appendSlice(a, "<br>\n");
        },
        .emph => {
            try out.appendSlice(a, "<em>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</em>");
        },
        .strong => {
            try out.appendSlice(a, "<strong>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</strong>");
        },
        .verbatim => {
            try out.appendSlice(a, "<code>");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</code>");
        },
        .link => {
            try out.appendSlice(a, "<a");
            if (node.destination) |dest| {
                try out.appendSlice(a, " href=\"");
                try appendAttrEscaped(a, out, dest);
                try out.appendSlice(a, "\"");
            }
            for (node.attrs) |attr| {
                try out.append(a, ' ');
                try out.appendSlice(a, attr.key);
                try out.appendSlice(a, "=\"");
                try appendAttrEscaped(a, out, attr.value);
                try out.appendSlice(a, "\"");
            }
            try out.appendSlice(a, ">");
            if (node.children.len > 0) {
                for (node.children) |child| try renderNode(a, out, child);
            } else {
                try appendEscaped(a, out, node.text);
            }
            try out.appendSlice(a, "</a>");
        },
        .image => {
            try out.appendSlice(a, "<img");
            try out.appendSlice(a, " alt=\"");
            try collectAltText(a, out, node.children);
            try out.appendSlice(a, "\"");
            if (node.destination) |dest| {
                try out.appendSlice(a, " src=\"");
                try appendAttrEscaped(a, out, dest);
                try out.appendSlice(a, "\"");
            }
            try out.appendSlice(a, ">");
        },
        .span => {
            try out.appendSlice(a, "<span");
            try renderAttrs(a, out, node);
            try out.appendSlice(a, ">");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</span>");
        },
        .footnote_reference => {
            try out.appendSlice(a, "<a");
            if (node.id) |fn_id| {
                try out.appendSlice(a, " id=\"");
                try appendAttrEscaped(a, out, fn_id);
                try out.appendSlice(a, "\"");
            }
            if (node.destination) |dest| {
                try out.appendSlice(a, " href=\"");
                try appendAttrEscaped(a, out, dest);
                try out.appendSlice(a, "\"");
            }
            try out.appendSlice(a, " role=\"doc-noteref\"><sup>");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</sup></a>");
        },
        .superscript => {
            try out.appendSlice(a, "<sup>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</sup>");
        },
        .subscript => {
            try out.appendSlice(a, "<sub>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</sub>");
        },
        .insert => {
            try out.appendSlice(a, "<ins>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</ins>");
        },
        .delete => {
            try out.appendSlice(a, "<del>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</del>");
        },
        .mark => {
            try out.appendSlice(a, "<mark>");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "</mark>");
        },
        .inline_math => {
            try out.appendSlice(a, "<span class=\"math inline\">\\(");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "\\)</span>");
        },
        .display_math => {
            try out.appendSlice(a, "<span class=\"math display\">\\[");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "\\]</span>");
        },
        .url => {
            try out.appendSlice(a, "<a href=\"");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "\">");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</a>");
        },
        .email => {
            try out.appendSlice(a, "<a href=\"mailto:");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "\">");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</a>");
        },
        .symb => {
            try out.appendSlice(a, "<span class=\"symbol\">");
            try appendEscaped(a, out, node.text);
            try out.appendSlice(a, "</span>");
        },
        .double_quoted => {
            try out.appendSlice(a, "\u{201c}");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "\u{201d}");
        },
        .single_quoted => {
            try out.appendSlice(a, "\u{2018}");
            for (node.children) |child| try renderNode(a, out, child);
            try out.appendSlice(a, "\u{2019}");
        },
        .escape => try appendEscaped(a, out, node.text),
        .non_breaking_space => try out.appendSlice(a, "&nbsp;"),
        .left_single_quote => try out.appendSlice(a, "\u{2018}"),
        .right_single_quote => try out.appendSlice(a, "\u{2019}"),
        .left_double_quote => try out.appendSlice(a, "\u{201c}"),
        .right_double_quote => try out.appendSlice(a, "\u{201d}"),
        .ellipsis => try out.appendSlice(a, "\u{2026}"),
        .em_dash => try out.appendSlice(a, "\u{2014}"),
        .en_dash => try out.appendSlice(a, "\u{2013}"),
        .raw_inline => {
            if (node.lang) |lang| {
                if (std.mem.eql(u8, lang, "html")) {
                    try out.appendSlice(a, node.text);
                }
            }
        },
        .raw_block => {
            if (node.lang) |lang| {
                if (std.mem.eql(u8, lang, "html")) {
                    try out.appendSlice(a, node.text);
                }
            }
        },
        else => {
            for (node.children) |child| try renderNode(a, out, child);
        },
    }
}

fn collectAltText(a: Allocator, out: *std.ArrayList(u8), children: []const Node) anyerror!void {
    for (children) |child| {
        if (child.tag == .str or child.tag == .soft_break) {
            try appendAttrEscaped(a, out, if (child.tag == .soft_break) " " else child.text);
        } else {
            try collectAltText(a, out, child.children);
        }
    }
}

fn renderListItem(a: Allocator, out: *std.ArrayList(u8), item: Node, tight: bool) anyerror!void {
    if (item.tag == .task_list_item) {
        try out.appendSlice(a, "<li>\n");
        if (item.checked orelse false) {
            try out.appendSlice(a, "<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\n");
        } else {
            try out.appendSlice(a, "<input disabled=\"\" type=\"checkbox\"/>\n");
        }
    } else {
        try out.appendSlice(a, "<li>\n");
    }

    if (tight) {
        for (item.children) |child| {
            if (child.tag == .para) {
                for (child.children) |inline_child| try renderNode(a, out, inline_child);
                try out.append(a, '\n');
            } else {
                try renderNode(a, out, child);
            }
        }
    } else {
        for (item.children) |child| try renderNode(a, out, child);
    }

    try out.appendSlice(a, "</li>\n");
}

fn renderAttrs(a: Allocator, out: *std.ArrayList(u8), node: Node) !void {
    if (node.id) |id| {
        try out.appendSlice(a, " id=\"");
        try appendAttrEscaped(a, out, id);
        try out.appendSlice(a, "\"");
    }
    var class_rendered = false;
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "class")) {
            class_rendered = true;
        }
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.appendSlice(a, "=\"");
        try appendAttrEscaped(a, out, attr.value);
        try out.appendSlice(a, "\"");
    }
    if (!class_rendered) {
        if (node.classes) |cls| {
            try out.appendSlice(a, " class=\"");
            try appendAttrEscaped(a, out, cls);
            try out.appendSlice(a, "\"");
        }
    }
}

fn renderFilteredAttrs(a: Allocator, out: *std.ArrayList(u8), node: Node, skip_class: bool) !void {
    if (node.id) |id| {
        try out.appendSlice(a, " id=\"");
        try appendAttrEscaped(a, out, id);
        try out.appendSlice(a, "\"");
    }
    for (node.attrs) |attr| {
        if (skip_class and std.mem.eql(u8, attr.key, "class")) continue;
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.appendSlice(a, "=\"");
        try appendAttrEscaped(a, out, attr.value);
        try out.appendSlice(a, "\"");
    }
    if (!skip_class) {
        if (node.classes) |cls| {
            try out.appendSlice(a, " class=\"");
            try appendAttrEscaped(a, out, cls);
            try out.appendSlice(a, "\"");
        }
    }
}

// ============================================================
// Utility Functions
// ============================================================

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// Check if a line starts a new block-level construct (heading, fence, list
/// marker, blockquote, thematic break, etc.). Used to prevent lazy continuation
/// from absorbing lines that should start their own block.
fn isNewBlockStart(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '#') return true; // heading
    if (trimmed[0] == '>') return true; // blockquote
    if (isCodeFence(line) != null) return true;
    if (parseBulletMarker(line) != null) return true;
    if (parseOrderedMarker(line) != null) return true;
    if (isThematicBreak(trimmed)) return true;
    if (trimmed[0] == ':' and trimmed.len > 1 and (trimmed[1] == ' ' or trimmed[1] == '\t')) return true;
    return false;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4;
        } else break;
    }
    return n;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

fn countLeadingChar(line: []const u8, char: u8) usize {
    for (line, 0..) |c, i| {
        if (c != char) return i;
    }
    return line.len;
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ' ') continue;
        if (c != '*' and c != '-') return false;
        count += 1;
    }
    return count >= 3;
}

const FenceInfo = struct {
    len: usize,
    char: u8,
    lang: ?[]const u8,
    indent: usize,
};

fn isCodeFence(line: []const u8) ?FenceInfo {
    var indent: usize = 0;
    var rest = line;
    while (rest.len > 0 and rest[0] == ' ') {
        indent += 1;
        rest = rest[1..];
    }
    if (rest.len < 3) return null;

    const fence_char = rest[0];
    if (fence_char != '`' and fence_char != '~') return null;

    const fence_len = countLeadingChar(rest, fence_char);
    if (fence_len < 3) return null;

    const after_fence = std.mem.trim(u8, rest[fence_len..], " \t");

    // Backtick fences: check if this is inline code (closing backticks on same line)
    // Also reject if the info string contains spaces (not a valid language specifier)
    if (fence_char == '`') {
        if (after_fence.len > 0) {
            if (std.mem.indexOfScalar(u8, after_fence, ' ') != null) return null;
            var bi: usize = 0;
            while (bi < after_fence.len) : (bi += 1) {
                if (after_fence[bi] == '`') {
                    const back_run = countLeadingChar(after_fence[bi..], '`');
                    if (back_run >= fence_len) return null;
                    bi += back_run;
                }
            }
        }
    }

    return .{
        .len = fence_len,
        .char = fence_char,
        .lang = if (after_fence.len > 0) after_fence else null,
        .indent = indent,
    };
}

fn startsBlockQuote(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len == 0) return false;
    if (trimmed[0] != '>') return false;
    if (trimmed.len == 1) return true; // Just ">"
    return trimmed[1] == ' ' or trimmed[1] == '\t';
}

fn stripBlockQuotePrefix(line: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len == 0) return "";
    if (trimmed[0] != '>') return line;
    if (trimmed.len == 1) return "";
    if (trimmed[1] == ' ' or trimmed[1] == '\t') return trimmed[2..];
    return trimmed[1..];
}

const DivInfo = struct {
    fence: []const u8,
    class: ?[]const u8,
};

fn isFencedDivStart(line: []const u8) ?DivInfo {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    const colons = countLeadingChar(trimmed, ':');
    if (colons < 3) return null;

    const after = std.mem.trim(u8, trimmed[colons..], " \t");
    return .{
        .fence = trimmed[0..colons],
        .class = if (after.len > 0) after else null,
    };
}

fn getNodeText(node: Node) []const u8 {
    if (node.text.len > 0) return node.text;
    if (node.children.len == 0) return "";
    // Return the full span from first str start to last str end
    var first: ?[*]const u8 = null;
    var last_end: [*]const u8 = undefined;
    for (node.children) |child| {
        if (child.tag == .str and child.text.len > 0) {
            if (first == null) first = child.text.ptr;
            last_end = child.text.ptr + child.text.len;
        } else if (child.tag == .soft_break) {
            // Soft break is a newline; include it in the span
        }
    }
    if (first) |f| {
        const len = @intFromPtr(last_end) - @intFromPtr(f);
        return f[0..len];
    }
    return "";
}

fn joinLines(a: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    var total: usize = 0;
    for (lines, 0..) |line, i| {
        if (i > 0) total += 1;
        total += line.len;
    }
    var buf = try a.alloc(u8, total);
    var pos: usize = 0;
    for (lines, 0..) |line, i| {
        if (i > 0) {
            buf[pos] = '\n';
            pos += 1;
        }
        @memcpy(buf[pos..][0..line.len], line);
        pos += line.len;
    }
    return buf;
}

fn appendEscaped(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            else => try out.append(a, c),
        }
    }
}

fn appendAttrEscaped(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, c),
        }
    }
}

// ============================================================
// Attribute Parser (state machine)
// ============================================================
//
// Parses Djot attributes: {#id .class key=value key="quoted" %comment%}
// Used for both block-level attributes and inline attributes.
// Modeled on the djot.js AttributeParser state machine.

const BlockAttrs = struct {
    id: ?[]const u8 = null,
    classes: ?[]const u8 = null,
    attrs: []const Attr = &.{},

    /// Merge `other` into `self`. Later values win for id and key-value;
    /// classes accumulate.
    fn merge(self: BlockAttrs, other: BlockAttrs, a: Allocator) !BlockAttrs {
        var result = BlockAttrs{};
        result.id = other.id orelse self.id;
        // Merge attrs: classes accumulate, other keys: later wins
        var merged: std.ArrayList(Attr) = .{};
        // Collect all class values from both sides
        var class_buf: std.ArrayList(u8) = .{};
        for (self.attrs) |sa| {
            if (std.mem.eql(u8, sa.key, "class")) {
                if (class_buf.items.len > 0) try class_buf.append(a, ' ');
                try class_buf.appendSlice(a, sa.value);
            }
        }
        for (other.attrs) |oa| {
            if (std.mem.eql(u8, oa.key, "class")) {
                if (class_buf.items.len > 0) try class_buf.append(a, ' ');
                try class_buf.appendSlice(a, oa.value);
            }
        }
        // Add non-class attrs from self (skip if overridden by other)
        for (self.attrs) |sa| {
            if (std.mem.eql(u8, sa.key, "class")) continue;
            var overridden = false;
            for (other.attrs) |oa| {
                if (std.mem.eql(u8, sa.key, oa.key)) { overridden = true; break; }
            }
            if (!overridden) try merged.append(a, sa);
        }
        // Add non-class attrs from other
        for (other.attrs) |oa| {
            if (std.mem.eql(u8, oa.key, "class")) continue;
            try merged.append(a, oa);
        }
        // Add merged class at end
        if (class_buf.items.len > 0) {
            try merged.append(a, .{ .key = "class", .value = try class_buf.toOwnedSlice(a) });
        }
        // Also merge the legacy classes field
        if (self.classes != null or other.classes != null) {
            result.classes = other.classes orelse self.classes;
        }
        if (merged.items.len > 0) {
            result.attrs = try merged.toOwnedSlice(a);
        }
        return result;
    }
};

const AttrParseStatus = enum { done, fail, @"continue" };

const AttrParser = struct {
    src: []const u8,
    state: AttrState,
    begin: ?usize,
    lastpos: ?usize,
    result: BlockAttrs,
    attrs_list: std.ArrayList(Attr),
    value_buf: std.ArrayList(u8),
    current_key: ?[]const u8,
    a: Allocator,

    const AttrState = enum {
        start,
        scanning,
        scanning_id,
        scanning_class,
        scanning_key,
        scanning_value,
        scanning_bare_value,
        scanning_quoted_value,
        scanning_escaped,
        scanning_comment,
        done,
        fail,
    };

    fn init(a: Allocator, src: []const u8) AttrParser {
        return .{
            .src = src,
            .state = .start,
            .begin = null,
            .lastpos = null,
            .result = .{},
            .attrs_list = .{},
            .value_buf = .{},
            .current_key = null,
            .a = a,
        };
    }

    fn feed(self: *AttrParser, startpos: usize, endpos: usize) struct { status: AttrParseStatus, position: usize } {
        var pos = startpos;
        while (pos <= endpos and pos < self.src.len) {
            self.state = self.step(pos);
            if (self.state == .done) {
                return .{ .status = .done, .position = pos };
            } else if (self.state == .fail) {
                return .{ .status = .fail, .position = pos };
            }
            self.lastpos = pos;
            pos += 1;
        }
        return .{ .status = .@"continue", .position = if (endpos < self.src.len) endpos else self.src.len -| 1 };
    }

    fn step(self: *AttrParser, pos: usize) AttrState {
        const c = self.src[pos];
        return switch (self.state) {
            .start => if (c == '{') .scanning else .fail,
            .scanning => self.stepScanning(c, pos),
            .scanning_id => self.stepScanningId(c, pos),
            .scanning_class => self.stepScanningClass(c, pos),
            .scanning_key => self.stepScanningKey(c, pos),
            .scanning_value => self.stepScanningValue(c, pos),
            .scanning_bare_value => self.stepScanningBareValue(c, pos),
            .scanning_quoted_value => self.stepScanningQuotedValue(c, pos),
            .scanning_escaped => .scanning_quoted_value,
            .scanning_comment => self.stepScanningComment(c),
            .done => .done,
            .fail => .fail,
        };
    }

    fn stepScanning(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') return .scanning;
        if (c == '}') return .done;
        if (c == '#') { self.begin = pos; return .scanning_id; }
        if (c == '%') { self.begin = pos; return .scanning_comment; }
        if (c == '.') { self.begin = pos; return .scanning_class; }
        if (isName(c)) { self.begin = pos; return .scanning_key; }
        return .fail;
    }

    fn stepScanningId(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isIdChar(c)) return .scanning_id;
        if (c == '}') {
            self.emitId(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitId(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningClass(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isName(c)) return .scanning_class;
        if (c == '}') {
            self.emitClass(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitClass(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningKey(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '=' and self.begin != null) {
            self.current_key = self.src[self.begin.? .. pos];
            self.begin = null;
            return .scanning_value;
        }
        if (isName(c)) return .scanning_key;
        return .fail;
    }

    fn stepScanningValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '"') {
            self.begin = pos;
            self.value_buf.items.len = 0;
            return .scanning_quoted_value;
        }
        if (isName(c)) {
            self.begin = pos;
            return .scanning_bare_value;
        }
        return .fail;
    }

    fn stepScanningBareValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isName(c)) return .scanning_bare_value;
        if (c == '}') {
            self.emitBareValue(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitBareValue(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningQuotedValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '"') {
            self.emitQuotedValue(pos);
            return .scanning;
        }
        if (c == '\\') {
            return .scanning_escaped;
        }
        if (c == '\n') {
            // Multi-line quoted value: append what we have so far
            if (self.begin) |b| {
                self.value_buf.appendSlice(self.a, self.src[b + 1 .. pos]) catch {};
                self.value_buf.appendSlice(self.a, " ") catch {};
                self.begin = pos; // will be reset on next non-whitespace
            }
            return .scanning_quoted_value;
        }
        return .scanning_quoted_value;
    }

    fn stepScanningComment(self: *AttrParser, c: u8) AttrState {
        _ = self;
        if (c == '%') return .scanning;
        if (c == '}') return .done;
        return .scanning_comment;
    }

    fn emitId(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const lp = if (self.lastpos) |l| l else pos -| 1;
            if (lp >= b) {
                self.result.id = self.src[b + 1 .. pos];
            }
            self.begin = null;
        }
    }

    fn emitClass(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const cls = self.src[b + 1 .. pos];
            // Store class as an attr entry to preserve declaration order
            self.attrs_list.append(self.a, .{ .key = "class", .value = cls }) catch {};
            self.begin = null;
        }
    }

    fn emitBareValue(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const value = self.src[b..pos];
            if (self.current_key) |key| {
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
            self.begin = null;
        }
    }

    fn emitQuotedValue(self: *AttrParser, pos: usize) void {
        if (self.value_buf.items.len > 0) {
            if (self.begin) |b| {
                self.value_buf.appendSlice(self.a, self.src[b + 1 .. pos]) catch {};
            }
            if (self.current_key) |key| {
                const raw = self.value_buf.toOwnedSlice(self.a) catch &.{};
                const value = self.processEscapes(raw);
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
        } else if (self.begin) |b| {
            const value = self.processEscapes(self.src[b + 1 .. pos]);
            if (self.current_key) |key| {
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
        }
        self.begin = null;
    }

    fn processEscapes(self: *AttrParser, raw: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var buf: std.ArrayList(u8) = .{};
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                buf.append(self.a, raw[i + 1]) catch {};
                i += 2;
            } else {
                buf.append(self.a, raw[i]) catch {};
                i += 1;
            }
        }
        return buf.toOwnedSlice(self.a) catch raw;
    }

    fn finish(self: *AttrParser) BlockAttrs {
        var result = self.result;
        // Merge multiple class entries into a single class attr at the
        // position of the first class, preserving overall declaration order
        if (self.attrs_list.items.len > 0) {
            var merged: std.ArrayList(Attr) = .{};
            var class_buf: std.ArrayList(u8) = .{};
            var class_inserted = false;
            for (self.attrs_list.items) |attr| {
                if (std.mem.eql(u8, attr.key, "class")) {
                    if (class_buf.items.len > 0) {
                        class_buf.append(self.a, ' ') catch {};
                    }
                    class_buf.appendSlice(self.a, attr.value) catch {};
                    if (!class_inserted) {
                        // Placeholder index; value will be set below
                        merged.append(self.a, .{ .key = "class", .value = "" }) catch {};
                        class_inserted = true;
                    }
                } else {
                    merged.append(self.a, attr) catch {};
                }
            }
            if (class_buf.items.len > 0) {
                const class_val = class_buf.toOwnedSlice(self.a) catch "";
                // Find the placeholder and fill in the merged value
                for (merged.items) |*m| {
                    if (std.mem.eql(u8, m.key, "class") and m.value.len == 0) {
                        m.value = class_val;
                        break;
                    }
                }
            }
            result.attrs = merged.toOwnedSlice(self.a) catch &.{};
        }
        return result;
    }

    fn isName(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
    }

    fn isIdChar(c: u8) bool {
        if (c <= ' ') return false;
        return switch (c) {
            ']', '[', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '`', ',', '.', '<', '>', '\\', '|', '=', '+', '/', '?', '"', '\'' => false,
            else => true,
        };
    }

    fn isAttrWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

fn tryParseBlockAttr(line: []const u8) ?BlockAttrs {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '{') return null;
    // Block attributes must occupy the entire line (no trailing content after })
    if (trimmed[trimmed.len - 1] != '}') return null;
    return parseAttrsFromStr(std.heap.page_allocator, trimmed);
}

fn parseAttrsFromStr(a: Allocator, src: []const u8) ?BlockAttrs {
    if (src.len < 2 or src[0] != '{') return null;
    var parser = AttrParser.init(a, src);
    const result = parser.feed(0, src.len -| 1);
    if (result.status == .done) {
        return parser.finish();
    }
    return null;
}

fn parseInlineAttrs(a: Allocator, src: []const u8, pos: usize) ?struct { attrs: BlockAttrs, end: usize } {
    if (pos >= src.len or src[pos] != '{') return null;
    var parser = AttrParser.init(a, src);
    const result = parser.feed(pos, src.len -| 1);
    if (result.status == .done) {
        return .{ .attrs = parser.finish(), .end = result.position + 1 };
    }
    return null;
}

fn mergeBlockAttrs(a: Allocator, existing: ?BlockAttrs, new_attrs: BlockAttrs) !BlockAttrs {
    if (existing) |ex| {
        return ex.merge(new_attrs, a);
    }
    return new_attrs;
}

fn applyBlockAttrs(node: Node, attrs: BlockAttrs) Node {
    var result = node;
    if (attrs.id) |id| result.id = id;
    if (attrs.classes) |cls| result.classes = cls;
    if (attrs.attrs.len > 0) result.attrs = attrs.attrs;
    return result;
}

/// Merge reference-level attrs as defaults under any inline attrs already on the node.
/// Inline attrs (already on the node) take priority for id and key-value pairs.
fn mergeRefAttrs(node: Node, ref_attrs: BlockAttrs, a: Allocator) Node {
    var result = node;
    if (result.id == null) result.id = ref_attrs.id;
    if (ref_attrs.classes) |ref_cls| {
        if (result.classes) |existing| {
            result.classes = std.fmt.allocPrint(a, "{s} {s}", .{ ref_cls, existing }) catch existing;
        } else {
            result.classes = ref_cls;
        }
    }
    if (ref_attrs.attrs.len > 0) {
        if (result.attrs.len == 0) {
            result.attrs = ref_attrs.attrs;
        } else {
            var merged: std.ArrayList(Attr) = .{};
            for (ref_attrs.attrs) |ra| {
                var overridden = false;
                for (result.attrs) |na| {
                    if (std.mem.eql(u8, ra.key, na.key)) {
                        overridden = true;
                        break;
                    }
                }
                if (!overridden) merged.append(a, ra) catch {};
            }
            for (result.attrs) |na| merged.append(a, na) catch {};
            result.attrs = merged.toOwnedSlice(a) catch result.attrs;
        }
    }
    return result;
}

const BulletInfo = struct {
    rest: []const u8,
    indent: usize,
    content_col: usize,
    marker: u8,
};

fn parseBulletMarker(line: []const u8) ?BulletInfo {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
    const trimmed = line[indent..];
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '-' and trimmed[0] != '+' and trimmed[0] != '*') return null;
    if (trimmed[1] != ' ' and trimmed[1] != '\t') return null;
    if (trimmed[0] == '-' or trimmed[0] == '*') {
        if (isThematicBreak(line)) return null;
    }
    return .{
        .rest = trimmed[2..],
        .indent = indent,
        .content_col = indent + 2,
        .marker = trimmed[0],
    };
}

const ListStyle = enum {
    decimal, // 1. 1) (1)
    lower_alpha, // a. a) (a)
    upper_alpha, // A. A) (A)
    lower_roman, // i. i) (i)
    upper_roman, // I. I) (I)

    fn htmlType(self: ListStyle) ?[]const u8 {
        return switch (self) {
            .decimal => null,
            .lower_alpha => "a",
            .upper_alpha => "A",
            .lower_roman => "i",
            .upper_roman => "I",
        };
    }
};

const OrderedInfo = struct {
    rest: []const u8,
    indent: usize,
    content_col: usize,
    start: usize,
    style: ListStyle,
    styles: [2]?ListStyle, // ambiguous styles (e.g. "i." could be roman or alpha)
    n_styles: u2,
    marker_text: []const u8, // raw marker chars (digits/letters only, no parens/period)
};

fn parseOrderedMarker(line: []const u8) ?OrderedInfo {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
    const trimmed = line[indent..];
    if (trimmed.len < 2) return null;

    var paren_open = false;
    var start: usize = 0;
    if (trimmed[0] == '(') {
        paren_open = true;
        start = 1;
    }
    const after_paren = trimmed[start..];
    if (after_paren.len == 0) return null;

    // Try digit sequence: 1. 1) (1)
    var i: usize = 0;
    while (i < after_paren.len and std.ascii.isDigit(after_paren[i])) : (i += 1) {}
    if (i > 0 and i < after_paren.len) {
        const delim = after_paren[i];
        if ((!paren_open and (delim == '.' or delim == ')')) or
            (paren_open and delim == ')'))
        {
            const marker_len = start + i + 1;
            const num = std.fmt.parseInt(usize, after_paren[0..i], 10) catch 1;
            return finishMarker(trimmed, indent, marker_len, num, .decimal, .decimal, after_paren[0..i]);
        }
    }

    // Try single-char alpha or roman, or multi-char roman
    if (after_paren.len >= 2) {
        const c = after_paren[0];
        // Single lowercase letter
        if (std.ascii.isLower(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or
                (paren_open and delim == ')'))
            {
                const marker_len = start + 2;
                if (isRomanLower(c)) {
                    return finishMarker(trimmed, indent, marker_len,
                        romanToNumber(&.{c}), .lower_roman, .lower_alpha, after_paren[0..1]);
                } else {
                    return finishMarker(trimmed, indent, marker_len,
                        @as(usize, c - 'a') + 1, .lower_alpha, .lower_alpha, after_paren[0..1]);
                }
            }
        }
        // Single uppercase letter
        if (std.ascii.isUpper(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or
                (paren_open and delim == ')'))
            {
                const marker_len = start + 2;
                if (isRomanUpper(c)) {
                    return finishMarker(trimmed, indent, marker_len,
                        romanToNumber(&.{c}), .upper_roman, .upper_alpha, after_paren[0..1]);
                } else {
                    return finishMarker(trimmed, indent, marker_len,
                        @as(usize, c - 'A') + 1, .upper_alpha, .upper_alpha, after_paren[0..1]);
                }
            }
        }
        // Multi-char lowercase roman
        if (isRomanLower(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanLower(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or
                    (paren_open and delim == ')'))
                {
                    const marker_len = start + j + 1;
                    const num = romanToNumber(after_paren[0..j]);
                    return finishMarker(trimmed, indent, marker_len, num, .lower_roman, .lower_roman, after_paren[0..j]);
                }
            }
        }
        // Multi-char uppercase roman
        if (isRomanUpper(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanUpper(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or
                    (paren_open and delim == ')'))
                {
                    const marker_len = start + j + 1;
                    const num = romanToNumber(after_paren[0..j]);
                    return finishMarker(trimmed, indent, marker_len, num, .upper_roman, .upper_roman, after_paren[0..j]);
                }
            }
        }
    }

    return null;
}

fn finishMarker(trimmed: []const u8, indent: usize, marker_len: usize, num: usize, style1: ListStyle, style2: ListStyle, marker_text: []const u8) ?OrderedInfo {
    if (marker_len >= trimmed.len) {
        return .{
            .rest = "",
            .indent = indent,
            .content_col = indent + marker_len + 1,
            .start = num,
            .style = style1,
            .styles = .{ style1, if (style1 != style2) style2 else null },
            .n_styles = if (style1 != style2) 2 else 1,
            .marker_text = marker_text,
        };
    }
    if (trimmed[marker_len] != ' ' and trimmed[marker_len] != '\t') return null;
    return .{
        .rest = trimmed[marker_len + 1 ..],
        .indent = indent,
        .content_col = indent + marker_len + 1,
        .start = num,
        .style = style1,
        .styles = .{ style1, if (style1 != style2) style2 else null },
        .n_styles = if (style1 != style2) 2 else 1,
        .marker_text = marker_text,
    };
}

fn getListStart(marker_text: []const u8, style: ListStyle) usize {
    return switch (style) {
        .decimal => std.fmt.parseInt(usize, marker_text, 10) catch 1,
        .lower_alpha => if (marker_text.len == 1) @as(usize, marker_text[0] - 'a') + 1 else 1,
        .upper_alpha => if (marker_text.len == 1) @as(usize, marker_text[0] - 'A') + 1 else 1,
        .lower_roman => romanToNumber(marker_text),
        .upper_roman => romanToNumber(marker_text),
    };
}

fn isRomanLower(c: u8) bool {
    return switch (c) {
        'i', 'v', 'x', 'l', 'c', 'd', 'm' => true,
        else => false,
    };
}

fn isRomanUpper(c: u8) bool {
    return switch (c) {
        'I', 'V', 'X', 'L', 'C', 'D', 'M' => true,
        else => false,
    };
}

fn romanToNumber(s: []const u8) usize {
    var total: usize = 0;
    var prev: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const n: usize = switch (s[i]) {
            'i', 'I' => 1,
            'v', 'V' => 5,
            'x', 'X' => 10,
            'l', 'L' => 50,
            'c', 'C' => 100,
            'd', 'D' => 500,
            'm', 'M' => 1000,
            else => 0,
        };
        if (n < prev) {
            total -|= n;
        } else {
            total += n;
        }
        prev = n;
    }
    return if (total > 0) total else 1;
}

fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 1 or trimmed[0] != '|') return false;
    var pipes: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            i += 2;
        } else if (trimmed[i] == '`') {
            const ticks = countRunAt(trimmed, i, '`');
            const after = i + ticks;
            if (findClosingTicks(trimmed, after, ticks)) |close| {
                i = close + ticks;
            } else {
                i = trimmed.len;
            }
        } else {
            if (trimmed[i] == '|') pipes += 1;
            i += 1;
        }
    }
    return pipes >= 2;
}

fn isTableSep(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t|");
    for (trimmed) |c| {
        if (c != '-' and c != ':' and c != '|' and c != ' ') return false;
    }
    return trimmed.len > 0;
}

fn parseSepAligns(a: Allocator, line: []const u8) ![]const Node.CellAlign {
    var result: std.ArrayList(Node.CellAlign) = .{};
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    var cell_iter = std.mem.splitScalar(u8, content, '|');
    while (cell_iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) {
            try result.append(a, .default);
            continue;
        }
        const left_colon = c[0] == ':';
        const right_colon = c[c.len - 1] == ':';
        if (left_colon and right_colon) {
            try result.append(a, .center);
        } else if (right_colon) {
            try result.append(a, .right);
        } else if (left_colon) {
            try result.append(a, .left);
        } else {
            try result.append(a, .default);
        }
    }
    return result.toOwnedSlice(a);
}

fn splitTableCells(a: Allocator, content: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .{};
    var i: usize = 0;
    var cell_start: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
        } else if (content[i] == '`') {
            const tick_count = countRunAt(content, i, '`');
            const after = i + tick_count;
            if (findClosingTicks(content, after, tick_count)) |close| {
                i = close + tick_count;
            } else {
                i = content.len;
            }
        } else if (content[i] == '|') {
            try result.append(a, content[cell_start..i]);
            cell_start = i + 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    try result.append(a, content[cell_start..]);
    return result.toOwnedSlice(a);
}

fn parseTableRowWithAlign(a: Allocator, line: []const u8, col_aligns: []const Node.CellAlign, is_head: bool) ![]const Node {
    var cells: std.ArrayList(Node) = .{};
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    const cell_strs = try splitTableCells(a, content);
    for (cell_strs, 0..) |cell, col| {
        const cell_text = std.mem.trim(u8, cell, " \t");
        const inlines = try parseInlines(a, &.{cell_text});
        var node = Node{ .tag = .cell, .children = inlines, .head = is_head };
        if (col < col_aligns.len) {
            node.cell_align = col_aligns[col];
        }
        try cells.append(a, node);
    }
    return cells.toOwnedSlice(a);
}

// ============================================================
// Test Harness
// ============================================================

const TestCase = struct {
    input: []const u8,
    expected: []const u8,
    line_number: usize,
    ast_mode: bool,
    sourcepos: bool,
};

const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.failed + self.skipped;
    }

    fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

fn countBackticks(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != '`') return i;
    }
    return line.len;
}

fn parseTestFile(allocator: Allocator, content: []const u8) ![]TestCase {
    var cases: std.ArrayList(TestCase) = .{};

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (true) {
        const raw = lines.next() orelse break;
        line_num += 1;
        const line = std.mem.trimRight(u8, raw, "\r");

        const fence = countBackticks(line);
        if (fence < 3) continue;

        const opts = std.mem.trim(u8, line[fence..], " \t");
        const ast_mode = std.mem.indexOfScalar(u8, opts, 'a') != null;
        const sourcepos = std.mem.indexOfScalar(u8, opts, 'p') != null;
        const start_line = line_num;

        var input_buf: std.ArrayList(u8) = .{};
        var sep_found = false;

        while (lines.next()) |r| {
            line_num += 1;
            const l = std.mem.trimRight(u8, r, "\r");
            if (l.len == 1 and (l[0] == '.' or l[0] == '!')) {
                sep_found = true;
                break;
            }
            try input_buf.appendSlice(allocator, l);
            try input_buf.append(allocator, '\n');
        }

        if (!sep_found) {
            input_buf.deinit(allocator);
            break;
        }

        var output_buf: std.ArrayList(u8) = .{};

        while (lines.next()) |r| {
            line_num += 1;
            const l = std.mem.trimRight(u8, r, "\r");
            if (countBackticks(l) >= fence) break;
            try output_buf.appendSlice(allocator, l);
            try output_buf.append(allocator, '\n');
        }

        try cases.append(allocator, .{
            .input = try input_buf.toOwnedSlice(allocator),
            .expected = try output_buf.toOwnedSlice(allocator),
            .line_number = start_line,
            .ast_mode = ast_mode,
            .sourcepos = sourcepos,
        });
    }

    return try cases.toOwnedSlice(allocator);
}

fn runTestFile(
    allocator: Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
) !TestResults {
    const file = try dir.openFile(filename, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    const cases = try parseTestFile(allocator, content);

    var results = TestResults{};

    for (cases, 0..) |tc, ci| {
        const html = if (tc.ast_mode)
            toAstOpts(allocator, tc.input, tc.sourcepos) catch |err| {
                std.debug.print("    ERR[{d}] at line {d}: {s}\n", .{ ci, tc.line_number, @errorName(err) });
                results.failed += 1;
                continue;
            }
        else
            toHtml(allocator, tc.input) catch |err| {
                std.debug.print("    ERR[{d}] at line {d}: {s}\n", .{ ci, tc.line_number, @errorName(err) });
                results.failed += 1;
                continue;
            };

        if (std.mem.eql(u8, html, tc.expected)) {
            results.passed += 1;
        } else {
            results.failed += 1;
            if (results.failed <= 100) {
                std.debug.print("    FAIL[{d}] at line {d}:\n", .{ ci, tc.line_number });
                std.debug.print("---expected---\n{s}\n---got---\n{s}\n---end---\n", .{ tc.expected, html });
            }
        }
    }

    return results;
}

const test_file_names = [_][]const u8{
    "attributes.test",
    "block_quote.test",
    "code_blocks.test",
    "definition_lists.test",
    "emphasis.test",
    "escapes.test",
    "fenced_divs.test",
    "footnotes.test",
    "headings.test",
    "insert_delete_mark.test",
    "links_and_images.test",
    "lists.test",
    "math.test",
    "para.test",
    "raw.test",
    "regression.test",
    "smart.test",
    "spans.test",
    "sourcepos.test",
    "super_subscript.test",
    "symb.test",
    "tables.test",
    "task_lists.test",
    "thematic_breaks.test",
    "verbatim.test",
};

test "djot test suite" {
    var test_dir = std.fs.cwd().openDir("../djot/djot.js/test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory ../djot/djot.js/test: {}\n", .{err});
        std.debug.print("Ensure djot.js is cloned at ../djot/djot.js relative to the project root.\n", .{});
        return err;
    };
    defer test_dir.close();

    var total = TestResults{};

    for (test_file_names) |filename| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const results = runTestFile(arena.allocator(), test_dir, filename) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            continue;
        };

        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const name = filename[0..dot];

        if (results.skipped > 0) {
            std.debug.print("  {s}: {d}/{d} passed ({d} skipped)\n", .{
                name, results.passed, results.total(), results.skipped,
            });
        } else {
            std.debug.print("  {s}: {d}/{d} passed\n", .{
                name, results.passed, results.total(),
            });
        }

        total.add(results);
    }

    std.debug.print("\n  Total: {d}/{d} passed", .{ total.passed, total.total() });
    if (total.skipped > 0) std.debug.print(" ({d} skipped)", .{total.skipped});
    std.debug.print("\n\n", .{});

    if (total.failed > 0) {
        return error.TestsFailed;
    }
}
