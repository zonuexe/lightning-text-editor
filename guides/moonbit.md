# MoonBit版 クイックリファレンス (WasmGC / WASI)

MoonBit は WebAssembly をファーストクラスターゲットとして設計された言語です。  
**エディタのコアロジックを「入力を受け取って ANSI 文字列を返す純粋なステートマシン」として実装する**ことで、同じコードから **ブラウザ向け Web アプリ (`--target wasm-gc`)** と **WASI CLI バイナリ (`--target wasm`)** の両方を小さく高速にビルドできます。

---

## ⚡️ クイックスタート

```bash
# MoonBit CLI インストール (未導入の場合)
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

moon new my_editor --user you --name my_editor
cd my_editor
moon test --target wasm-gc
```

参照実装の全体は [`examples/moonbit/`](../examples/moonbit/) をご覧ください。

---

## 🧱 最小プロジェクト骨格 & MoonBit 文法クイックチェック

MoonBit は Rust や TOML とは構文が異なります（`Cargo.toml` / `[package]` / `impl` / `&mut self` / `i32` / `#[test]` ではなく、MoonBit 独自の DSL と型を使います）：

```moonbit
// moon.mod （TOML ではなくフラットなキー = 値形式。moon new でも生成される）
name = "you/my_editor"
version = "0.1.0"
preferred_target = "wasm"
```

```moonbit
// moon.pkg （標準ライブラリ以外を使う場合のみ import を書く。空でも可）
import {
  "moonbitlang/core/encoding/utf8",
}
```

```moonbit
// editor.mbt （moon.pkg と同じディレクトリに置く。サブディレクトリを使う場合は各ディレクトリにも moon.pkg が必要）
pub struct Editor {
  mut lines : Array[String]
  mut cursor_x : Int
  mut cursor_y : Int
}

pub fn Editor::new(content : String) -> Editor {
  { lines: [content], cursor_x: 0, cursor_y: 0 }
}

pub fn Editor::insert_char(self : Editor, ch : Char) -> Unit {
  self.lines[self.cursor_y] = self.lines[self.cursor_y] + ch.to_string()
  self.cursor_x += 1
}

///|
test "insert_char" {
  let ed = Editor::new("a")
  ed.insert_char('b')
  assert_eq(ed.lines[0], "ab")
}
```

- 文字列操作には `Array[Char]`（`for ch in s { ... }` で Unicode スカラー値列挙、`String::from_array(...)`）を使い、サロゲート／マルチバイト境界を壊さないようにします。
- `*.mbt` ファイルと `moon.pkg` は同じパッケージディレクトリに配置し、`moon test` 実行時にテストが実際に認識・通過していること（`Total tests > 0`）を確認してください（`moon.pkg` のない `src/` 等へソースを置くとテストが検出されず空ビルドになることがあります）。

---

## 🧩 ブラウザアプリ (`--target wasm-gc` + JS String Builtins)

`moon.pkg` で `use-js-builtin-string: true` を有効にすると、MoonBit の `String` をそのまま JavaScript の文字列として受け渡しできます。

```moonbit
// cmd/web/moon.pkg
options(
  "is-main": false,
  link: {
    "wasm-gc": {
      "use-js-builtin-string": true,
      "exports": ["init_editor", "on_data", "on_resize"],
    },
  },
)
```

ブラウザ側（JS/TS）では `builtins: ["js-string"]` を渡してインスタンス化し、`xterm.js` の `term.onData` と直結します：

```typescript
const mod = await WebAssembly.compile(bytes, {
  builtins: ["js-string"],
  importedStringConstants: "_",
});
const { exports } = await WebAssembly.instantiate(mod, {});
term.write(exports.init_editor(term.cols, term.rows, "sample.txt", text));
term.onData((data) => term.write(exports.on_data(data)));
```

---

## 🖥 WASI Preview 1 CLI (`--target wasm`)

外部パッケージを使わずに `wasi_snapshot_preview1` を直接 `extern` 宣言すると、`wasmtime` などの標準 WASI ランタイム単体で動くバイナリが作れます。

