const std = @import("std");
const unicode = @import("unicode.zig");

pub const KeyEvent = union(enum) {
    char: u21,
    enter,
    backspace,
    delete,
    tab,
    up,
    down,
    right,
    left,
    home,
    end,
    page_up,
    page_down,
    word_left,
    word_right,
    doc_start,
    doc_end,
    delete_word_back,
    delete_word_forward,
    delete_to_line_start,
    shift_up,
    shift_down,
    shift_right,
    shift_left,
    shift_home,
    shift_end,
    shift_word_left,
    shift_word_right,
    shift_doc_start,
    shift_doc_end,
    select_all,
    add_cursor_up,
    add_cursor_down,
    f2,
    f3,
    ctrl: u8,
    escape,
    mouse_click: struct { col: usize, row: usize },
    mouse_drag: struct { col: usize, row: usize },
    mouse_add_cursor: struct { col: usize, row: usize },
    mouse_wheel_up,
    mouse_wheel_down,
};

pub const InputDecoder = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn pushAndNext(self: *InputDecoder, data: []const u8, events: *std.ArrayList(KeyEvent), allocator: std.mem.Allocator) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const space = self.buf.len - self.len;
            const take = @min(space, data.len - offset);
            @memcpy(self.buf[self.len .. self.len + take], data[offset .. offset + take]);
            self.len += take;
            offset += take;
            try self.drain(events, allocator, offset == data.len);
        }
        if (data.len == 0) {
            try self.drain(events, allocator, true);
        }
    }

    fn drain(self: *InputDecoder, events: *std.ArrayList(KeyEvent), allocator: std.mem.Allocator, at_chunk_end: bool) !void {
        var i: usize = 0;
        while (i < self.len) {
            const b = self.buf[i];
            if (b == 0x1B) {
                if (i + 1 >= self.len) {
                    if (at_chunk_end) {
                        try events.append(allocator, .escape);
                        i += 1;
                    } else {
                        break;
                    }
                } else if (self.buf[i + 1] == '[') {
                    var j = i + 2;
                    while (j < self.len and !(self.buf[j] >= 0x40 and self.buf[j] <= 0x7E)) : (j += 1) {}
                    if (j >= self.len) break;
                    if (parseCsi(self.buf[i + 2 .. j], self.buf[j])) |ev| {
                        try events.append(allocator, ev);
                    }
                    i = j + 1;
                } else if (self.buf[i + 1] == 'O') {
                    if (i + 2 >= self.len) break;
                    switch (self.buf[i + 2]) {
                        'H' => try events.append(allocator, .home),
                        'F' => try events.append(allocator, .end),
                        'A' => try events.append(allocator, .up),
                        'B' => try events.append(allocator, .down),
                        'C' => try events.append(allocator, .right),
                        'D' => try events.append(allocator, .left),
                        'Q' => try events.append(allocator, .f2),
                        'R' => try events.append(allocator, .f3),
                        else => {},
                    }
                    i += 3;
                } else {
                    const next = self.buf[i + 1];
                    if (next == 0x7F or next == 0x08) {
                        try events.append(allocator, .delete_word_back);
                        i += 2;
                    } else if (next == 'b' or next == 'B') {
                        try events.append(allocator, .word_left);
                        i += 2;
                    } else if (next == 'f' or next == 'F') {
                        try events.append(allocator, .word_right);
                        i += 2;
                    } else if (next == 'd' or next == 'D') {
                        try events.append(allocator, .delete_word_forward);
                        i += 2;
                    } else {
                        try events.append(allocator, .escape);
                        i += 1;
                    }
                }
            } else if (b == '\r' or b == '\n') {
                try events.append(allocator, .enter);
                if (b == '\r' and i + 1 < self.len and self.buf[i + 1] == '\n') {
                    i += 2;
                } else {
                    i += 1;
                }
            } else if (b == '\t') {
                try events.append(allocator, .tab);
                i += 1;
            } else if (b == 0x7F or b == 0x08) {
                try events.append(allocator, .backspace);
                i += 1;
            } else if (b >= 1 and b <= 26) {
                try events.append(allocator, .{ .ctrl = b + 'a' - 1 });
                i += 1;
            } else if (b >= 0x20) {
                const need = unicode.utf8CharLen(b);
                if (i + need > self.len) break;
                const dec = unicode.decodeUtf8(self.buf[i..self.len]);
                try events.append(allocator, .{ .char = dec.cp });
                i += dec.len;
            } else {
                i += 1;
            }
        }
        const rem = self.len - i;
        if (rem > 0 and i > 0) {
            std.mem.copyForwards(u8, self.buf[0..rem], self.buf[i..self.len]);
        }
        self.len = rem;
    }
};

