const std = @import("std");
const Io = std.Io;
const core = @import("inzm_core");
const Editor = core.Editor;

var orig_termios: std.posix.termios = undefined;
var raw_enabled = false;
var needs_resize = std.atomic.Value(bool).init(false);
var signal_quit = std.atomic.Value(bool).init(false);

fn onSigWinch(_: std.posix.SIG) callconv(.c) void {
    needs_resize.store(true, .release);
}

fn onSigTerm(_: std.posix.SIG) callconv(.c) void {
    signal_quit.store(true, .release);
}

fn installSignals() void {
    const empty_mask = std.mem.zeroes(std.posix.sigset_t);
    const winch_act = std.posix.Sigaction{
        .handler = .{ .handler = onSigWinch },
        .mask = empty_mask,
        .flags = 0, // Do NOT set SA_RESTART so read() returns EINTR on resize
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &winch_act, null);

    const term_act = std.posix.Sigaction{
        .handler = .{ .handler = onSigTerm },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &term_act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &term_act, null);
}

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

    const stdin_file: Io.File = .stdin();
    if (!(stdin_file.isTty(io) catch false)) {
        std.debug.print("Error: inzm.zig requires an interactive TTY.\n", .{});
        std.process.exit(1);
    }

    enableRawMode() catch {
        std.debug.print("Error: inzm.zig requires an interactive TTY.\n", .{});
        std.process.exit(1);
    };
    defer disableRawMode();
    installSignals();

    const initial_content = Io.Dir.cwd().readFileAlloc(io, filename, alloc, .limited(16 * 1024 * 1024)) catch "";
    defer if (initial_content.len > 0) alloc.free(initial_content);

    const sz = getTerminalSize();
    var editor = try Editor.init(alloc, sz.cols, sz.rows, filename, initial_content);
    defer editor.deinit();

    const stdout: Io.File = .stdout();
    try stdout.writeStreamingAll(io, Editor.enterAltScreen());
    defer stdout.writeStreamingAll(io, Editor.leaveAltScreen()) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try editor.render(&out);
    try stdout.writeStreamingAll(io, out.items);

    var read_buf: [128]u8 = undefined;
    while (!editor.should_quit and !signal_quit.load(.acquire)) {
        const rc = std.posix.system.read(std.posix.STDIN_FILENO, &read_buf, read_buf.len);
        const n: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => {
                if (signal_quit.load(.acquire)) break;
                if (needs_resize.swap(false, .acq_rel)) {
                    const new_sz = getTerminalSize();
                    if (new_sz.cols != editor.cols or new_sz.rows != editor.rows) {
                        editor.resize(new_sz.cols, new_sz.rows);
                    }
                    out.clearRetainingCapacity();
                    try editor.render(&out);
                    try stdout.writeStreamingAll(io, out.items);
                }
                continue;
            },
            else => break,
        };
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
