const std = @import("std");
const Io = std.Io;
const core = @import("inzm_core");
const Editor = core.Editor;

var orig_termios: std.posix.termios = undefined;
var raw_enabled = false;

fn disableRawMode() void {
    if (raw_enabled) {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
        raw_enabled = false;
    }
}

fn enableRawMode() !void {
    orig_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = orig_termios;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    raw_enabled = true;
}

fn getTerminalSize() struct { cols: usize, rows: usize } {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDIN_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0 and ws.row > 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{ .cols = 80, .rows = 24 };
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const filename = if (args.len >= 2) args[1] else "sample.txt";

    const initial_content = Io.Dir.cwd().readFileAlloc(io, filename, alloc, .limited(16 * 1024 * 1024)) catch "";
    defer if (initial_content.len > 0) alloc.free(initial_content);

    const sz = getTerminalSize();
    var editor = try Editor.init(alloc, sz.cols, sz.rows, filename, initial_content);
    defer editor.deinit();

    try enableRawMode();
    defer disableRawMode();

    const stdout: Io.File = .stdout();
    try stdout.writeStreamingAll(io, Editor.enterAltScreen());
    defer stdout.writeStreamingAll(io, Editor.leaveAltScreen()) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try editor.render(&out);
    try stdout.writeStreamingAll(io, out.items);

    var read_buf: [128]u8 = undefined;
    while (!editor.should_quit) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &read_buf) catch break;
        if (n == 0) break;

        const cur_sz = getTerminalSize();
        if (cur_sz.cols != editor.cols or cur_sz.rows != editor.rows) {
            editor.resize(cur_sz.cols, cur_sz.rows);
        }

        try editor.feedBytes(read_buf[0..n], &out);
        if (editor.takeSaveRequest()) {
            Io.Dir.cwd().writeFile(io, .{
                .sub_path = editor.filename,
                .data = editor.flat,
            }) catch |err| {
                var ebuf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&ebuf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
                try editor.setStatus(msg);
                out.clearRetainingCapacity();
                try editor.render(&out);
                try stdout.writeStreamingAll(io, out.items);
                continue;
            };
            try editor.markSaved();
            if (!editor.should_quit) {
                out.clearRetainingCapacity();
                try editor.render(&out);
            }
        }
        try stdout.writeStreamingAll(io, out.items);
    }
}
