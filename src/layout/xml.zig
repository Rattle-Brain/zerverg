//! A deliberately small XML parser for layout files.
//!
//! Supported: elements, quoted attributes, text, comments, an XML
//! declaration and the five predefined entities plus numeric
//! character references. Rejected: DOCTYPE, CDATA, processing
//! instructions and namespaces. With no DTD support there is no
//! entity expansion, so XXE and "billion laughs" are impossible.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_depth = 32;
pub const max_nodes = 2048;

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    element: Element,
    text: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    children: []const Node = &.{},

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidXml,
    XmlUnsupportedFeature,
    XmlTooDeep,
    XmlTooLarge,
} || Allocator.Error;

/// Parses `source` and returns its root element. All memory comes
/// from `arena`; the result may reference `source`.
pub fn parse(arena: Allocator, source: []const u8) ParseError!Element {
    var parser: Parser = .{ .arena = arena, .src = source };
    try parser.skipMisc(true);
    const root = try parser.parseElement(0);
    try parser.skipMisc(false);
    if (parser.pos != source.len) return error.InvalidXml;
    return root;
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    nodes: usize = 0,

    /// Skips whitespace and comments; the XML declaration is only
    /// allowed before the root element.
    fn skipMisc(p: *Parser, allow_declaration: bool) ParseError!void {
        while (true) {
            p.skipSpace();
            if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (allow_declaration and p.startsWith("<?xml")) {
                const end = std.mem.indexOfPos(u8, p.src, p.pos, "?>") orelse
                    return error.InvalidXml;
                p.pos = end + 2;
            } else if (p.startsWith("<!") or p.startsWith("<?")) {
                return error.XmlUnsupportedFeature;
            } else {
                return;
            }
        }
    }

    fn parseElement(p: *Parser, depth: usize) ParseError!Element {
        if (depth >= max_depth) return error.XmlTooDeep;
        try p.countNode();
        try p.expect('<');
        const name = try p.parseName();
        const attrs = try p.parseAttrs();
        if (p.startsWith("/>")) {
            p.pos += 2;
            return .{ .name = name, .attrs = attrs };
        }
        try p.expect('>');
        const children = try p.parseChildren(depth);
        try p.expectClosing(name);
        return .{ .name = name, .attrs = attrs, .children = children };
    }

    fn parseChildren(p: *Parser, depth: usize) ParseError![]const Node {
        var children: std.ArrayList(Node) = .empty;
        while (true) {
            if (p.pos >= p.src.len) return error.InvalidXml;
            if (p.startsWith("</")) return children.items;
            if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<!") or p.startsWith("<?")) {
                return error.XmlUnsupportedFeature;
            } else if (p.src[p.pos] == '<') {
                const child = try p.parseElement(depth + 1);
                try children.append(p.arena, .{ .element = child });
            } else {
                const text = try p.parseText();
                if (!isBlank(text)) {
                    try p.countNode();
                    try children.append(p.arena, .{ .text = text });
                }
            }
        }
    }

    fn parseAttrs(p: *Parser) ParseError![]const Attr {
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len) return error.InvalidXml;
            const c = p.src[p.pos];
            if (c == '>' or c == '/') return attrs.items;
            const name = try p.parseName();
            for (attrs.items) |a| {
                if (std.mem.eql(u8, a.name, name)) return error.InvalidXml;
            }
            p.skipSpace();
            try p.expect('=');
            p.skipSpace();
            const value = try p.parseQuoted();
            try attrs.append(p.arena, .{ .name = name, .value = value });
        }
    }

    fn parseQuoted(p: *Parser) ParseError![]const u8 {
        if (p.pos >= p.src.len) return error.InvalidXml;
        const quote = p.src[p.pos];
        if (quote != '"' and quote != '\'') return error.InvalidXml;
        const start = p.pos + 1;
        const end = std.mem.indexOfScalarPos(u8, p.src, start, quote) orelse
            return error.InvalidXml;
        const raw = p.src[start..end];
        if (std.mem.indexOfScalar(u8, raw, '<') != null) {
            return error.InvalidXml;
        }
        p.pos = end + 1;
        return decodeEntities(p.arena, raw);
    }

    fn parseText(p: *Parser) ParseError![]const u8 {
        const start = p.pos;
        const end = std.mem.indexOfScalarPos(u8, p.src, start, '<') orelse
            return error.InvalidXml;
        p.pos = end;
        return decodeEntities(p.arena, p.src[start..end]);
    }

    fn parseName(p: *Parser) ParseError![]const u8 {
        const start = p.pos;
        while (p.pos < p.src.len and isNameChar(p.src[p.pos])) p.pos += 1;
        if (p.pos == start or !isNameStart(p.src[start])) {
            return error.InvalidXml;
        }
        return p.src[start..p.pos];
    }

    fn expectClosing(p: *Parser, name: []const u8) ParseError!void {
        if (!p.startsWith("</")) return error.InvalidXml;
        p.pos += 2;
        const closing = try p.parseName();
        if (!std.mem.eql(u8, closing, name)) return error.InvalidXml;
        p.skipSpace();
        try p.expect('>');
    }

    fn skipComment(p: *Parser) ParseError!void {
        const end = std.mem.indexOfPos(u8, p.src, p.pos + 4, "-->") orelse
            return error.InvalidXml;
        p.pos = end + 3;
    }

    fn countNode(p: *Parser) ParseError!void {
        p.nodes += 1;
        if (p.nodes > max_nodes) return error.XmlTooLarge;
    }

    fn expect(p: *Parser, c: u8) ParseError!void {
        if (p.pos >= p.src.len or p.src[p.pos] != c) return error.InvalidXml;
        p.pos += 1;
    }

    fn startsWith(p: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], prefix);
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and isSpace(p.src[p.pos])) p.pos += 1;
    }
};

