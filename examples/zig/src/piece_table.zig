const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = enum {
    original,
    add,
};

pub const Piece = struct {
    source: Source,
    start: usize,
    len: usize,
};

pub const Selection = struct {
    anchor: usize,
    head: usize,

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.head);
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.head;
    }

    pub fn point(pos: usize) Selection {
        return .{ .anchor = pos, .head = pos };
    }
};

pub const Snapshot = struct {
    pieces: []Piece,
    cursors: []Selection,
    total_len: usize,
};

/// Piece Table text buffer with append-only `add_buf` and transaction-friendly
/// multi-cursor + selection Undo/Redo snapshot history.
pub const PieceTable = struct {
    allocator: Allocator,
    original: []u8,
    add_buf: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    undo_stack: std.ArrayList(Snapshot),
    redo_stack: std.ArrayList(Snapshot),
    total_len: usize,

    pub fn init(allocator: Allocator, initial_text: []const u8) !PieceTable {
        const orig_copy = try allocator.dupe(u8, initial_text);
        errdefer allocator.free(orig_copy);

        var pieces: std.ArrayList(Piece) = .empty;
        errdefer pieces.deinit(allocator);
        if (orig_copy.len > 0) {
            try pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .len = orig_copy.len,
            });
        }

        return .{
            .allocator = allocator,
            .original = orig_copy,
            .add_buf = .empty,
            .pieces = pieces,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .total_len = orig_copy.len,
        };
    }

    pub fn deinit(self: *PieceTable) void {
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.add_buf.deinit(self.allocator);
        self.allocator.free(self.original);
    }

    fn clearStack(self: *PieceTable, stack: *std.ArrayList(Snapshot)) void {
        for (stack.items) |snap| {
            self.allocator.free(snap.pieces);
            self.allocator.free(snap.cursors);
        }
        stack.clearRetainingCapacity();
    }

    /// Capture an Undo snapshot for the current pieces and cursor selections.
    pub fn pushUndo(self: *PieceTable, cursors_before: []const Selection) !void {
        const pieces_copy = try self.allocator.dupe(Piece, self.pieces.items);
        errdefer self.allocator.free(pieces_copy);
        const cursors_copy = try self.allocator.dupe(Selection, cursors_before);
        errdefer self.allocator.free(cursors_copy);

        try self.undo_stack.append(self.allocator, .{
            .pieces = pieces_copy,
            .cursors = cursors_copy,
            .total_len = self.total_len,
        });
        self.clearStack(&self.redo_stack);
    }

    pub fn pieceSlice(self: *const PieceTable, piece: Piece) []const u8 {
        return switch (piece.source) {
            .original => self.original[piece.start .. piece.start + piece.len],
            .add => self.add_buf.items[piece.start .. piece.start + piece.len],
        };
    }

    pub fn materialize(self: *const PieceTable, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.total_len);
        var pos: usize = 0;
        for (self.pieces.items) |piece| {
            const s = self.pieceSlice(piece);
            @memcpy(out[pos .. pos + s.len], s);
            pos += s.len;
        }
        return out;
    }

    /// Insert bytes without creating an Undo snapshot (used for multi-cursor batches).
    pub fn insertRaw(self: *PieceTable, byte_pos: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const clamped_pos = @min(byte_pos, self.total_len);

        const add_start = self.add_buf.items.len;
        try self.add_buf.appendSlice(self.allocator, bytes);
        const new_piece: Piece = .{
            .source = .add,
            .start = add_start,
            .len = bytes.len,
        };

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += bytes.len;
            return;
        }

        var offset: usize = 0;
        for (self.pieces.items, 0..) |*p, idx| {
            if (clamped_pos == offset) {
                if (idx > 0) {
                    const prev = &self.pieces.items[idx - 1];
                    if (prev.source == .add and prev.start + prev.len == add_start) {
                        prev.len += bytes.len;
                        self.total_len += bytes.len;
                        return;
                    }
                }
                try self.pieces.insert(self.allocator, idx, new_piece);
                self.total_len += bytes.len;
                return;
            }
            if (clamped_pos < offset + p.len) {
                const split_at = clamped_pos - offset;
                const left: Piece = .{ .source = p.source, .start = p.start, .len = split_at };
                const right: Piece = .{ .source = p.source, .start = p.start + split_at, .len = p.len - split_at };
                p.* = left;
                try self.pieces.insertSlice(self.allocator, idx + 1, &.{ new_piece, right });
                self.total_len += bytes.len;
                return;
            }
            offset += p.len;
        }

        const last = &self.pieces.items[self.pieces.items.len - 1];
        if (last.source == .add and last.start + last.len == add_start) {
            last.len += bytes.len;
        } else {
            try self.pieces.append(self.allocator, new_piece);
        }
        self.total_len += bytes.len;
    }

    pub fn insert(self: *PieceTable, byte_pos: usize, bytes: []const u8, cursor_before: usize) !void {
        if (bytes.len == 0) return;
        try self.pushUndo(&.{Selection.point(cursor_before)});
        try self.insertRaw(byte_pos, bytes);
    }

    /// Delete byte range without creating an Undo snapshot (used for multi-cursor batches).
    pub fn deleteRangeRaw(self: *PieceTable, start_pos: usize, del_len: usize) !void {
        if (del_len == 0 or start_pos >= self.total_len) return;
        const actual_end = @min(start_pos + del_len, self.total_len);
        if (actual_end <= start_pos) return;

        var next_pieces: std.ArrayList(Piece) = .empty;
        errdefer next_pieces.deinit(self.allocator);

        var offset: usize = 0;
        for (self.pieces.items) |p| {
            const p_start = offset;
            const p_end = offset + p.len;
            offset = p_end;

            if (p_end <= start_pos or p_start >= actual_end) {
                try next_pieces.append(self.allocator, p);
                continue;
            }
            if (p_start < start_pos) {
                try next_pieces.append(self.allocator, .{
                    .source = p.source,
                    .start = p.start,
                    .len = start_pos - p_start,
                });
            }
            if (p_end > actual_end) {
                const skip = actual_end - p_start;
                try next_pieces.append(self.allocator, .{
                    .source = p.source,
                    .start = p.start + skip,
                    .len = p_end - actual_end,
                });
            }
        }

        self.pieces.deinit(self.allocator);
        self.pieces = next_pieces;
        self.total_len -= (actual_end - start_pos);
    }

    pub fn deleteRange(self: *PieceTable, start_pos: usize, del_len: usize, cursor_before: usize) !void {
        if (del_len == 0 or start_pos >= self.total_len) return;
        try self.pushUndo(&.{Selection.point(cursor_before)});
        try self.deleteRangeRaw(start_pos, del_len);
    }

    pub fn undo(self: *PieceTable, current_cursors: []const Selection, out_cursors: *std.ArrayList(Selection)) !bool {
        if (self.undo_stack.items.len == 0) return false;
        const snap = self.undo_stack.pop().?;
        errdefer {
            self.allocator.free(snap.pieces);
            self.allocator.free(snap.cursors);
        }

        const redo_pieces = try self.allocator.dupe(Piece, self.pieces.items);
        errdefer self.allocator.free(redo_pieces);
        const redo_cursors = try self.allocator.dupe(Selection, current_cursors);
        errdefer self.allocator.free(redo_cursors);

        try self.redo_stack.append(self.allocator, .{
            .pieces = redo_pieces,
            .cursors = redo_cursors,
            .total_len = self.total_len,
        });

        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, snap.pieces);
        self.total_len = snap.total_len;

        out_cursors.clearRetainingCapacity();
        try out_cursors.appendSlice(self.allocator, snap.cursors);

        self.allocator.free(snap.pieces);
        self.allocator.free(snap.cursors);
        return true;
    }

    pub fn redo(self: *PieceTable, current_cursors: []const Selection, out_cursors: *std.ArrayList(Selection)) !bool {
        if (self.redo_stack.items.len == 0) return false;
        const snap = self.redo_stack.pop().?;
        errdefer {
            self.allocator.free(snap.pieces);
            self.allocator.free(snap.cursors);
        }

        const undo_pieces = try self.allocator.dupe(Piece, self.pieces.items);
        errdefer self.allocator.free(undo_pieces);
        const undo_cursors = try self.allocator.dupe(Selection, current_cursors);
        errdefer self.allocator.free(undo_cursors);

        try self.undo_stack.append(self.allocator, .{
            .pieces = undo_pieces,
            .cursors = undo_cursors,
            .total_len = self.total_len,
        });

        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, snap.pieces);
        self.total_len = snap.total_len;

        out_cursors.clearRetainingCapacity();
        try out_cursors.appendSlice(self.allocator, snap.cursors);

        self.allocator.free(snap.pieces);
        self.allocator.free(snap.cursors);
        return true;
    }
};

test "piece table insert, delete, undo, redo" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "hello world");
    defer pt.deinit();

    try pt.insert(6, "zig ", 6);
    {
        const s = try pt.materialize(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello zig world", s);
    }

    try pt.deleteRange(5, 4, 10);
    {
        const s = try pt.materialize(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello world", s);
    }

    var cursors: std.ArrayList(Selection) = .empty;
    defer cursors.deinit(alloc);

    try std.testing.expect(try pt.undo(&.{Selection.point(5)}, &cursors));
    try std.testing.expectEqualSlices(Selection, &.{Selection.point(10)}, cursors.items);
    {
        const s = try pt.materialize(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello zig world", s);
    }

    try std.testing.expect(try pt.redo(&.{Selection.point(10)}, &cursors));
    try std.testing.expectEqualSlices(Selection, &.{Selection.point(5)}, cursors.items);
    {
        const s = try pt.materialize(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello world", s);
    }
}
