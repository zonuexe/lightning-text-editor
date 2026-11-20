# inzm.mbt - MoonBit (WASM ブラウザアプリ & WASI Preview 1 CLI 両対応) 実装サンプル

MoonBit で実装された、**同じエディタコアから「ブラウザ上の Web アプリ（WasmGC + xterm.js）」と「WASI Preview 1 CLI バイナリ（wasmtime 等）」の両方にビルドできる**テキストエディタの参照実装です。

---

## 🌟 特徴

1. **イベント駆動コア + 薄型ホスト（Browser / WASI 両対応アーキテクチャ）**:
   - コアパッケージ（`Editor`, `InputDecoder`, Unicode幅計算）は OS・WASI・DOM に一切依存しない純粋なステートマシンとして実装。
   - **ブラウザ版 (`cmd/web`)**: `--target wasm-gc` + `use-js-builtin-string: true` で約 30 KB の `.wasm` にビルドし、`xterm.js` の `onData` / `onResize` とゼロコピー文字列受け渡しで直結（`SharedArrayBuffer` / COOP・COEP ヘッダ不要）。
   - **WASI CLI 版 (`cmd/wasi`)**: `--target wasm` で純粋な `wasi_snapshot_preview1` インポートのみ（`fd_read`, `fd_write`, `args_get`, `environ_get`, `path_open`, `fd_close`）を使った約 37 KB の単一 `.wasm` バイナリを生成し、`wasmtime` 等でそのまま動作。
2. **日本語・絵文字のセル幅計算 & EAW トグル (`Ctrl+T`)**:
   - 全角文字（ひらがな・カタカナ・漢字・絵文字）を 2 セル、結合文字を 0 セルとして水平スクロールやカーソル座標を追従。
   - ステータスバーにカーソル下文字の Unicode コードポイント（`U+XXXX`）とセル幅を表示。
   - `Ctrl+T` で曖昧文字（`※`, `★`, `α` 等）の幅を `EAW:1` / `EAW:2` でリアルタイム切替可能。
3. **分割到着に強いストリーミングデコーダ**:
   - WASI `fd_read` や `xterm.js` のチャンク分割に備え、UTF-8 マルチバイト文字と ANSI エスケープシーケンスの途中切れをバッファリングして復元。
4. **基本編集操作 + 安全終了ガード**:
   - 矢印キー、`Home`/`End`、`PageUp`/`PageDown`、`Tab`、行複製 (`Ctrl+D`)、行カット (`Ctrl+K`)、ペースト (`Ctrl+U`)、保存 (`Ctrl+S`)、未保存終了確認付き終了 (`Ctrl+Q`)。

---

## 📂 ディレクトリ構成

```text
examples/moonbit/
├── moon.mod              # MoonBit モジュール定義
├── moon.pkg              # コアパッケージ依存設定 (@encoding/utf8)
├── unicode.mbt           # Unicode セル幅計算・U+XXXX フォーマット
├── input.mbt             # ストリーミング UTF-8 / ANSI エスケープシーケンスデコーダ
├── editor.mbt            # 環境非依存の Editor ステートマシン & ANSI レンダラ
├── inzm_test.mbt         # コア動作のユニットテスト (`moon test`)
├── cmd/
│   ├── web/              # ブラウザ向け WasmGC エクスポート (`use-js-builtin-string`)
│   └── wasi/             # 純粋 WASI Preview 1 CLI エントリ & バインディング
├── web/                  # Vite + xterm.js ブラウザアプリ
├── run-wasi.sh           # stty raw -echo を安全に管理して wasmtime を起動するラッパー
├── sample.txt            # テスト用サンプルテキスト
└── package.json          # ビルド・開発サーバ起動スクリプト
```

---

## 🚀 ビルド & 起動

### 1. ブラウザアプリとしてビルド & 起動（WasmGC + xterm.js）

```bash
cd examples/moonbit
bun install

# 開発サーバ起動 (WasmGC ビルド + Vite)
bun run dev

# 静的サイトとしてビルド (web/dist/ に出力)
bun run build
bun run preview
```

ブラウザ上では `Open File` でローカルファイルを開いたり、`Ctrl+S` で `localStorage` へ保存、`Download` ボタンでファイル保存が可能です。

> **ブラウザ要件**: `WebAssembly` の `builtins: ["js-string"]`（JS String Builtins）に対応したモダンブラウザ（Chrome 130+ / Edge 130+ / Firefox 134+ 等）で動作します。

### 2. WASI Preview 1 CLI としてビルド & 起動（wasmtime）

WASI にはまだ `termios`（Raw Mode）の標準 API がないため、付属の `run-wasi.sh` がホスト側シェルを一時的に `stty raw -echo` に切り替え、`COLUMNS` / `LINES` を環境変数で渡して `wasmtime --dir=.` を実行します（終了時は `trap` で確実に元の端末状態へ復元します）。

```bash
cd examples/moonbit

# WASI バイナリ単体ビルド
bun run build:wasi

# 端末で起動（要 wasmtime）
./run-wasi.sh sample.txt
```

### 3. テストの実行

```bash
cd examples/moonbit
bun run test
# または: moon test -d --target wasm && moon test -d --target wasm-gc
```

---

## ⌨️ キーバインド

| キー | 動作 |
| :--- | :--- |
| **左クリック / ドラッグ / ホイール** | **カーソル移動 / 範囲選択 / 上下スクロール**（SGR 1002 + 1006 マウス対応） |
| **Shift+矢印 / Shift+Home,End** | **キーボードで範囲選択**（選択中は入力・Backspace で置換/削除、ブラウザ版は `Cmd+A`/`C`/`X` も可） |
| **矢印キー (↑ ↓ ← →)** | カーソル移動（全角対応、行跨ぎ） |
| **Ctrl+P / N / B / F** | macOS Cocoa 風の上 / 下 / 左 / 右 移動 |
| **Home / End** (`Ctrl+A` / `Ctrl+E`, ブラウザ版 `Cmd+←/→`) | 行頭 / 行末 へ移動 |
| **ブラウザ版 `Cmd+↑ / ↓`** | ファイル先頭 / 末尾 へ移動 |
| **Option+← / Option+→** | 単語単位で左右移動 |
| **PageUp / PageDown** | 1 画面分スクロール移動 |
| **Enter / Backspace / Delete / Tab** | 改行 / 前1文字削除 / 次1文字削除 / インデント |
| **Option+Backspace / Delete** | 単語単位で前/後ろを削除 |
| **ブラウザ版 `Cmd+Backspace`** | 行頭まで削除 |
| **Ctrl+D** (ブラウザ版 `Cmd+D` も可) | 現在行を下に複製 |
| **Ctrl+K** | 現在行をカット（クリップボードへコピー） |
| **Ctrl+U** | カットした行を現在行の上にペースト |
| **Ctrl+T** | EAW（曖昧文字幅）1セル / 2セル 切替 |
| **Ctrl+S** (ブラウザ版 `Cmd+S` も可) | 保存（ブラウザ版: `localStorage` 保存、WASI版: ファイル書き出し） |
| **Ctrl+Q** | 終了（未保存変更がある場合は確認後に再押下で終了） |