/// Decodes predefined entities and numeric character references.
fn decodeEntities(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(arena, raw[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse
            return error.InvalidXml;
        try appendEntity(arena, &out, raw[i + 1 .. end]);
        i = end + 1;
    }
    return out.items;
}

fn appendEntity(
    arena: Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) ParseError!void {
    const named = [_]struct { []const u8, u8 }{
        .{ "lt", '<' },   .{ "gt", '>' },    .{ "amp", '&' },
        .{ "quot", '"' }, .{ "apos", '\'' },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            return out.append(arena, entry[1]);
        }
    }
    if (name.len < 2 or name[0] != '#') return error.InvalidXml;
    const hex = name[1] == 'x';
    const digits = if (hex) name[2..] else name[1..];
    const code = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch
        return error.InvalidXml;
    if (code == 0) return error.InvalidXml;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &buf) catch
        return error.InvalidXml;
    try out.appendSlice(arena, buf[0..len]);
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isBlank(text: []const u8) bool {
    for (text) |c| if (!isSpace(c)) return false;
    return true;
}

const testing = std.testing;

test "parse nested elements, attributes and entities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const root = try parse(arena_state.allocator(),
        \\<?xml version="1.0"?>
        \\<!-- comment -->
        \\<layout kind='single'>
        \\  <text>a &lt;b&gt; &#65;&#x42;</text>
        \\  <main/>
        \\</layout>
    );
    try testing.expectEqualStrings("layout", root.name);
    try testing.expectEqualStrings("single", root.attr("kind").?);
    try testing.expectEqual(@as(usize, 2), root.children.len);
    const text = root.children[0].element.children[0].text;
    try testing.expectEqualStrings("a <b> AB", text);
}

test "reject dangerous or malformed input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doctype = "<!DOCTYPE x [<!ENTITY a \"b\">]><x/>";
    try testing.expectError(error.XmlUnsupportedFeature, parse(arena, doctype));
    try testing.expectError(error.InvalidXml, parse(arena, "<a><b></a>"));
    try testing.expectError(error.InvalidXml, parse(arena, "<a x='1' x='2'/>"));
    try testing.expectError(error.InvalidXml, parse(arena, "<a>&bogus;</a>"));
    try testing.expectError(error.InvalidXml, parse(arena, "<a/><b/>"));
    const deep = "<a>" ** 40 ++ "</a>" ** 40;
    try testing.expectError(error.XmlTooDeep, parse(arena, deep));
}
