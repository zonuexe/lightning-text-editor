const std = @import("std");
const core = @import("inzm_core");
const Editor = core.Editor;

// Growable heap for freestanding wasm32 (memory.grow). Zero WASI or OS dependencies.
// FixedBufferAllocator can only free its most recent allocation, so per-keystroke
// cache rebuilds would exhaust it after a few hundred keystrokes.
const alloc = std.heap.wasm_allocator;

var in_buf: [1024 * 1024]u8 = undefined;
var fname_buf: [256]u8 = undefined;
var out_buf: std.ArrayList(u8) = .empty;
var sel_buf: std.ArrayList(u8) = .empty;
var editor: ?Editor = null;

export fn wasm_in_ptr() [*]u8 {
    return &in_buf;
}

export fn wasm_in_cap() usize {
    return in_buf.len;
}

export fn wasm_fname_ptr() [*]u8 {
    return &fname_buf;
}

export fn wasm_out_ptr() [*]const u8 {
    return out_buf.items.ptr;
}

export fn wasm_content_ptr() [*]const u8 {
    if (editor) |*ed| return ed.flat.ptr;
    return &fname_buf;
}

export fn wasm_content_len() usize {
    if (editor) |*ed| return ed.flat.len;
    return 0;
}

export fn wasm_selected_ptr() [*]const u8 {
    return sel_buf.items.ptr;
}

export fn wasm_selected_len() usize {
    const ed = &(editor orelse return 0);
    sel_buf.clearRetainingCapacity();
    const s = ed.selectedTextAlloc(alloc) catch return 0;
    defer alloc.free(s);
    sel_buf.appendSlice(alloc, s) catch return 0;
    return sel_buf.items.len;
}

export fn wasm_delete_selected() usize {
    const ed = &(editor orelse return 0);
    _ = ed.deleteSelectionsOnly() catch return 0;
    out_buf.clearRetainingCapacity();
    ed.render(&out_buf) catch return 0;
    return out_buf.items.len;
}

export fn wasm_should_quit() u32 {
    if (editor) |*ed| return if (ed.should_quit) 1 else 0;
    return 0;
}

export fn wasm_take_save_request() u32 {
    if (editor) |*ed| return if (ed.takeSaveRequest()) 1 else 0;
    return 0;
}

export fn wasm_init(cols: usize, rows: usize, fname_len: usize, content_len: usize) usize {
    if (editor) |*ed| {
        ed.deinit();
        editor = null;
    }
    out_buf.deinit(alloc);
    out_buf = .empty;
    sel_buf.deinit(alloc);
    sel_buf = .empty;

    const fname = fname_buf[0..@min(fname_len, fname_buf.len)];
    const content = in_buf[0..@min(content_len, in_buf.len)];

    editor = Editor.init(alloc, cols, rows, fname, content) catch return 0;
    out_buf.appendSlice(alloc, Editor.enterAltScreen()) catch return 0;
    editor.?.render(&out_buf) catch return 0;
    return out_buf.items.len;
}

export fn wasm_load_file(fname_len: usize, content_len: usize) usize {
    const ed = &(editor orelse return 0);
    const fname = fname_buf[0..@min(fname_len, fname_buf.len)];
    const content = in_buf[0..@min(content_len, in_buf.len)];
    ed.loadFile(fname, content) catch return 0;
    out_buf.clearRetainingCapacity();
    ed.render(&out_buf) catch return 0;
    return out_buf.items.len;
}

export fn wasm_on_data(data_len: usize) usize {
    const ed = &(editor orelse return 0);
    const slice = in_buf[0..@min(data_len, in_buf.len)];
    ed.feedBytes(slice, &out_buf) catch return 0;
    return out_buf.items.len;
}

export fn wasm_on_resize(cols: usize, rows: usize) usize {
    const ed = &(editor orelse return 0);
    ed.resize(cols, rows);
    out_buf.clearRetainingCapacity();
    ed.render(&out_buf) catch return 0;
    return out_buf.items.len;
}

export fn wasm_mark_saved() usize {
    const ed = &(editor orelse return 0);
    ed.markSaved() catch return 0;
    out_buf.clearRetainingCapacity();
    ed.render(&out_buf) catch return 0;
    return out_buf.items.len;
}
