# Zig版 クイックリファレンス (termios / wasm32-freestanding)

Zig は単一のツールチェーンだけで **OS ネイティブの高速な CLI バイナリ** と **依存ゼロ・数十 KB の `wasm32-freestanding` ブラウザバイナリ** の両方を即座にビルドできます。

---

## ⚡️ クイックスタート

```bash
mkdir my-zig-editor && cd my-zig-editor
# build.zig と src/main.zig を用意して実行
zig build run
```

参照実装（Piece Table + 無制限 Undo/Redo + Live Inspector + ブラウザ WASM 対応）の全体は [`examples/zig/`](../examples/zig/) をご覧ください。

---

## ⌨️ ターミナル生モード (`std.posix.tcgetattr` / `tcsetattr`)

Zig 0.17.1+ では `termios` のフラグが `packed struct` として定義されており、ビットマスク演算ではなくフィールド名で安全にオン/オフできます：

```zig
const std = @import("std");

var orig_termios: std.posix.termios = undefined;

fn enableRawMode() !void {
    orig_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = orig_termios;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode() void {
    // 実際のアプリでは \x1b[?1049l\x1b[?25h\x1b[0m を標準出力へ flush してから復元する
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
}
```

---

## 🌐 ブラウザ WASM 向け (`wasm32-freestanding`)

`build.zig` で `.cpu_arch = .wasm32, .os_tag = .freestanding` を指定し、`std.heap.FixedBufferAllocator` を使うと、WASI シムも JS String Builtins も不要で全ブラウザ互換の超小型 `.wasm` が作れます（詳細は [docs/browser-wasm-runtime.md](../docs/browser-wasm-runtime.md) 参照）。

```zig
// build.zig
const wasm_target = b.resolveTargetQuery(.{
    .cpu_arch = .wasm32,
    .os_tag = .freestanding,
});
wasm_exe.entry = .disabled;
wasm_exe.rdynamic = true;
wasm_exe.export_memory = true;
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`std.testing.allocator` でリークを即検知する**:
   - Zig のエディタコアは `Allocator` を引数で受け取る構造にしておくと、テスト時に `std.testing.allocator` を渡すだけで解放忘れ（特に Undo/Redo 履歴や文字列キャッシュ）を自動検出できます。
2. **Zig 0.17 の `std.ArrayList` と `std.Io`**:
   - `std.ArrayList(T)` はアンマネージド形式（`.empty` 初期化、`.append(alloc, item)` 等）になっており、ファイル I/O は `main(init: std.process.Init)` で渡される `init.io` を `std.Io.Dir.cwd()` へ渡して行います。
3. **WASM 側のメモリバッファサイズ**:
   - `wasm32-freestanding` で `FixedBufferAllocator` を使う場合、大きなファイルや長い編集履歴を扱うときは静的ヒープサイズ（例: 4 MiB）と入力ステージングバッファの上限を意識し、`wasm_init` 時には `fba.reset()` で綺麗に初期化します。
