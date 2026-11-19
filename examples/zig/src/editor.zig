const std = @import("std");
const Allocator = std.mem.Allocator;
const pt_mod = @import("piece_table.zig");
const PieceTable = pt_mod.PieceTable;
const Selection = pt_mod.Selection;
const unicode = @import("unicode.zig");
const input = @import("input.zig");
const KeyEvent = input.KeyEvent;

pub const LineSpan = struct {
    start: usize,
    end: usize, // excludes '\n' (and '\r' before '\n')
};

pub const Editor = struct {
    allocator: Allocator,
    pt: PieceTable,
    flat: []u8,
    lines: std.ArrayList(LineSpan),
    cursors: std.ArrayList(Selection),
    primary_idx: usize,
    row_offset: usize,
    col_offset: usize,
    cols: usize,
    rows: usize,
    filename: []u8,
    is_modified: bool,
    quit_confirm: bool,
    should_quit: bool,
    save_requested: bool,
    is_eaw: bool,
    show_inspector: bool,
    search_mode: bool,
    search_query: std.ArrayList(u8),
    multi_word_query: std.ArrayList(u8),
    status_message: []u8,
    decoder: input.InputDecoder,

    pub fn init(allocator: Allocator, cols: usize, rows: usize, filename: []const u8, content: []const u8) !Editor {
        var pt = try PieceTable.init(allocator, content);
        errdefer pt.deinit();

        const fname = try allocator.dupe(u8, if (filename.len == 0) "untitled.txt" else filename);
        errdefer allocator.free(fname);

        const msg = try allocator.dupe(
            u8,
            "Shift+Arrows/Drag: Select | Ctrl+D: +Cursor | Ctrl+Z/Y: Undo/Redo | F2: Inspector | Ctrl+S: Save | Ctrl+Q: Quit",
        );
        errdefer allocator.free(msg);

        var cursors: std.ArrayList(Selection) = .empty;
        errdefer cursors.deinit(allocator);
        try cursors.append(allocator, Selection.point(0));

        var ed: Editor = .{
            .allocator = allocator,
            .pt = pt,
            .flat = &.{},
            .lines = .empty,
            .cursors = cursors,
            .primary_idx = 0,
            .row_offset = 0,
            .col_offset = 0,
            .cols = @max(cols, 24),
            .rows = @max(rows, 6),
            .filename = fname,
            .is_modified = false,
            .quit_confirm = false,
            .should_quit = false,
            .save_requested = false,
            .is_eaw = false,
            .show_inspector = true,
            .search_mode = false,
            .search_query = .empty,
            .multi_word_query = .empty,
            .status_message = msg,
            .decoder = .{},
        };
        try ed.refreshCache();
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        self.pt.deinit();
        if (self.flat.len > 0) self.allocator.free(self.flat);
        self.lines.deinit(self.allocator);
        self.cursors.deinit(self.allocator);
        self.search_query.deinit(self.allocator);
        self.multi_word_query.deinit(self.allocator);
        self.allocator.free(self.filename);
        self.allocator.free(self.status_message);
    }

    pub fn loadFile(self: *Editor, filename: []const u8, content: []const u8) !void {
        var new_pt = try PieceTable.init(self.allocator, content);
        errdefer new_pt.deinit();
        const new_fname = try self.allocator.dupe(u8, if (filename.len == 0) "untitled.txt" else filename);
        errdefer self.allocator.free(new_fname);

        self.pt.deinit();
        self.pt = new_pt;
        self.allocator.free(self.filename);
        self.filename = new_fname;
        self.cursors.clearRetainingCapacity();
        try self.cursors.append(self.allocator, Selection.point(0));
        self.primary_idx = 0;
        self.row_offset = 0;
        self.col_offset = 0;
        self.is_modified = false;
        self.quit_confirm = false;
        self.should_quit = false;
        self.save_requested = false;
        self.search_mode = false;
        self.multi_word_query.clearRetainingCapacity();
        try self.refreshCache();
        try self.setStatusFmt("Opened {s} ({d} bytes, {d} lines)", .{ self.filename, self.flat.len, self.lines.items.len });
    }

    pub fn resize(self: *Editor, cols: usize, rows: usize) void {
        self.cols = @max(cols, 24);
        self.rows = @max(rows, 6);
        self.ensureCursorVisible();
    }

    pub fn enterAltScreen() []const u8 {
        return "\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H";
    }

    pub fn leaveAltScreen() []const u8 {
        return "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1049l\x1b[?25h\x1b[0m";
    }

    pub fn takeSaveRequest(self: *Editor) bool {
        const v = self.save_requested;
        self.save_requested = false;
        return v;
    }

    pub fn markSaved(self: *Editor) !void {
        self.is_modified = false;
        self.quit_confirm = false;
        try self.setStatusFmt("Saved {s} ({d} bytes)", .{ self.filename, self.flat.len });
    }

    pub fn setStatus(self: *Editor, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        self.allocator.free(self.status_message);
        self.status_message = copy;
    }

    fn setStatusFmt(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
        try self.setStatus(msg);
    }

    pub fn primarySelection(self: *const Editor) Selection {
        if (self.cursors.items.len == 0) return Selection.point(0);
        const idx = @min(self.primary_idx, self.cursors.items.len - 1);
        return self.cursors.items[idx];
    }

    pub fn primaryCursor(self: *const Editor) usize {
        return self.primarySelection().head;
    }

    pub fn selectedTextAlloc(self: *const Editor, allocator: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var first = true;
        for (self.cursors.items) |sel| {
            if (sel.isEmpty()) continue;
            if (!first) try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, self.flat[sel.start()..sel.end()]);
            first = false;
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn totalSelectedBytes(self: *const Editor) usize {
        var sum: usize = 0;
        for (self.cursors.items) |sel| {
            sum += sel.end() - sel.start();
        }
        return sum;
    }

    pub fn deleteSelectionsOnly(self: *Editor) !bool {
        if (self.totalSelectedBytes() == 0) return false;
        try self.deleteAll(.back_char);
        return true;
    }

    fn refreshCache(self: *Editor) !void {
        const next_flat = try self.pt.materialize(self.allocator);
        errdefer self.allocator.free(next_flat);

        self.lines.clearRetainingCapacity();
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < next_flat.len) : (i += 1) {
            if (next_flat[i] == '\n') {
                const line_end = if (i > line_start and next_flat[i - 1] == '\r') i - 1 else i;
                try self.lines.append(self.allocator, .{ .start = line_start, .end = line_end });
                line_start = i + 1;
            }
        }
        if (next_flat.len == 0 or line_start < next_flat.len or next_flat[next_flat.len - 1] == '\n') {
            try self.lines.append(self.allocator, .{ .start = line_start, .end = next_flat.len });
        }

        if (self.flat.len > 0) self.allocator.free(self.flat);
        self.flat = next_flat;
        for (self.cursors.items) |*sel| {
            sel.anchor = @min(sel.anchor, self.flat.len);
            sel.head = @min(sel.head, self.flat.len);
        }
    }

    fn selectionLessThan(_: void, a: Selection, b: Selection) bool {
        if (a.start() != b.start()) return a.start() < b.start();
        if (a.end() != b.end()) return a.end() < b.end();
        return a.head < b.head;
    }

    fn normalizeCursors(self: *Editor, preferred_head: ?usize) void {
        if (self.cursors.items.len == 0) {
            self.cursors.append(self.allocator, Selection.point(0)) catch return;
            self.primary_idx = 0;
            return;
        }
        for (self.cursors.items) |*sel| {
            sel.anchor = @min(sel.anchor, self.flat.len);
            sel.head = @min(sel.head, self.flat.len);
        }
        const target_head = preferred_head orelse self.primaryCursor();
        std.mem.sort(Selection, self.cursors.items, {}, selectionLessThan);

        var write_idx: usize = 1;
        for (self.cursors.items[1..]) |next_sel| {
            const prev_sel = &self.cursors.items[write_idx - 1];
            const overlaps = next_sel.start() < prev_sel.end() or
                (next_sel.start() == prev_sel.end() and (prev_sel.isEmpty() or next_sel.isEmpty()));
            if (overlaps) {
                const merged_start = @min(prev_sel.start(), next_sel.start());
                const merged_end = @max(prev_sel.end(), next_sel.end());
                if (next_sel.head >= prev_sel.head) {
                    prev_sel.anchor = merged_start;
                    prev_sel.head = merged_end;
                } else {
                    prev_sel.anchor = merged_end;
                    prev_sel.head = merged_start;
                }
            } else {
                self.cursors.items[write_idx] = next_sel;
                write_idx += 1;
            }
        }
        self.cursors.shrinkRetainingCapacity(write_idx);

        self.primary_idx = self.cursors.items.len - 1;
        for (self.cursors.items, 0..) |sel, idx| {
            if (sel.head == target_head) {
                self.primary_idx = idx;
                break;
            }
        }
    }

    fn containsSelectionRange(self: *const Editor, s: usize, e: usize) bool {
        for (self.cursors.items) |sel| {
            if (sel.start() == s and sel.end() == e) return true;
        }
        return false;
    }

    fn inspectorRows(self: *const Editor) usize {
        return if (self.show_inspector and self.rows >= 10) 3 else 0;
    }

    fn textRows(self: *const Editor) usize {
        const reserved = 2 + self.inspectorRows();
        return if (self.rows > reserved) self.rows - reserved else 1;
    }

    fn gutterWidth(self: *const Editor) usize {
        var n = self.lines.items.len;
        var digits: usize = 1;
        while (n >= 10) : (n /= 10) {
            digits += 1;
        }
        return @max(digits, 3) + 1;
    }

    fn lineColAt(self: *const Editor, offset: usize) struct { line: usize, col_byte: usize } {
        for (self.lines.items, 0..) |sp, idx| {
            const next_start = if (idx + 1 < self.lines.items.len) self.lines.items[idx + 1].start else self.flat.len + 1;
            if (offset < next_start or idx + 1 == self.lines.items.len) {
                const col_b = if (offset > sp.start) @min(offset - sp.start, sp.end - sp.start) else 0;
                return .{ .line = idx, .col_byte = col_b };
            }
        }
        return .{ .line = 0, .col_byte = 0 };
    }

    fn visualXAt(self: *const Editor, offset: usize) usize {
        const lc = self.lineColAt(offset);
        const sp = self.lines.items[lc.line];
        return unicode.strWidth(self.flat[sp.start .. sp.start + lc.col_byte], self.is_eaw);
    }

    fn textCols(self: *const Editor) usize {
        const gw = self.gutterWidth();
        return if (self.cols > gw + 1) self.cols - gw - 1 else 1;
    }

    fn ensureCursorVisible(self: *Editor) void {
        const head = self.primaryCursor();
        const lc = self.lineColAt(head);
        const visible_rows = self.textRows();
        if (lc.line < self.row_offset) {
            self.row_offset = lc.line;
        }
        if (lc.line >= self.row_offset + visible_rows) {
            self.row_offset = lc.line - visible_rows + 1;
        }
        const text_cols = self.textCols();
        const vx = self.visualXAt(head);
        if (vx < self.col_offset) {
            self.col_offset = vx;
        }
        if (vx >= self.col_offset + text_cols) {
            self.col_offset = vx - text_cols + 1;
        }
    }

    fn moveOffsetVertical(self: *const Editor, offset: usize, delta: isize) usize {
        const lc = self.lineColAt(offset);
        const vx = self.visualXAt(offset);
        const cur_i: isize = @intCast(lc.line);
        const max_i: isize = @intCast(self.lines.items.len - 1);
        const target_i = std.math.clamp(cur_i + delta, 0, max_i);
        const target_line: usize = @intCast(target_i);
        return self.byteOffsetAtVisualCol(target_line, vx);
    }

    fn byteOffsetAtVisualCol(self: *const Editor, line_idx: usize, target_vx: usize) usize {
        const sp = self.lines.items[line_idx];
        const line_slice = self.flat[sp.start..sp.end];
        var vx: usize = 0;
        var i: usize = 0;
        while (i < line_slice.len) {
            const d = unicode.decodeUtf8(line_slice[i..]);
            if (d.len == 0) break;
            const w = unicode.displayWidthAt(d.cp, vx, self.is_eaw);
            if (vx + w > target_vx) break;
            vx += w;
            i += d.len;
        }
        return sp.start + i;
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
    }

    fn prevWordPos(self: *const Editor, from: usize) usize {
        var pos = @min(from, self.flat.len);
        while (pos > 0 and (self.flat[pos - 1] == ' ' or self.flat[pos - 1] == '\t')) : (pos -= 1) {}
        if (pos == 0) return 0;
        if (self.flat[pos - 1] == '\n') return pos - 1;
        const word = isWordByte(self.flat[pos - 1]);
        while (pos > 0 and self.flat[pos - 1] != ' ' and self.flat[pos - 1] != '\t' and self.flat[pos - 1] != '\n' and isWordByte(self.flat[pos - 1]) == word) : (pos -= 1) {}
        return pos;
    }

    fn nextWordPos(self: *const Editor, from: usize) usize {
        var pos = @min(from, self.flat.len);
        if (pos >= self.flat.len) return self.flat.len;
        if (self.flat[pos] == '\n') return pos + 1;
        if (self.flat[pos] != ' ' and self.flat[pos] != '\t') {
            const word = isWordByte(self.flat[pos]);
            while (pos < self.flat.len and self.flat[pos] != ' ' and self.flat[pos] != '\t' and self.flat[pos] != '\n' and isWordByte(self.flat[pos]) == word) : (pos += 1) {}
        }
        while (pos < self.flat.len and (self.flat[pos] == ' ' or self.flat[pos] == '\t')) : (pos += 1) {}
        return pos;
    }

    fn shiftSelectionSlice(items: []Selection, delta: isize) void {
        for (items) |*sel| {
            sel.anchor = @intCast(@as(isize, @intCast(sel.anchor)) + delta);
            sel.head = @intCast(@as(isize, @intCast(sel.head)) + delta);
        }
    }

    fn insertAll(self: *Editor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.pt.pushUndo(self.cursors.items);
        const p_idx = @min(self.primary_idx, self.cursors.items.len - 1);

        var idx = self.cursors.items.len;
        while (idx > 0) {
            idx -= 1;
            const sel = self.cursors.items[idx];
            const s = sel.start();
            const del_len = sel.end() - s;
            if (del_len > 0) {
                try self.pt.deleteRangeRaw(s, del_len);
            }
            try self.pt.insertRaw(s, bytes);
            self.cursors.items[idx] = Selection.point(s + bytes.len);
            const delta: isize = @as(isize, @intCast(bytes.len)) - @as(isize, @intCast(del_len));
            if (delta != 0) {
                shiftSelectionSlice(self.cursors.items[idx + 1 ..], delta);
            }
        }

        const next_primary = self.cursors.items[p_idx].head;
        self.is_modified = true;
        try self.refreshCache();
        self.normalizeCursors(next_primary);
    }

    const DeleteKind = enum {
        back_char,
        forward_char,
        word_back,
        word_forward,
        to_line_start,
    };

    fn deleteAll(self: *Editor, kind: DeleteKind) !void {
        const has_sel = self.totalSelectedBytes() > 0;
        if (!has_sel) {
            var any_change = false;
            for (self.cursors.items) |sel| {
                const pos = sel.head;
                const ok = switch (kind) {
                    .back_char, .word_back => pos > 0,
                    .forward_char, .word_forward => pos < self.flat.len,
                    .to_line_start => pos > self.lines.items[self.lineColAt(pos).line].start,
                };
                if (ok) {
                    any_change = true;
                    break;
                }
            }
            if (!any_change) return;
        }

        try self.pt.pushUndo(self.cursors.items);
        const p_idx = @min(self.primary_idx, self.cursors.items.len - 1);

        var idx = self.cursors.items.len;
        while (idx > 0) {
            idx -= 1;
            const sel = self.cursors.items[idx];
            if (!sel.isEmpty()) {
                const s = sel.start();
                const del_len = sel.end() - s;
                try self.pt.deleteRangeRaw(s, del_len);
                self.cursors.items[idx] = Selection.point(s);
                shiftSelectionSlice(self.cursors.items[idx + 1 ..], -@as(isize, @intCast(del_len)));
                continue;
            }
            if (has_sel) continue;

            const pos = sel.head;
            const min_bound: usize = if (idx > 0) self.cursors.items[idx - 1].end() else 0;
            const range: struct { start: usize, end: usize } = switch (kind) {
                .back_char => blk: {
                    const prev = @max(unicode.prevBoundary(self.flat, pos), min_bound);
                    break :blk .{ .start = prev, .end = pos };
                },
                .forward_char => blk: {
                    const next = unicode.nextBoundary(self.flat, pos);
                    break :blk .{ .start = pos, .end = next };
                },
                .word_back => blk: {
                    const prev = @max(self.prevWordPos(pos), min_bound);
                    break :blk .{ .start = prev, .end = pos };
                },
                .word_forward => blk: {
                    const next = self.nextWordPos(pos);
                    break :blk .{ .start = pos, .end = next };
                },
                .to_line_start => blk: {
                    const line_start = @max(self.lines.items[self.lineColAt(pos).line].start, min_bound);
                    break :blk .{ .start = line_start, .end = pos };
                },
            };

            if (range.end > range.start) {
                const del_len = range.end - range.start;
                try self.pt.deleteRangeRaw(range.start, del_len);
                self.cursors.items[idx] = Selection.point(range.start);
                shiftSelectionSlice(self.cursors.items[idx + 1 ..], -@as(isize, @intCast(del_len)));
            }
        }

        const next_primary = self.cursors.items[p_idx].head;
        self.is_modified = true;
        try self.refreshCache();
        self.normalizeCursors(next_primary);
    }

    fn findNextMatch(self: *const Editor, query: []const u8, start_from: usize) ?usize {
        if (query.len == 0 or query.len > self.flat.len) return null;
        if (start_from <= self.flat.len) {
            if (std.mem.indexOf(u8, self.flat[start_from..], query)) |rel| {
                return start_from + rel;
            }
        }
        if (std.mem.indexOf(u8, self.flat, query)) |abs| {
            return abs;
        }
        return null;
    }

    fn wordBoundsAt(self: *const Editor, pos: usize) ?struct { start: usize, end: usize } {
        if (self.flat.len == 0) return null;
        var anchor = @min(pos, self.flat.len);
        if (anchor == self.flat.len or !isWordByte(self.flat[anchor])) {
            if (anchor > 0 and isWordByte(self.flat[anchor - 1])) {
                anchor -= 1;
            } else {
                return null;
            }
        }
        var s = anchor;
        while (s > 0 and isWordByte(self.flat[s - 1])) : (s -= 1) {}
        var e = anchor;
        while (e < self.flat.len and isWordByte(self.flat[e])) : (e += 1) {}
        if (e <= s) return null;
        return .{ .start = s, .end = e };
    }

    fn addNextOccurrence(self: *Editor) !void {
        const primary = self.primarySelection();
        // First Ctrl+D when primary cursor has no selection: select the word under cursor.
        if (self.cursors.items.len == 1 and primary.isEmpty()) {
            if (self.wordBoundsAt(primary.head)) |b| {
                self.multi_word_query.clearRetainingCapacity();
                try self.multi_word_query.appendSlice(self.allocator, self.flat[b.start..b.end]);
                self.cursors.items[0] = .{ .anchor = b.start, .head = b.end };
                try self.setStatusFmt("Selected \"{s}\" (Ctrl+D again for next match)", .{self.multi_word_query.items});
                return;
            }
            if (self.search_query.items.len == 0) {
                try self.setStatus("Move onto a word or select text for Ctrl+D");
                return;
            }
        }

        if (!primary.isEmpty()) {
            self.multi_word_query.clearRetainingCapacity();
            try self.multi_word_query.appendSlice(self.allocator, self.flat[primary.start()..primary.end()]);
        } else if (self.multi_word_query.items.len == 0 and self.search_query.items.len > 0) {
            try self.multi_word_query.appendSlice(self.allocator, self.search_query.items);
        }

        const q = self.multi_word_query.items;
        if (q.len == 0 or q.len > self.flat.len) return;

        const start_scan = @min(primary.end(), self.flat.len);
        var cand_pos = self.findNextMatch(q, start_scan);
        var checked: usize = 0;
        while (cand_pos) |m| {
            const m_end = m + q.len;
            if (!self.containsSelectionRange(m, m_end)) {
                try self.cursors.append(self.allocator, .{ .anchor = m, .head = m_end });
                self.normalizeCursors(m_end);
                try self.setStatusFmt("Selected \"{s}\" ({d} cursors)", .{ q, self.cursors.items.len });
                return;
            }
            checked += 1;
            if (checked >= self.flat.len) break;
            const next_from = @min(m + q.len, self.flat.len);
            cand_pos = self.findNextMatch(q, next_from);
            if (cand_pos != null and cand_pos.? == m) break;
        }
        try self.setStatusFmt("All occurrences of \"{s}\" selected ({d} cursors)", .{ q, self.cursors.items.len });
    }

    fn addCursorVertical(self: *Editor, delta: isize) !void {
        const edge = if (delta < 0) self.cursors.items[0].head else self.cursors.items[self.cursors.items.len - 1].head;
        const target = self.moveOffsetVertical(edge, delta);
        if (!self.containsSelectionRange(target, target)) {
            try self.cursors.append(self.allocator, Selection.point(target));
            self.normalizeCursors(target);
        }
        try self.setStatusFmt("Multi-cursor ({d} cursors, Esc to collapse)", .{self.cursors.items.len});
    }

    fn moveCursors(self: *Editor, ev: KeyEvent, extend: bool) void {
        const p_idx = @min(self.primary_idx, self.cursors.items.len - 1);
        for (self.cursors.items) |*sel| {
            const next_head: usize = switch (ev) {
                .up, .shift_up => self.moveOffsetVertical(sel.head, -1),
                .down, .shift_down => self.moveOffsetVertical(sel.head, 1),
                .left, .shift_left => blk: {
                    if (!extend and !sel.isEmpty()) break :blk sel.start();
                    break :blk unicode.prevBoundary(self.flat, sel.head);
                },
                .right, .shift_right => blk: {
                    if (!extend and !sel.isEmpty()) break :blk sel.end();
                    break :blk unicode.nextBoundary(self.flat, sel.head);
                },
                .home, .shift_home => self.lines.items[self.lineColAt(sel.head).line].start,
                .end, .shift_end => self.lines.items[self.lineColAt(sel.head).line].end,
                .word_left, .shift_word_left => self.prevWordPos(sel.head),
                .word_right, .shift_word_right => self.nextWordPos(sel.head),
                .doc_start, .shift_doc_start => 0,
                .doc_end, .shift_doc_end => self.flat.len,
                .page_up => self.moveOffsetVertical(sel.head, -@as(isize, @intCast(self.textRows()))),
                .page_down => self.moveOffsetVertical(sel.head, @as(isize, @intCast(self.textRows()))),
                .ctrl => |c| switch (c) {
                    'p' => self.moveOffsetVertical(sel.head, -1),
                    'n' => self.moveOffsetVertical(sel.head, 1),
                    'b' => unicode.prevBoundary(self.flat, sel.head),
                    'a' => self.lines.items[self.lineColAt(sel.head).line].start,
                    'e' => self.lines.items[self.lineColAt(sel.head).line].end,
                    else => sel.head,
                },
                else => sel.head,
            };
            sel.head = next_head;
            if (!extend) sel.anchor = next_head;
        }
        const next_primary = self.cursors.items[p_idx].head;
        self.normalizeCursors(next_primary);
    }

    fn handleSearchKey(self: *Editor, ev: KeyEvent) !void {
        switch (ev) {
            .escape => {
                self.search_mode = false;
                try self.setStatus("Search cancelled");
                return;
            },
            .ctrl => |c| {
                if (c == 'g' or c == 'c') {
                    self.search_mode = false;
                    try self.setStatus("Search cancelled");
                    return;
                }
                if (c == 'f') {
                    const from = @min(self.primaryCursor() + 1, self.flat.len);
                    if (self.findNextMatch(self.search_query.items, from)) |pos| {
                        self.cursors.clearRetainingCapacity();
                        try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos + self.search_query.items.len });
                        self.primary_idx = 0;
                    }
                    return;
                }
            },
            .enter, .f3 => {
                const from = @min(self.primaryCursor() + 1, self.flat.len);
                if (self.findNextMatch(self.search_query.items, from)) |pos| {
                    self.cursors.clearRetainingCapacity();
                    try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos + self.search_query.items.len });
                    self.primary_idx = 0;
                    try self.setStatusFmt("Match at byte {d} (Enter/F3: next, Esc: done)", .{pos});
                } else {
                    try self.setStatus("No match found");
                }
            },
            .backspace => {
                if (self.search_query.items.len > 0) {
                    const prev = unicode.prevBoundary(self.search_query.items, self.search_query.items.len);
                    self.search_query.shrinkRetainingCapacity(prev);
                    if (self.findNextMatch(self.search_query.items, 0)) |pos| {
                        self.cursors.clearRetainingCapacity();
                        try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos + self.search_query.items.len });
                        self.primary_idx = 0;
                    }
                }
            },
            .char => |cp| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &enc) catch return;
                try self.search_query.appendSlice(self.allocator, enc[0..len]);
                if (self.findNextMatch(self.search_query.items, self.primarySelection().start())) |pos| {
                    self.cursors.clearRetainingCapacity();
                    try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos + self.search_query.items.len });
                    self.primary_idx = 0;
                }
            },
            else => {
                self.search_mode = false;
                try self.handleKey(ev);
            },
        }
    }

    fn offsetFromClick(self: *const Editor, col1: usize, row1: usize) ?usize {
        const visible = self.textRows();
        if (row1 < 1 or row1 > visible) return null;
        const target_line = self.row_offset + (row1 - 1);
        if (target_line >= self.lines.items.len) {
            return self.flat.len;
        }
        const gw = self.gutterWidth();
        const rel_col = if (col1 > gw + 1) col1 - 1 - gw else 0;
        const target_vx = self.col_offset + rel_col;
        return self.byteOffsetAtVisualCol(target_line, target_vx);
    }

    fn handleClick(self: *Editor, col1: usize, row1: usize) void {
        const pos = self.offsetFromClick(col1, row1) orelse return;
        self.cursors.clearRetainingCapacity();
        self.cursors.append(self.allocator, Selection.point(pos)) catch return;
        self.primary_idx = 0;
        self.multi_word_query.clearRetainingCapacity();
    }

    fn handleDrag(self: *Editor, col1: usize, row1: usize) void {
        const pos = self.offsetFromClick(col1, row1) orelse return;
        const idx = @min(self.primary_idx, self.cursors.items.len - 1);
        const anchor = self.cursors.items[idx].anchor;
        self.cursors.clearRetainingCapacity();
        self.cursors.append(self.allocator, .{ .anchor = anchor, .head = pos }) catch return;
        self.primary_idx = 0;
    }

    fn handleAddCursorClick(self: *Editor, col1: usize, row1: usize) !void {
        const pos = self.offsetFromClick(col1, row1) orelse return;
        for (self.cursors.items, 0..) |sel, idx| {
            if (sel.head == pos and sel.isEmpty()) {
                if (self.cursors.items.len > 1) {
                    _ = self.cursors.orderedRemove(idx);
                    self.normalizeCursors(null);
                    try self.setStatusFmt("Removed cursor ({d} cursors)", .{self.cursors.items.len});
                }
                return;
            }
        }
        try self.cursors.append(self.allocator, Selection.point(pos));
        self.normalizeCursors(pos);
        try self.setStatusFmt("Added cursor ({d} cursors, Esc to collapse)", .{self.cursors.items.len});
    }

    fn scrollViewport(self: *Editor, delta: isize) void {
        const visible = self.textRows();
        const max_offset: isize = if (self.lines.items.len > visible)
            @intCast(self.lines.items.len - visible)
        else
            0;
        const cur: isize = @intCast(self.row_offset);
        self.row_offset = @intCast(std.math.clamp(cur + delta, 0, max_offset));
    }

    pub fn handleKey(self: *Editor, ev: KeyEvent) anyerror!void {
        if (ev != .ctrl or ev.ctrl != 'q') {
            self.quit_confirm = false;
        }
        if (self.search_mode) {
            try self.handleSearchKey(ev);
            self.ensureCursorVisible();
            return;
        }

        switch (ev) {
            .doc_start => {
                self.cursors.clearRetainingCapacity();
                try self.cursors.append(self.allocator, Selection.point(0));
                self.primary_idx = 0;
            },
            .doc_end => {
                self.cursors.clearRetainingCapacity();
                try self.cursors.append(self.allocator, Selection.point(self.flat.len));
                self.primary_idx = 0;
            },
            .up, .down, .left, .right, .home, .end, .word_left, .word_right, .page_up, .page_down => self.moveCursors(ev, false),
            .shift_up, .shift_down, .shift_left, .shift_right, .shift_home, .shift_end, .shift_word_left, .shift_word_right, .shift_doc_start, .shift_doc_end => self.moveCursors(ev, true),
            .select_all => {
                self.cursors.clearRetainingCapacity();
                try self.cursors.append(self.allocator, .{ .anchor = 0, .head = self.flat.len });
                self.primary_idx = 0;
                try self.setStatusFmt("Selected all ({d} bytes)", .{self.flat.len});
            },
            .add_cursor_up => try self.addCursorVertical(-1),
            .add_cursor_down => try self.addCursorVertical(1),
            .enter => try self.insertAll("\n"),
            .tab => try self.insertAll("  "),
            .backspace => try self.deleteAll(.back_char),
            .delete => try self.deleteAll(.forward_char),
            .delete_word_back => try self.deleteAll(.word_back),
            .delete_word_forward => try self.deleteAll(.word_forward),
            .delete_to_line_start => try self.deleteAll(.to_line_start),
            .char => |cp| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &enc) catch return;
                try self.insertAll(enc[0..len]);
            },
            .f2 => {
                self.show_inspector = !self.show_inspector;
                try self.setStatus(if (self.show_inspector) "Piece Table Inspector ON" else "Piece Table Inspector OFF");
            },
            .f3 => {
                if (self.search_query.items.len > 0) {
                    const from = @min(self.primaryCursor() + 1, self.flat.len);
                    if (self.findNextMatch(self.search_query.items, from)) |pos| {
                        self.cursors.clearRetainingCapacity();
                        try self.cursors.append(self.allocator, .{ .anchor = pos, .head = pos + self.search_query.items.len });
                        self.primary_idx = 0;
                    }
                }
            },
            .ctrl => |c| switch (c) {
                'd' => try self.addNextOccurrence(),
                'z' => {
                    var restored: std.ArrayList(Selection) = .empty;
                    defer restored.deinit(self.allocator);
                    if (try self.pt.undo(self.cursors.items, &restored)) {
                        self.cursors.clearRetainingCapacity();
                        try self.cursors.appendSlice(self.allocator, restored.items);
                        self.is_modified = true;
                        try self.refreshCache();
                        self.normalizeCursors(null);
                        try self.setStatusFmt("Undo (remaining: {d}, cursors: {d})", .{ self.pt.undo_stack.items.len, self.cursors.items.len });
                    } else {
                        try self.setStatus("Nothing to undo");
                    }
                },
                'y' => {
                    var restored: std.ArrayList(Selection) = .empty;
                    defer restored.deinit(self.allocator);
                    if (try self.pt.redo(self.cursors.items, &restored)) {
                        self.cursors.clearRetainingCapacity();
                        try self.cursors.appendSlice(self.allocator, restored.items);
                        self.is_modified = true;
                        try self.refreshCache();
                        self.normalizeCursors(null);
                        try self.setStatusFmt("Redo (remaining: {d}, cursors: {d})", .{ self.pt.redo_stack.items.len, self.cursors.items.len });
                    } else {
                        try self.setStatus("Nothing to redo");
                    }
                },
                'f' => {
                    self.search_mode = true;
                    self.search_query.clearRetainingCapacity();
                    try self.setStatus("Incremental Search (type to jump, Enter/F3: next, Esc: close)");
                },
                'g' => {
                    self.show_inspector = !self.show_inspector;
                    try self.setStatus(if (self.show_inspector) "Piece Table Inspector ON" else "Piece Table Inspector OFF");
                },
                's' => {
                    self.save_requested = true;
                    try self.setStatusFmt("Saving {s}...", .{self.filename});
                },
                'q' => {
                    if (self.is_modified and !self.quit_confirm) {
                        self.quit_confirm = true;
                        try self.setStatus("Unsaved changes! Press Ctrl+Q again to quit without saving.");
                    } else {
                        self.should_quit = true;
                    }
                },
                't' => {
                    self.is_eaw = !self.is_eaw;
                    try self.setStatus(if (self.is_eaw) "Ambiguous width: EAW=2 (Wide)" else "Ambiguous width: EAW=1 (Narrow)");
                },
                'p', 'n', 'b', 'a', 'e' => self.moveCursors(ev, false),
                else => {},
            },
            .mouse_click => |m| self.handleClick(m.col, m.row),
            .mouse_drag => |m| self.handleDrag(m.col, m.row),
            .mouse_add_cursor => |m| try self.handleAddCursorClick(m.col, m.row),
            .mouse_wheel_up => self.scrollViewport(-3),
            .mouse_wheel_down => self.scrollViewport(3),
            .escape => {
                if (self.cursors.items.len > 1 or !self.primarySelection().isEmpty()) {
                    const keep = self.primaryCursor();
                    self.cursors.clearRetainingCapacity();
                    try self.cursors.append(self.allocator, Selection.point(keep));
                    self.primary_idx = 0;
                    self.multi_word_query.clearRetainingCapacity();
                    try self.setStatus("Cleared selection / extra cursors");
                }
            },
        }

        switch (ev) {
            .mouse_wheel_up, .mouse_wheel_down => {},
            else => self.ensureCursorVisible(),
        }
    }

    pub fn feedBytes(self: *Editor, bytes: []const u8, out: *std.ArrayList(u8)) !void {
        var events: std.ArrayList(KeyEvent) = .empty;
        defer events.deinit(self.allocator);
        try self.decoder.pushAndNext(bytes, &events, self.allocator);
        for (events.items) |ev| {
            if (self.should_quit) break;
            try self.handleKey(ev);
        }
        out.clearRetainingCapacity();
        if (self.should_quit) {
            try out.appendSlice(self.allocator, Editor.leaveAltScreen());
        } else {
            try self.render(out);
        }
    }

    pub fn render(self: *const Editor, out: *std.ArrayList(u8)) !void {
        const gw = self.gutterWidth();
        const num_w = gw - 1;
        const visible_rows = self.textRows();
        const text_cols = self.textCols();

        try out.appendSlice(self.allocator, "\x1b[?2026h\x1b[?25l\x1b[H");
        var tmp: [256]u8 = undefined;

        for (0..visible_rows) |row| {
            const file_row = self.row_offset + row;
            if (file_row < self.lines.items.len) {
                const sp = self.lines.items[file_row];
                const num_s = try std.fmt.bufPrint(&tmp, "{d}", .{file_row + 1});
                try out.appendSlice(self.allocator, "\x1b[90m");
                var pad = if (num_w > num_s.len) num_w - num_s.len else 0;
                while (pad > 0) : (pad -= 1) try out.append(self.allocator, ' ');
                try out.appendSlice(self.allocator, num_s);
                try out.appendSlice(self.allocator, " \x1b[0m");
                try self.renderLineSlice(out, sp.start, sp.end, text_cols);
            } else {
                try out.appendSlice(self.allocator, "\x1b[90m");
                var pad = if (num_w > 1) num_w - 1 else 0;
                while (pad > 0) : (pad -= 1) try out.append(self.allocator, ' ');
                try out.appendSlice(self.allocator, "~ \x1b[0m");
            }
            try out.appendSlice(self.allocator, "\x1b[K\r\n");
        }

        if (self.inspectorRows() > 0) {
            try self.renderInspector(out);
        }

        const primary_head = self.primaryCursor();
        const lc = self.lineColAt(primary_head);
        const mod_s: []const u8 = if (self.is_modified) " [+]" else "";
        const eaw_s: []const u8 = if (self.is_eaw) "EAW:2" else "EAW:1";
        const sel_bytes = self.totalSelectedBytes();
        var left_buf: [160]u8 = undefined;
        var right_buf: [224]u8 = undefined;
        var extra_buf: [64]u8 = undefined;

        const left_s = std.fmt.bufPrint(&left_buf, " inzm.zig - {s}{s} ", .{ self.filename, mod_s }) catch " inzm.zig ";
        const extra_s = if (self.cursors.items.len > 1 and sel_bytes > 0)
            std.fmt.bufPrint(&extra_buf, " ({d} cursors, {d}B sel)", .{ self.cursors.items.len, sel_bytes }) catch ""
        else if (self.cursors.items.len > 1)
            std.fmt.bufPrint(&extra_buf, " ({d} cursors)", .{self.cursors.items.len}) catch ""
        else if (sel_bytes > 0)
            std.fmt.bufPrint(&extra_buf, " (Sel:{d}B)", .{sel_bytes}) catch ""
        else
            "";

        const right_s = std.fmt.bufPrint(
            &right_buf,
            " Ln {d}, Col {d}{s} | P:{d} U:{d} R:{d} | {s} ",
            .{ lc.line + 1, lc.col_byte + 1, extra_s, self.pt.pieces.items.len, self.pt.undo_stack.items.len, self.pt.redo_stack.items.len, eaw_s },
        ) catch "";

        const status_cols = if (self.cols > 1) self.cols - 1 else 1;
        try out.appendSlice(self.allocator, "\x1b[7m");
        const lw = unicode.strWidth(left_s, self.is_eaw);
        const rw = unicode.strWidth(right_s, self.is_eaw);
        if (lw + rw <= status_cols) {
            const used_l = try self.appendTruncated(out, left_s, status_cols);
            var spaces = if (status_cols > used_l + rw) status_cols - used_l - rw else 0;
            while (spaces > 0) : (spaces -= 1) try out.append(self.allocator, ' ');
            _ = try self.appendTruncated(out, right_s, status_cols - used_l);
        } else if (rw <= status_cols) {
            const avail = status_cols - rw;
            const used = try self.appendTruncated(out, left_s, avail);
            var spaces = if (avail > used) avail - used else 0;
            while (spaces > 0) : (spaces -= 1) try out.append(self.allocator, ' ');
            _ = try self.appendTruncated(out, right_s, rw);
        } else {
            _ = try self.appendTruncated(out, right_s, status_cols);
        }
        try out.appendSlice(self.allocator, "\x1b[0m\x1b[K\r\n");

        const safe_msg_cols = if (self.cols > 1) self.cols - 1 else 1;
        if (self.search_mode) {
            try out.appendSlice(self.allocator, "\x1b[33mSearch: \x1b[0m");
            _ = try self.appendTruncated(out, self.search_query.items, if (safe_msg_cols > 8) safe_msg_cols - 8 else 1);
            try out.appendSlice(self.allocator, "\x1b[K");
        } else {
            try out.appendSlice(self.allocator, "\x1b[36m");
            _ = try self.appendTruncated(out, self.status_message, safe_msg_cols);
            try out.appendSlice(self.allocator, "\x1b[0m\x1b[K");
        }

        const vx = self.visualXAt(primary_head);
        if (lc.line >= self.row_offset and lc.line < self.row_offset + visible_rows and vx >= self.col_offset and vx < self.col_offset + text_cols) {
            const sy = lc.line - self.row_offset + 1;
            const sx = gw + (vx - self.col_offset) + 1;
            const pos_s = try std.fmt.bufPrint(&tmp, "\x1b[{d};{d}H\x1b[?25h", .{ sy, sx });
            try out.appendSlice(self.allocator, pos_s);
        }
        try out.appendSlice(self.allocator, "\x1b[?2026l");
    }

    fn isSecondaryHeadAt(self: *const Editor, abs_pos: usize) bool {
        for (self.cursors.items, 0..) |sel, idx| {
            if (idx != self.primary_idx and sel.head == abs_pos) return true;
        }
        return false;
    }

    fn isByteSelected(self: *const Editor, abs_pos: usize) bool {
        for (self.cursors.items) |sel| {
            if (abs_pos >= sel.start() and abs_pos < sel.end()) return true;
        }
        return false;
    }

    fn renderLineSlice(self: *const Editor, out: *std.ArrayList(u8), line_start: usize, line_end: usize, max_cols: usize) !void {
        const line = self.flat[line_start..line_end];
        const query = self.search_query.items;
        const do_hl = self.search_mode and query.len > 0;

        var x: usize = 0;
        var out_w: usize = 0;
        var i: usize = 0;
        var hl_active = false;
        var hl_end_idx: usize = 0;

        while (i < line.len) {
            if (do_hl and !hl_active and i + query.len <= line.len and std.mem.eql(u8, line[i .. i + query.len], query)) {
                hl_active = true;
                hl_end_idx = i + query.len;
            }
            const abs_pos = line_start + i;
            const is_sec = self.isSecondaryHeadAt(abs_pos);
            const is_sel = self.isByteSelected(abs_pos);

            const d = unicode.decodeUtf8(line[i..]);
            if (d.len == 0) break;
            const w = unicode.displayWidthAt(d.cp, x, self.is_eaw);
            var san_buf: [4]u8 = undefined;
            const disp = unicode.sanitizeSlice(d.cp, line[i .. i + d.len], x, &san_buf);
            if (x + w <= self.col_offset) {
                x += w;
                i += d.len;
                if (hl_active and i >= hl_end_idx) hl_active = false;
                continue;
            }
            if (x < self.col_offset and x + w > self.col_offset) {
                var pad = x + w - self.col_offset;
                while (pad > 0 and out_w < max_cols) : (pad -= 1) {
                    try out.append(self.allocator, ' ');
                    out_w += 1;
                }
                x += w;
                i += d.len;
                if (hl_active and i >= hl_end_idx) hl_active = false;
                continue;
            }
            if (out_w + w > max_cols) break;

            if (is_sec) {
                try out.appendSlice(self.allocator, "\x1b[46;30m");
            } else if (is_sel) {
                try out.appendSlice(self.allocator, "\x1b[44;97m");
            } else if (hl_active) {
                try out.appendSlice(self.allocator, "\x1b[43;30m");
            }
            try out.appendSlice(self.allocator, disp);
            if (is_sec or is_sel or hl_active) {
                try out.appendSlice(self.allocator, "\x1b[0m");
            }
            x += w;
            out_w += w;
            i += d.len;
            if (hl_active and i >= hl_end_idx) hl_active = false;
        }

        if (x >= self.col_offset and out_w < max_cols) {
            if (self.isSecondaryHeadAt(line_end)) {
                try out.appendSlice(self.allocator, "\x1b[46;30m \x1b[0m");
            } else if (line_end < self.flat.len and self.isByteSelected(line_end)) {
                try out.appendSlice(self.allocator, "\x1b[44;97m \x1b[0m");
            }
        }
    }

    fn renderInspector(self: *const Editor, out: *std.ArrayList(u8)) !void {
        const safe_cols = if (self.cols > 1) self.cols - 1 else 1;
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &hdr_buf,
            "── Piece Table Inspector (F2/Ctrl+G) ── pieces:{d}  orig:{d}B  add:{d}B  undo:{d}  redo:{d}  cursors:{d}  primary:@{d} ──",
            .{ self.pt.pieces.items.len, self.pt.original.len, self.pt.add_buf.items.len, self.pt.undo_stack.items.len, self.pt.redo_stack.items.len, self.cursors.items.len, self.primaryCursor() },
        ) catch "── Piece Table Inspector ──";
        try out.appendSlice(self.allocator, "\x1b[90m");
        _ = try self.appendTruncated(out, hdr, safe_cols);
        try out.appendSlice(self.allocator, "\x1b[0m\x1b[K\r\n");

        var cur_w: usize = 0;
        var row_idx: usize = 0;
        for (self.pt.pieces.items, 0..) |piece, idx| {
            var chip_buf: [64]u8 = undefined;
            const tag: u8 = if (piece.source == .original) 'O' else 'A';
            var preview_buf: [16]u8 = undefined;
            const slice = self.pt.pieceSlice(piece);
            var p_len: usize = 0;
            for (slice) |ch| {
                if (p_len >= 10) break;
                if (ch == '\n') {
                    if (p_len + 2 <= preview_buf.len) {
                        preview_buf[p_len] = '\\';
                        preview_buf[p_len + 1] = 'n';
                        p_len += 2;
                    }
                } else if (ch >= 0x20 and ch < 0x7F) {
                    preview_buf[p_len] = ch;
                    p_len += 1;
                } else if (ch >= 0x80) {
                    preview_buf[p_len] = '*';
                    p_len += 1;
                }
            }
            const chip = std.fmt.bufPrint(
                &chip_buf,
                "[{c}:{d}..{d} \"{s}\"] ",
                .{ tag, piece.start, piece.start + piece.len, preview_buf[0..p_len] },
            ) catch continue;

            if (cur_w + chip.len > safe_cols) {
                try out.appendSlice(self.allocator, "\x1b[K\r\n");
                row_idx += 1;
                cur_w = 0;
                if (row_idx >= 2) break;
            }
            if (piece.source == .original) {
                try out.appendSlice(self.allocator, "\x1b[36m");
            } else {
                try out.appendSlice(self.allocator, "\x1b[32m");
            }
            try out.appendSlice(self.allocator, chip);
            try out.appendSlice(self.allocator, "\x1b[0m");
            cur_w += chip.len;
            if (idx + 1 == self.pt.pieces.items.len) break;
        }
        while (row_idx < 2) : (row_idx += 1) {
            try out.appendSlice(self.allocator, "\x1b[K\r\n");
        }
    }

    fn appendTruncated(self: *const Editor, out: *std.ArrayList(u8), s: []const u8, max_cols: usize) !usize {
        var w: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const d = unicode.decodeUtf8(s[i..]);
            if (d.len == 0) break;
            const cw = unicode.displayWidthAt(d.cp, w, self.is_eaw);
            if (w + cw > max_cols) break;
            var san_buf: [4]u8 = undefined;
            const disp = unicode.sanitizeSlice(d.cp, s[i .. i + d.len], w, &san_buf);
            try out.appendSlice(self.allocator, disp);
            w += cw;
            i += d.len;
        }
        return w;
    }
};

