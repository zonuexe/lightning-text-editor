# WASM 経由のブラウザランタイム設計ガイド（ターミナル以外のターゲット）

本プロジェクトのテキストエディタは、ローカルのターミナル（TTY）だけでなく、**WASM（WebAssembly / WasmGC）+ ブラウザ端末エミュレータ（`xterm.js` 等）** をランタイムとして動かすことができます。

このドキュメントでは、実際に [examples/moonbit/](../examples/moonbit/)（WasmGC ブラウザアプリ & WASI Preview 1 CLI 両対応）を実装・検証する中で得られたアーキテクチャ設計とブラウザ特有の落とし穴をまとめます。

---

## 🏗 1. アーキテクチャの違い：ブロッキングループ vs イベント駆動コア

従来のローカルターミナル版では、プログラム自身が主導権を持って以下のループを回します：

```text
[ターミナル直結型]
Raw Mode 化 ─► loop { render(); key = blocking_read_key(); handle(key); } ─► 復元
```

しかし、ブラウザや WASI 環境では 2 つの制約があります：
1. **ブラウザメインスレッドでは `fd_read` のような同期ブロッキングができない**
   - 純粋な WASI CLI バイナリをそのままブラウザで対話実行しようとすると、`Web Worker + SharedArrayBuffer + Atomics.wait`（COOP/COEP HTTP ヘッダ必須）や JSPI / Asyncify が必要になります。
2. **WASI Preview 1/2 には `termios`（Raw Mode）と端末サイズ取得 (`TIOCGWINSZ`) の標準 API がない**
   - 端末制御を OS に依存すると移植性が失われます。

### ✅ 解決策：「イベント駆動コア + 薄型ホスト」パターン

エディタのコアを **「入力を受け取って ANSI 文字列を返す、環境非依存のステートマシン」** として設計します。

```text
                ┌──────────────────────────────────────┐
                │      Editor Core (純粋ロジック)       │
                │  - init(cols, rows, file, content)   │
                │  - on_data(input)  -> ANSI String    │
                │  - on_resize(cols, rows) -> ANSI     │
                │  - take_save_request() / content()   │
                └──────────┬───────────────┬───────────┘
                           │               │
         ┌─────────────────┘               └─────────────────┐
         ▼                                                   ▼
┌────────────────────────────┐                 ┌────────────────────────────┐
│  ブラウザホスト (xterm.js)  │                 │   WASI CLI ホスト (wasmtime) │
│  - term.onData -> on_data  │                 │   - stty raw -echo (ラッパー)│
│  - term.onResize           │                 │   - fd_read -> feed_bytes  │
│  - localStorage / Download │                 │   - path_open で実ファイル保存│
└────────────────────────────┘                 └────────────────────────────┘
```

この構成にすると：
- ブラウザ版は `SharedArrayBuffer` や特殊な HTTP ヘッダ不要で、静的サイトとしてそのまま配信できます。
- 同じコアを WASI CLI の薄い `fd_read` / `fd_write` ループから呼ぶだけで、`wasmtime` 等のネイティブ WASI ランタイムでも動作します。

---

## 🛠 ブラウザ WASM 向けにビルドしやすい主な言語

40 分のハンズオンでは「**ビルドが速く、JS との連携がシンプル**」な言語が特に快適です（Ruby / PHP 等のスクリプト言語も VM ごと WASM 化して動かせますが、ビルド時間やバイナリサイズが大きくなりやすいため、まずはネイティブに WASM を出力できる以下の言語がおすすめです）：

| 言語 | ビルド手段・ツール | 特徴・ブラウザ連携のしやすさ |
| :--- | :--- | :--- |
| **MoonBit** | `moon build --target wasm-gc` | **最軽量クラス（約18KB）**。`use-js-builtin-string` で JS 文字列をゼロコピー受け渡しでき、WASI CLI とも共有しやすい（[examples/moonbit/](../examples/moonbit/)） |
| **Rust** | `wasm-pack` / `wasm-bindgen` (`wasm32-unknown-unknown`) | エコシステムが充実。`#[wasm_bindgen]` だけで `String` を取る関数を自動バインドでき、ビルドも高速 |
| **Go / TinyGo** | `GOOS=js GOARCH=wasm go build` / `tinygo build -target=wasm` | 標準の `go` だけで `wasm_exec.js` 経由のブラウザ実行が可能。サイズを小さくしたい場合は TinyGo が便利 |
| **Zig** | `zig build-exe -target wasm32-freestanding` | ツールチェーン単体で外部依存なく超高速ビルド・極小 `.wasm` を生成可能（線形メモリ経由で文字列をやり取り） |
| **AssemblyScript** | `npx asc` | TypeScript に近い構文から数秒で `.wasm` にコンパイルでき、JS/TS 開発者が入りやすい |
| **C / C++** | `clang --target=wasm32` / Emscripten | 環境があればすぐ単体 `.wasm` を生成可能（文字列受け渡しは線形メモリ上のポインタ＋長さで設計） |

