# inzm.zig - Zig (Piece Table + 無制限 Undo/Redo + ライブ Inspector) 実装サンプル

Zig (`0.17.1`) で実装された、既存サンプルの行配列モデル（`lines[]`）とは一線を画す **Piece Table（ピーステーブル）方式** のテキストエディタです。  
**ネイティブ `termios` ターミナル CLI** と **WASI・外部依存すら不要な `wasm32-freestanding` ブラウザアプリ（約 31 KB）** の両方にビルドできます。

---

## 🌟 特徴（他言語サンプルにないポイント）

1. **Piece Table（ピーステーブル）データ構造**:
   - 初期ファイルを不変の `original` スライスとして保持し、編集で追加されたバイト列だけを追記専用バッファ `add_buf` に蓄積し、`Piece` の配列として文書を構成（[src/piece_table.zig](src/piece_table.zig)）。
   - 明示的 `Allocator` ベースで動作し、`zig build test`（`std.testing.allocator`）でメモリリークゼロを保証。
2. **マルチカーソル同時編集 & 一括 Undo / Redo (`Ctrl+Z` / `Ctrl+Y`)**:
   - **`Ctrl+D` / `Cmd+D`**: カーソル下の単語と一致する次の箇所へカーソルを追加（VS Code 風）。
   - **`Option+↑/↓` / `Option+クリック`**: 上下の行やクリックした位置にカーソルを追加・トグル（`Esc` で単一カーソルに復帰）。
   - Piece Table の1次元バイトオフセット設計により、複数カーソルで同時入力・同時削除し、**1 回の `Ctrl+Z` / `Ctrl+Y` で全カーソル分を一括 Undo / Redo** 可能！
3. **ライブ「Piece Table Inspector」パネル (`F2` / `Ctrl+G`)**:
   - 画面下部に現在のピース数・`ORIG` / `ADD` バイト数・Undo/Redo 深さに加え、`[O:0..42 "..."]`（シアン）と `[A:0..5 "zig!"]`（緑）のピース分割・結合状態をリアルタイムに可視化！
   - 文字入力・削除・Undo・Redo を行うたびにピース構造の変化を目で見て学べます。
4. **インクリメンタル検索 + マッチハイライト (`Ctrl+F` / `Cmd+F`)**:
   - 検索プロンプトに入力するたびに即座に次の一致位置へジャンプし、画面内の全一致箇所をハイライト表示（`Enter` / `F3` で次候補へ移動）。
5. **ネイティブ `termios` CLI × `wasm32-freestanding` 極小ブラウザ版の両対応**:
   - ブラウザ版は **`wasm32-freestanding` + `FixedBufferAllocator`** で外部インポートゼロ・約 31 KB の `.wasm` にビルドでき、Safari / Chrome / Firefox すべてのモダンブラウザで動作。
   - ブラウザ版でも SKK 直接かな入力、macOS ショートカット、SGR 1006 クリック移動・ビューポート専用ホイールスクロール、ローカルファイル読込・保存に対応。

---

## 📂 ディレクトリ構成

```text
examples/zig/
├── build.zig             # ネイティブ CLI / wasm32-freestanding / test ビルド定義
├── build.zig.zon         # Zig パッケージマニフェスト
├── src/
│   ├── piece_table.zig   # Piece Table + Undo/Redo スナップショットエンジン
│   ├── unicode.zig       # UTF-8 境界判定 & 東アジア文字幅計算
│   ├── input.zig         # ストリーミング ANSI / SGR マウス入力デコーダ
│   ├── editor.zig        # Editor 本体・検索・Piece Table Inspector 描画
│   ├── root.zig          # コアモジュールエントリ
│   ├── main.zig          # ネイティブ POSIX termios CLI エントリ
│   └── wasm.zig          # wasm32-freestanding 線形メモリ エクスポート層
├── web/                  # Vite + xterm.js ブラウザアプリ
├── sample.txt            # テスト用サンプルテキスト
└── package.json          # ブラウザ版ビルド・開発サーバ起動スクリプト
```

---

## 🚀 ビルド & 起動

### 1. ネイティブターミナル CLI として実行

```bash
cd examples/zig

# 単体テスト (メモリリーク検知付き)
zig build test

# ビルド & 起動
zig build run -- sample.txt
```

### 2. ブラウザアプリとしてビルド & 起動 (`wasm32-freestanding` + `xterm.js`)

```bash
cd examples/zig
bun install

# 開発サーバ起動 (zig build wasm + Vite)
bun run dev

# 静的サイトとしてビルド (web/dist/)
bun run build
bun run preview
```

---

## ⌨️ キーバインド

| キー | 動作 |
| :--- | :--- |
| **F2 / Ctrl+G** | **Piece Table Inspector の表示 / 非表示トグル** |
| **Shift+矢印 / ドラッグ** | **範囲選択**（複数カーソルそれぞれの選択範囲も保持、ブラウザ版は `Cmd+A`/`C`/`X` 可） |
| **Ctrl+D** (ブラウザ `Cmd+D`) | **マルチカーソル：単語選択 → 次の一致語を選択追加** |
| **Option+↑ / ↓** / **Option+クリック** | **マルチカーソル：上下の行／クリック位置にカーソル追加（`Esc` で解除）** |
| **Ctrl+Z** (ブラウザ `Cmd+Z`) | **一括 Undo**（複数カーソル編集も1ステップで元に戻す） |
| **Ctrl+Y** (ブラウザ `Cmd+Shift+Z`) | **Redo**（取り消した編集をやり直す） |
| **Ctrl+F** (ブラウザ `Cmd+F`) | **インクリメンタル検索**（`Enter` / `F3` で次候補、`Esc` で終了） |
| **左クリック / ホイール** | クリック位置へ移動 / カーソルを動かさず画面スクロール |
| **矢印キー / Ctrl+P,N,B** | カーソル移動 |
| **Home / End** (`Ctrl+A`/`E`, `Cmd+←`/`→`) | 行頭 / 行末 へ移動 |
| **Option+← / Option+→** | 単語単位で左右移動 |
| **Option+Backspace / Delete** | 単語単位で削除 |
| **Ctrl+T** | EAW（曖昧文字幅）1セル / 2セル 切替 |
| **Ctrl+S** (ブラウザ `Cmd+S`) | 保存 |
| **Ctrl+Q** | 終了（未保存時は再押下で確認終了） |