test "editor typing, undo/redo, search, and mouse wheel" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 20, "demo.txt", "hello world\nsecond line");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try ed.feedBytes("\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[Czig ", &out);
    try std.testing.expectEqualStrings("hello zig world\nsecond line", ed.flat);

    try ed.feedBytes("\x1a", &out);
    try std.testing.expectEqualStrings("hello zigworld\nsecond line", ed.flat);

    try ed.feedBytes("\x19", &out);
    try std.testing.expectEqualStrings("hello zig world\nsecond line", ed.flat);

    try ed.feedBytes("\x06second", &out);
    try std.testing.expectEqual(@as(usize, 16), ed.primarySelection().start());
}

test "editor japanese word delete, mouse click, viewport wheel, inspector toggle" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 12, "ja.txt", "first\nあいう\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try ed.feedBytes("\x1b[<0;7;2MX", &out);
    try std.testing.expect(std.mem.indexOf(u8, ed.flat, "あXいう") != null);

    try ed.feedBytes("\x07\x1b[<0;5;1M\x1b[<65;5;1M", &out);
    try std.testing.expectEqual(@as(usize, 0), ed.primaryCursor());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?25h") == null);

    var ed2 = try Editor.init(alloc, 80, 12, "w.txt", "hello world");
    defer ed2.deinit();
    try ed2.feedBytes("\x1b[F\x1b\x7f", &out);
    try std.testing.expectEqualStrings("hello ", ed2.flat);
}