fn parseCsi(body: []const u8, final: u8) ?KeyEvent {
    switch (final) {
        'A' => {
            if (std.mem.eql(u8, body, "1;9")) return .doc_start;
            if (std.mem.eql(u8, body, "1;2")) return .shift_up;
            if (std.mem.eql(u8, body, "1;6") or std.mem.eql(u8, body, "1;10")) return .shift_doc_start;
            if (std.mem.eql(u8, body, "1;3") or std.mem.eql(u8, body, "1;7")) return .add_cursor_up;
            return .up;
        },
        'B' => {
            if (std.mem.eql(u8, body, "1;9")) return .doc_end;
            if (std.mem.eql(u8, body, "1;2")) return .shift_down;
            if (std.mem.eql(u8, body, "1;6") or std.mem.eql(u8, body, "1;10")) return .shift_doc_end;
            if (std.mem.eql(u8, body, "1;3") or std.mem.eql(u8, body, "1;7")) return .add_cursor_down;
            return .down;
        },
        'C' => {
            if (std.mem.eql(u8, body, "1;3") or std.mem.eql(u8, body, "1;9")) return .word_right;
            if (std.mem.eql(u8, body, "1;2")) return .shift_right;
            if (std.mem.eql(u8, body, "1;4") or std.mem.eql(u8, body, "1;10")) return .shift_word_right;
            return .right;
        },
        'D' => {
            if (std.mem.eql(u8, body, "1;3") or std.mem.eql(u8, body, "1;9")) return .word_left;
            if (std.mem.eql(u8, body, "1;2")) return .shift_left;
            if (std.mem.eql(u8, body, "1;4") or std.mem.eql(u8, body, "1;10")) return .shift_word_left;
            return .left;
        },
        'H' => {
            if (std.mem.eql(u8, body, "1;5") or std.mem.eql(u8, body, "1;9")) return .doc_start;
            if (std.mem.eql(u8, body, "1;2")) return .shift_home;
            if (std.mem.eql(u8, body, "1;6") or std.mem.eql(u8, body, "1;10")) return .shift_doc_start;
            return .home;
        },
        'F' => {
            if (std.mem.eql(u8, body, "1;5") or std.mem.eql(u8, body, "1;9")) return .doc_end;
            if (std.mem.eql(u8, body, "1;2")) return .shift_end;
            if (std.mem.eql(u8, body, "1;6") or std.mem.eql(u8, body, "1;10")) return .shift_doc_end;
            return .end;
        },
        'u' => {
            if (std.mem.eql(u8, body, "127;9")) return .delete_to_line_start;
            if (std.mem.eql(u8, body, "97;9")) return .select_all;
            return null;
        },
        'M' => return parseSgrMouse(body),
        'm' => return null,
        '~' => {
            const code = if (std.mem.indexOfScalar(u8, body, ';')) |semi| body[0..semi] else body;
            if (std.mem.eql(u8, code, "1") or std.mem.eql(u8, code, "7")) return .home;
            if (std.mem.eql(u8, code, "3")) return .delete;
            if (std.mem.eql(u8, code, "4") or std.mem.eql(u8, code, "8")) return .end;
            if (std.mem.eql(u8, code, "5")) return .page_up;
            if (std.mem.eql(u8, code, "6")) return .page_down;
            if (std.mem.eql(u8, code, "12")) return .f2;
            if (std.mem.eql(u8, code, "13")) return .f3;
            return null;
        },
        else => return null,
    }
}

fn parseSgrMouse(body: []const u8) ?KeyEvent {
    if (body.len == 0 or body[0] != '<') return null;
    var it = std.mem.splitScalar(u8, body[1..], ';');
    const btn_s = it.next() orelse return null;
    const col_s = it.next() orelse return null;
    const row_s = it.next() orelse return null;
    if (it.next() != null) return null;

    const btn = std.fmt.parseInt(usize, btn_s, 10) catch return null;
    const col = std.fmt.parseInt(usize, col_s, 10) catch return null;
    const row = std.fmt.parseInt(usize, row_s, 10) catch return null;

    return switch (btn) {
        0 => .{ .mouse_click = .{ .col = col, .row = row } },
        8, 16, 24 => .{ .mouse_add_cursor = .{ .col = col, .row = row } },
        32 => .{ .mouse_drag = .{ .col = col, .row = row } },
        64 => .mouse_wheel_up,
        65 => .mouse_wheel_down,
        else => null,
    };
}
