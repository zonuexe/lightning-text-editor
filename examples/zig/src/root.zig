pub const PieceTable = @import("piece_table.zig").PieceTable;
pub const Editor = @import("editor.zig").Editor;
pub const unicode = @import("unicode.zig");
pub const input = @import("input.zig");

test {
    _ = @import("piece_table.zig");
    _ = @import("editor.zig");
}