---

## ⚠️ 2. ブラウザ (`xterm.js`) 実装で踏む実戦の落とし穴と対策

ブラウザはターミナルエミュレータでありながら、同時に **Web ブラウザと OS の IME（日本語変換）** の上流にいます。以下の 5 点は実際に動作確認して初めて気づきやすいポイントです。

### 落とし穴 ①：日本語 IME（漢字変換）中のキー横取り
- **症状**: 変換中に押した `Enter`（確定）、`Esc`（キャンセル）、`Ctrl+J` / `Ctrl+K`（変換操作）をアプリ側が拾ってしまい、変換が途中で確定・破棄される。
- **対策**:
  - `term.attachCustomKeyEventHandler` の最優先で **`ev.isComposing || ev.keyCode === 229`** をチェックし、`true` を返して素通りさせる。
  - Safari / Chrome では `compositionend` と `keydown` の発火順や `isComposing` のタイミングが微妙に異なることがあるため、`term.textarea` の `compositionstart` / `compositionend` でも自前フラグを持ち、`compositionend` 時は `setTimeout(..., 0)` で次マクロタスクにフラグを落とすと安全です。
  - `.xterm .composition-view` の配色と `z-index` を調整すると、カーソル位置の未確定文字列が視認しやすくなります。

### 落とし穴 ②：SKK 系 IME の「`aaa` → `aaa`（aiueo 問題）」
- **症状**: AquaSKK や macSKK のように **漢字変換（`compositionstart`）を開始せず直接かなを確定する IME** を使うと、`a` を押した瞬間に `xterm.js` が `keydown`（`keyCode === 65`）を横取りして `"a"` を発火したうえ `e.preventDefault()` を呼ぶため、IME へキーが届かず `"aaa"` がそのまま入力されてしまいます。
- **対策**:
  1. `attachCustomKeyEventHandler` で通常の単一文字キー（`!ctrlKey && !metaKey && !altKey && ev.key.length === 1`）および macOS の `Ctrl+J`（SKK かな切替）に対して **`preventDefault()` を呼ばずに `return false`** し、`xterm.js` の `keydown`/`keypress` 処理をスキップして OS のテキスト入力系（`NSTextInputClient`）へそのまま流す。
  2. `term.textarea` の `input` イベント（`inputType === "insertText"`）から確定文字列（`"あ"` 等）を取得してコアへ渡す。
  3. 音声入力や別経路で `xterm.js` 自身の `_inputEvent` がすでに `term.onData` を発火したイベントを二重処理しないよう、キャプチャフェーズでフラグをリセットし、`onData` 発火時は `input` 側をスキップする排他制御を入れる。