```moonbit
#unsafe_skip_stub_check
#borrow(iovs, nread)
fn wasi_fd_read(
  fd : Int,
  iovs : FixedArray[Int],
  iovs_len : Int,
  nread : FixedArray[Int],
) -> Int = "wasi_snapshot_preview1" "fd_read"
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **WASI には `termios`（Raw Mode）と端末サイズ取得 API がない（＆非 ASCII 入力の扱い）**:
   - `wasmtime` 等をそのまま起動するとシェルが Cooked Mode のままになり、1文字ずつ入力が届きません。CLI 起動時はラッパースクリプトで `stty raw -echo` を設定し、`trap` で終了時に必ず元へ戻してください（`examples/moonbit/run-wasi.sh` 参照）。
   - WASI の `fd_read` で読み込んだバイト列をコアへ渡す際は、`if b < 128` 等で非 ASCII バイトを捨てず、UTF-8 増分デコードを通して日本語等も扱えるようにします。
2. **`moon.mod` / `moon.pkg` 形式と文字列リテラルの `\u{1B}`**:
   - 最近の MoonBit ツールチェーンでは旧 `moon.mod.json` が非推奨/非サポートになっており、DSL 形式の `moon.mod` / `moon.pkg` を使います。また、文字列内のエスケープ文字は `\x1b` ではなく `\u{1B}` を使うと警告が出ません。
3. **`--target wasm` の線形メモリ FFI でバッファが早期解放される問題**:
   - `FixedArray[Byte]` や `Bytes` の先頭アドレスを取り出して `iovs` や `argv_buf` を経由して WASI に渡す場合、そのバッファへの参照が WASI 呼び出し後に残っていないと RC（参照カウント）によって解放・上書きされることがあります。読み出し側で配列要素を直接参照するか、呼び出し後に `#borrow` 付きダミー FFI で生存期間を保証してください。
4. **ブラウザでのショートカット衝突と IME / SKK 対策**:
   - `xterm.js` 上で `Ctrl+S` / `Cmd+S`（ページ保存）や `Ctrl+D` / `Cmd+D`（ブックマーク）がブラウザに奪われないよう、`term.attachCustomKeyEventHandler` で `ev.preventDefault()` を呼びます（ただし IME 変換中 `ev.isComposing || ev.keyCode === 229` は素通りさせること）。
   - **SKK 系 IME（AquaSKK / macSKK）の「`aaa` → `aaa`」問題**: `xterm.js` は通常文字の `keydown` で即座に `preventDefault()` するため、漢字変換（composition）を開始せず直接 `insertText` する SKK 入力がバイパスされます。単一文字キーおよび macOS の `Ctrl+J` は `attachCustomKeyEventHandler` で `preventDefault()` せずに `return false` し、`term.textarea` の `input` イベント（`inputType === "insertText"`）から確定文字を受け取ることで解決できます。
   - **macOS `Option` キー**: `macOptionIsMeta: true` を全体に有効にすると JIS キーボードの `Option+¥`（`\`）等が入力できなくなるため、`Option+矢印` / `Option+Backspace/Delete` だけを個別に制御シーケンスへマップします。
5. **マウスクリック & ビューポート専用ホイールスクロール**:
   - SGR 1006（`\x1b[?1000h\x1b[?1006h`、ドラッグ選択も取る場合は `\x1b[?1002h\x1b[?1006h`）を有効にすると、`xterm.js` ブラウザ版と WASI CLI 版の両方でクリック移動・ホイールスクロールが動きます。ホイール時は `row_offset` のみ更新し、`render()` 内で無条件に `ensure_cursor_visible()` を呼ばないことで「カーソルを引っ張らずに画面だけスクロール」できます（ブラウザ全体の設計指針は [docs/browser-wasm-runtime.md](../docs/browser-wasm-runtime.md) を参照）。
6. **`$HOME/.moon/bin` の PATH 解決**:
   - `bun run` 等から呼ばれる非ログインシェルでも動くよう、`package.json` スクリプトや `run-wasi.sh` で `PATH="$HOME/.moon/bin:$PATH"` を補っておくと安心です。
