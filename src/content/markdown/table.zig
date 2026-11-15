//! GFM pipe tables:
//!
//!     | Name | Price |
//!     |:-----|------:|
//!     | Tea  |  3.50 |

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const inline_md = @import("inline.zig");

const Align = enum { none, left, center, right };

/// A header row with a delimiter row right below it.
pub fn startsAt(lines: []const []const u8, i: usize) bool {
    if (i + 1 >= lines.len) return false;
    if (std.mem.indexOfScalar(u8, lines[i], '|') == null) return false;
    return isDelimiterRow(lines[i + 1]);
}

fn isDelimiterRow(line: []const u8) bool {
    if (std.mem.indexOfScalar(u8, line, '|') == null) return false;
    var cells = std.mem.splitScalar(u8, trimPipes(line), '|');
    while (cells.next()) |raw| {
        const cell = std.mem.trim(u8, raw, " ");
        const inner = std.mem.trim(u8, cell, ":");
        if (inner.len == 0) return false;
        for (inner) |c| if (c != '-') return false;
    }
    return true;
}

/// Renders the table starting at `i`; returns the index after it.
pub fn render(
    arena: Allocator,
    w: *Writer,
    lines: []const []const u8,
    i: usize,
) !usize {
    const header = try splitCells(arena, lines[i]);
    const aligns = try alignments(arena, lines[i + 1], header.len);
    try w.writeAll("<table>\n<thead>\n");
    try writeRow(w, header, aligns, "th");
    try w.writeAll("</thead>\n");
    var j = i + 2;
    if (j < lines.len and isBodyRow(lines[j])) try w.writeAll("<tbody>\n");
    const body_start = j;
    while (j < lines.len and isBodyRow(lines[j])) : (j += 1) {
        try writeRow(w, try splitCells(arena, lines[j]), aligns, "td");
    }
    if (j > body_start) try w.writeAll("</tbody>\n");
    try w.writeAll("</table>\n");
    return j;
}

fn isBodyRow(line: []const u8) bool {
    return std.mem.trim(u8, line, " ").len > 0 and
        std.mem.indexOfScalar(u8, line, '|') != null;
}

fn writeRow(
    w: *Writer,
    cells: []const []const u8,
    aligns: []const Align,
    comptime tag: []const u8,
) !void {
    try w.writeAll("<tr>\n");
    for (aligns, 0..) |a, k| {
        try w.writeAll("<" ++ tag);
        if (a != .none) try w.print(" style=\"text-align:{t}\"", .{a});
        try w.writeByte('>');
        if (k < cells.len) try inline_md.render(w, cells[k]);
        try w.writeAll("</" ++ tag ++ ">\n");
    }
    try w.writeAll("</tr>\n");
}

fn alignments(
    arena: Allocator,
    line: []const u8,
    count: usize,
) ![]Align {
    const out = try arena.alloc(Align, count);
    @memset(out, .none);
    var cells = std.mem.splitScalar(u8, trimPipes(line), '|');
    var k: usize = 0;
    while (cells.next()) |raw| : (k += 1) {
        if (k == count) break;
        const cell = std.mem.trim(u8, raw, " ");
        const left = std.mem.startsWith(u8, cell, ":");
        const right = std.mem.endsWith(u8, cell, ":");
        out[k] = if (left and right) .center else if (right)
            .right
        else if (left) .left else .none;
    }
    return out;
}

/// Cells split on `|`, except `\|` and pipes inside code spans.
fn splitCells(arena: Allocator, line: []const u8) ![]const []const u8 {
    const row = trimPipes(line);
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var in_code = false;
    for (row, 0..) |c, k| {
        if (c == '`') in_code = !in_code;
        const escaped = k > 0 and row[k - 1] == '\\';
        if (c != '|' or in_code or escaped) continue;
        try cells.append(arena, std.mem.trim(u8, row[start..k], " "));
        start = k + 1;
    }
    try cells.append(arena, std.mem.trim(u8, row[start..], " "));
    return cells.items;
}

fn trimPipes(line: []const u8) []const u8 {
    var row = std.mem.trim(u8, line, " ");
    if (std.mem.startsWith(u8, row, "|")) row = row[1..];
    if (std.mem.endsWith(u8, row, "|") and !std.mem.endsWith(u8, row, "\\|"))
        row = row[0 .. row.len - 1];
    return row;
}
