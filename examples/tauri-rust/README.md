# inzm-tauri (Rust + Tauri v2 + xterm.js)

イベント駆動の Pure-Rust エディタコアを **Tauri v2** のネイティブデスクトップウィンドウ + **`xterm.js`** 上で動かすスタンドアロンデスクトップアプリ版サンプル実装です。

## 特徴

- **ネイティブデスクトップ統合 (`tauri v2` + `tauri-plugin-dialog`)**:
  - ネイティブ macOS メニューバー (`File` / `Edit` / `View`) により、ブラウザ制限を受けずに `⌘T` (新規タブ)・`⌘W` (タブを閉じる)・`⌘O` (開く)・`⌘S` / `⇧⌘S` (保存)・`⌘Q` (終了) を直接ハンドリング。
  - OS のファイル開く/保存ダイアログ、ウィンドウへのドラッグ＆ドロップによるファイル読み込み、未保存変更時の確認ダイアログを実装。
- **マルチバッファ & 1行目タブUI**:
  - 複数のファイルをタブで同時編集。タブバーのクリック・`+` ボタン・`^N` / `^P` (`⇧⌘]` / `⇧⌘[`) で切り替え可能。
- **Unicode / 書記素クラスタ + EAW 切り替え**:
  - `unicode-segmentation` + `unicode-width` による書記素クラスタ単位の移動・削除・幅計算と、`^T` による East Asian Ambiguous Width (NARROW / WIDE) 切り替えに対応。
- **範囲選択 & クリップボード**:
  - `Shift+Arrow`、`Shift+Home/End`、`Shift+Option+Arrow`、`⌘A`、SGR マウスドラッグ (`?1002h` + `?1006h`) による範囲選択、置換入力、`⌘C` / `⌘X` / `⌘V` コピー＆ペーストに対応。
- **無制限 Undo / Redo・インクリメンタル検索・シンタックスハイライト**:
  - バッファごとの Undo (`⌘Z`) / Redo (`⇧⌘Z`)、インクリメンタル検索 (`⌘F`)、拡張子に応じた軽量 TrueColor ハイライトを内蔵。
- **SKK / IME / macOS 入力対応**:
  - [`docs/browser-wasm-runtime.md`](../../docs/browser-wasm-runtime.md) にまとめた WKWebView / `xterm.js` の SKK 直接仮名入力修正・JIS `Option+¥` 保持・ビューポート固定ホイールスクロールを適用済み。

## 構成

- `src-tauri/src/editor.rs` — Pure-Rust マルチバッファ・タブ・範囲選択・Undo/Redo・検索・ANSI 描画コア
- `src-tauri/src/input.rs` — ANSI / CSI / SGR マウス / Bracketed Paste デコーダ
- `src-tauri/src/highlight.rs` — 拡張子ベース軽量 TrueColor シンタックスハイライト
- `src-tauri/src/lib.rs` — Tauri v2 コマンド・ネイティブメニュー・ファイルダイアログ・ウィンドウイベント統合
- `src/main.ts` — Vite + TypeScript + `xterm.js` + `@tauri-apps/api` フロントエンドブリッジ

## ビルド・実行方法

### テストとチェック

```bash
cd examples/tauri-rust
bun install
bun run build
cd src-tauri && cargo test
```

### デスクトップアプリとして起動（開発モード）

```bash
cd examples/tauri-rust
bun run tauri dev
```

### プロダクションビルド

```bash
cd examples/tauri-rust
bun run tauri build
```