### 落とし穴 ③：macOS ショートカットとブラウザ予約キーの衝突
- **症状**: `Cmd+S` でブラウザの「ページを保存」、`Cmd+D` でブックマーク登録、`Ctrl+P` 等で意図しないブラウザ動作が発火する。
- **対策**:
  - `attachCustomKeyEventHandler`（`ev.type === "keydown"` 限定、かつ IME 非変換中）で `Cmd` / `Option` / `Ctrl` を制御列へ変換する：
    - `Cmd+S` → `\x13`（保存）
    - `Cmd+D` → `\x04`（行複製）
    - `Cmd+← / →` → `\x1b[H` / `\x1b[F`（行頭 / 行末）
    - `Cmd+↑ / ↓` → `\x1b[1;5H` / `\x1b[1;5F`（ファイル先頭 / 末尾）
    - `Cmd+Backspace` → 独自 CSI 列（例: `\x1b[127;9u`）で行頭まで削除
    - `Option+← / →` → `\x1b[1;3D` / `\x1b[1;3C`（単語移動）
    - `Option+Backspace` → `\x1b\x7f`（単語削除）
  - **重要（macOS JIS キーボード対策）**: `macOptionIsMeta: true` を全体に有効化すると `Option+¥`（`\` バックスラッシュ入力）や特殊記号入力が壊れるため、**`Option+矢印` と `Option+Backspace/Delete` だけを個別に横取りし、`Option+文字` はブラウザに任せる**のが安全です。
  - **注意**: `Cmd+Q` / `Cmd+W` / `Cmd+T` / `Cmd+R` はブラウザ・OS が予約しているため Web アプリ側で奪えません。終了系は `Ctrl+Q` を残します。

### 落とし穴 ④：マウスクリック移動 & 「カーソルを引っ張らない」ホイールスクロール
- **クリック移動**: コアの画面開始時に SGR 1006 拡張マウスモード（`\x1b[?1000h\x1b[?1006h`、終了時に `\x1b[?1006l\x1b[?1000l`）を有効化すると、`xterm.js` が左クリックを `\x1b[<0;col;rowM`、ホイールを `\x1b[<64;col;rowM` / `\x1b[<65;col;rowM` としてそのまま `onData` に送ってくれます（※範囲選択したいときは `Shift+ドラッグ`）。
- **全角文字の列計算**: クリックされた画面列から行番号ガター幅を引き、`col_offset` を足した表示カラム幅を各文字の表示幅（1セル / 2セル）で積算して文字インデックスへ変換します。
- **ホイールスクロール設計のコツ**:
  - ホイールでカーソル行（`cursor_y`）ごと動かしてしまうと「行移動」になってしまい、元の編集箇所を見失います。
  - **`render()` 内に `ensure_cursor_visible()` を書かない**のが鉄則です。ホイール時は `row_offset` だけを増減して `ensure_cursor_visible()` を呼ばず、カーソルが画面外に出たら `\x1b[?25l` のままカーソルを非表示にします。その後、文字入力・矢印キー・クリック時に `ensure_cursor_visible()` を呼べば、編集位置へ自然に視線が復帰します。

### 落とし穴 ⑤：文字列受け渡しとバイナリサイズ（WasmGC vs 線形メモリ）
- **WasmGC (`use-js-builtin-string`)**: JS String Builtins（`builtins: ["js-string"]`, `importedStringConstants: "_"`）を使うと、JS の `String` をコピー・ポインタ変換なしで直接 WASM 関数に渡せ、MoonBit では外部インポートゼロ・約 18 KB の `.wasm` としてビルドできます（Chrome 130+ / Edge 130+ / Firefox 134+ 等）。
- **線形メモリ WASI (`--target wasm`)**: Safari や古いブラウザを含む全環境互換を狙う場合や `wasmtime` でも動かす場合は、UTF-8 バイト列を線形メモリ経由で受け渡します。その際、GC/RC 言語では「ポインタだけ取り出したバッファが FFI 呼び出し前に自動解放されないよう、呼び出し後も参照を保持する」点に注意が必要です（詳細は [guides/moonbit.md](../guides/moonbit.md) 参照）。

---

## 📦 3. ローカルファイルの読み書き・永続化

「ブラウザ版ではローカルファイルを扱えないのでは？」と思われがちですが、ブラウザ標準の Web API を使うことで**手元のローカルファイルを普通に開いて編集・保存できます**。

コア側では直接ディスクを触らず、**「ファイル内容の読み込み（`load_file(name, content)`）」「保存要求フラグ（`take_save_request()`）」「内容取得（`content()`）」** だけを公開し、実際の I/O はホスト側に委譲します：

### 1. 全ブラウザ共通の方法（[examples/moonbit/](../examples/moonbit/) で実装済み）
- **開く**: `<input type="file">`（またはドラッグ＆ドロップ）で `await file.text()` を読み込み、`wasm.load_file(file.name, text)` へ渡す。
- **保存する**:
  - `Ctrl+S` / `Cmd+S` で `localStorage` へ自動保存（リロードしても編集状態を保持）。
  - `Blob` + `<a download>` で編集済みテキストをローカルへファイル保存（ダウンロード）。

### 2. 直接上書き保存したい場合（File System Access API）
Chromium 系ブラウザ（Chrome / Edge 等）では `window.showOpenFilePicker()` で取得した `FileSystemFileHandle` を保持しておくことで、**`Ctrl+S` / `Cmd+S` を押したときに元のローカルファイルへ直接上書き保存**することもできます：

```typescript
// 開くとき
const [handle] = await window.showOpenFilePicker();
const file = await handle.getFile();
term.write(wasm.load_file(file.name, await file.text()));

// 保存するとき（take_save_request() が true のとき）
const writable = await handle.createWritable();
await writable.write(wasm.get_content());
await writable.close();
term.write(wasm.mark_saved());
```

### 3. WASI CLI ホストの場合
- `wasi_snapshot_preview1` の `path_open` + `fd_read` / `fd_write`（`wasmtime --dir=.` 等）で実ファイルを直接読み書きします。