test "editor range selection via shift arrows, mouse drag, select all, and replace" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 20, "sel.txt", "hello world\nsecond line");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Shift+Right 5 times selects "hello"
    try ed.feedBytes("\x1b[1;2C\x1b[1;2C\x1b[1;2C\x1b[1;2C\x1b[1;2C", &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[44;97m") != null);
    {
        const s = try ed.selectedTextAlloc(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("hello", s);
    }

    // Typing replaces selected "hello"
    try ed.feedBytes("hi", &out);
    try std.testing.expectEqualStrings("hi world\nsecond line", ed.flat);

    // Mouse press at row 1 col 8 ('w') then drag to row 2 col 11 ('d')
    try ed.feedBytes("\x1b[<0;8;1M\x1b[<32;11;2M", &out);
    {
        const s = try ed.selectedTextAlloc(alloc);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("world\nsecond", s);
    }
    try ed.feedBytes("\x7f", &out);
    try std.testing.expectEqualStrings("hi  line", ed.flat);

    // Undo restores "hi world\nsecond line" and selection!
    try ed.feedBytes("\x1a", &out);
    try std.testing.expectEqualStrings("hi world\nsecond line", ed.flat);
    try std.testing.expectEqual(@as(usize, 12), ed.totalSelectedBytes());

    // SelectAll + replace
    try ed.feedBytes("\x1b[97;9uZ", &out);
    try std.testing.expectEqualStrings("Z", ed.flat);
}

test "editor multi-cursor ctrl+d word selection, atomic undo/redo, and collapse" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 20, "multi.txt", "foo one\nfoo two\nfoo three");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // First Ctrl+D selects "foo", next two Ctrl+D select the 2nd & 3rd "foo"
    try ed.feedBytes("\x04\x04\x04", &out);
    try std.testing.expectEqual(@as(usize, 3), ed.cursors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[44;97m") != null);

    // Typing "bar" replaces all 3 selected "foo"s in one go
    try ed.feedBytes("bar", &out);
    try std.testing.expectEqualStrings("bar one\nbar two\nbar three", ed.flat);

    // Single Ctrl+Z undoes 'r' at all 3 cursors
    try ed.feedBytes("\x1a", &out);
    try std.testing.expectEqualStrings("ba one\nba two\nba three", ed.flat);
    try std.testing.expectEqual(@as(usize, 3), ed.cursors.items.len);

    try ed.feedBytes("\x19", &out);
    try std.testing.expectEqualStrings("bar one\nbar two\nbar three", ed.flat);

    // Esc collapses back to 1 cursor (line 3), then Home + Option+Up adds cursor on line 2
    try ed.feedBytes("\x1b", &out);
    try std.testing.expectEqual(@as(usize, 1), ed.cursors.items.len);

    try ed.feedBytes("\x1b[H\x1b[1;3A!", &out);
    try std.testing.expectEqualStrings("bar one\n!bar two\n!bar three", ed.flat);
}

test "editor bracketed paste preserves literal tab, newlines, and suppresses shortcuts" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 20, "paste.txt", "");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Paste with literal tab, CRLF, Ctrl+Q (\x11), Ctrl+D (\x04), Backspace (\x7f),
    // and split end marker "\x1b[201" + "~"
    try ed.feedBytes("\x1b[200~a\tb\r\nc\x11\x04\x7fd\x1b[201", &out);
    try std.testing.expect(!ed.should_quit);
    try ed.feedBytes("~", &out);
    try std.testing.expectEqualStrings("a\tb\nc\x11\x04\x7fd", ed.flat);

    // After paste ends, Tab inserts two spaces and Ctrl+Q triggers quit guard
    try ed.feedBytes("\t!", &out);
    try std.testing.expectEqualStrings("a\tb\nc\x11\x04\x7fd  !", ed.flat);
    try ed.feedBytes("\x11", &out);
    try std.testing.expect(!ed.should_quit);
    try ed.feedBytes("\x11", &out);
    try std.testing.expect(ed.should_quit);
}

test "editor sanitizes filename, control chars, tabs, and limits lines to cols - 1" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc, 80, 20, "bad\x1b[31m\x07\tname.txt", "\tX\n\x01Y");
    defer ed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try ed.render(&out);
    // Raw escape / bell in filename must be sanitized in the status bar fast path
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "bad^[[31m^G") != null);
    // Buffer tab and control char are sanitized in rendered body
    try std.testing.expect(std.mem.indexOf(u8, out.items, "    X") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "^AY") != null);

    // Narrow terminal (cols=24): body stops at text_cols = 24 - 4 - 1 = 19 chars
    var narrow = try Editor.init(alloc, 24, 10, "n.txt", "012345678901234567890123456789");
    defer narrow.deinit();
    out.clearRetainingCapacity();
    try narrow.render(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "0123456789012345678\x1b[K") != null);
}
