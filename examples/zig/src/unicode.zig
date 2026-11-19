const std = @import("std");

/// Return byte length of a UTF-8 sequence given its leading byte.
pub fn utf8CharLen(first: u8) usize {
    if (first & 0x80 == 0) return 1;
    if (first & 0xE0 == 0xC0) return 2;
    if (first & 0xF0 == 0xE0) return 3;
    if (first & 0xF8 == 0xF0) return 4;
    return 1;
}

/// Decode one UTF-8 scalar value starting at `bytes[0]`, returning value and byte count.
pub fn decodeUtf8(bytes: []const u8) struct { cp: u21, len: usize } {
    if (bytes.len == 0) return .{ .cp = 0xFFFD, .len = 0 };
    const len = utf8CharLen(bytes[0]);
    if (len == 1 or len > bytes.len) {
        return .{ .cp = bytes[0], .len = 1 };
    }
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch {
        return .{ .cp = 0xFFFD, .len = 1 };
    };
    return .{ .cp = cp, .len = len };
}

fn isZeroWidth(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0x3099 and cp <= 0x309A) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or
        (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isAmbiguousWidth(cp: u21) bool {
    return (cp >= 0x0391 and cp <= 0x03C9) or
        (cp >= 0x0410 and cp <= 0x044F) or
        cp == 0x00A7 or
        cp == 0x00B0 or
        cp == 0x00B1 or
        cp == 0x00D7 or
        cp == 0x00F7 or
        (cp >= 0x2190 and cp <= 0x2199) or
        (cp >= 0x2460 and cp <= 0x249B) or
        (cp >= 0x2500 and cp <= 0x257F) or
        (cp >= 0x25A0 and cp <= 0x25FF) or
        (cp >= 0x2605 and cp <= 0x2606) or
        cp == 0x203B;
}

fn isWideChar(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        cp == 0x2329 or
        cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3040 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF01 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFF);
}

/// Return terminal cell width (0, 1, or 2) for a Unicode code point.
pub fn charWidth(cp: u21, is_eaw: bool) usize {
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (isZeroWidth(cp)) return 0;
    if (isWideChar(cp)) return 2;
    if (is_eaw and isAmbiguousWidth(cp)) return 2;
    return 1;
}

/// Return rendered terminal cell width at column `col`, including tab expansion and control char sanitization.
pub fn displayWidthAt(cp: u21, col: usize, is_eaw: bool) usize {
    if (cp == '\t') return 4 - (col % 4);
    if (cp < 0x20 or cp == 0x7F) return 2;
    if (cp >= 0x80 and cp < 0xA0) return 1;
    return charWidth(cp, is_eaw);
}

/// Return terminal-safe bytes for `cp` at column `col` (avoiding raw control/ESC output).
pub fn sanitizeSlice(cp: u21, slice: []const u8, col: usize, buf: *[4]u8) []const u8 {
    if (cp == '\t') {
        const tw = 4 - (col % 4);
        @memset(buf[0..tw], ' ');
        return buf[0..tw];
    }
    if (cp < 0x20) {
        buf[0] = '^';
        buf[1] = @intCast(cp + 64);
        return buf[0..2];
    }
    if (cp == 0x7F) {
        buf[0] = '^';
        buf[1] = '?';
        return buf[0..2];
    }
    if (cp >= 0x80 and cp < 0xA0) {
        buf[0] = '?';
        return buf[0..1];
    }
    return slice;
}

/// Compute total terminal cell width of a UTF-8 byte slice.
pub fn strWidth(text: []const u8, is_eaw: bool) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeUtf8(text[i..]);
        if (d.len == 0) break;
        w += displayWidthAt(d.cp, w, is_eaw);
        i += d.len;
    }
    return w;
}

/// Find the byte index of the previous UTF-8 codepoint boundary before `pos`.
pub fn prevBoundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = @min(pos, text.len) - 1;
    while (p > 0 and (text[p] & 0xC0) == 0x80) {
        p -= 1;
    }
    return p;
}

/// Find the byte index of the next UTF-8 codepoint boundary after `pos`.
pub fn nextBoundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    const len = utf8CharLen(text[pos]);
    return @min(pos + len, text.len);
}
