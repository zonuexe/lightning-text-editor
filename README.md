# 史上最速でキミだけのテキストエディタを実装しよう

事前知識ゼロから、**たった40分の対話**でターミナル上で動く自分専用のテキストエディタを作り上げるハンズオンプロジェクトです。

---

## 🚀 今すぐ始める（人間がすべきことはコレだけ！）

このリポジトリを開いている AI アシスタント（Claude Code, Cursor, Copilot, pi など）に向かって、**たった一言**話しかけてください：

> **「エディタを作りたい」**

AIがあなた専任のメンターとして起動し、以下を対話しながら40分で動くオリジナルエディタを一緒に作り上げます：
1. **言語の選択**: TypeScript/Bun, Python, Ruby, Go, Rust, Java, PHP, MoonBit, Zig, Lua, Bash, C など何でもOK！
2. **ターゲット環境**: ローカルのターミナル CLI、または **WASM 経由のブラウザアプリ（`xterm.js` 等）**
   - ※ ブラウザランタイムを選んだ場合でも、`<input type="file">` やドラッグ＆ドロップ、File System Access API を使って**手元のローカルファイルを開いて編集・保存**できます。
3. **エディタの名前**: あなたの好きなオリジナル名を命名
4. **好みの操作感**: スタンダード派（矢印キー）、Vim風（hjkl/モーダル）、Emacs風、nano風
5. **どこから動かすか**: 画面の見た目から？ キー入力の反応から？ ロジックから？

準備は一切不要。環境構築や前提知識がなくても、AIが手取り足取りエスコートします。

---

## 🎯 コンセプト

> **「エディタを使う側から、作る側へ」**

テキストエディタはプログラミングの基本要素（入出力、状態管理、イベントループ、画面描画、ファイルI/O）が凝縮された最高の教材です。しかし、既存のチュートリアル（Kiloエディタ系など）はC言語前提だったり、一本道の固定カリキュラムで退屈・挫折しがちでした。

本プロジェクトでは：
1. **言語フリー**: Ruby, Python, Go, Rust, Java, PHP, TypeScript, C など、ユーザーが普段使い慣れている言語や今学んでみたい言語を選べる
2. **完全対話型 & アドリブ歓迎**: 固定の順番に縛られず、ユーザーが「どこから動くものを見たいか」に合わせてAIがアドリブで進行ルートを動的に組み立てる
3. **40分のタイムボックス**: 最小構成（MVP）を短時間で確実に動かし、動く楽しさと達成感を最速で届ける

---

## 🧭 自由な進入路（好きなところから動かせる！）

エディタ開発は一本道である必要はありません。「まず何が動くところを見てワクワクしたいか？」によって、開始ポイントをユーザー自身が選べます。AIメンターはその選択に合わせて、足りないパーツをアドリブで繋ぎ合わせながら完成へ導きます。

```
          [ユーザーの「ここから動かしたい！」]
                 /            |            \
    🎨 見た目ファースト   🎮 入力ファースト   📄 ロジックファースト
   (画面描画・UI装飾)    (キー即時反応・操作)  (文字挿入・バッファ操作)
                 \            |            /
                  └─► [40分で合流して完成！] ◄─┘
```

| アプローチ | 「こんな人におすすめ」 | 最初の「動いた！」体験 |
| :--- | :--- | :--- |
| **🎨 見た目ファースト** | 「まずはエディタっぽいカッコいい画面を見たい」 | ターミナルいっぱいに広がるステータスバー、行番号、カラー表示 |
| **🎮 入力ファースト** | 「キーを押してすぐ反応するインタラクティブ感を味わいたい」 | 押したキーが即座に画面にリアクションするゲームループ |
| **📄 ロジックファースト** | 「テキストデータの操作や改行処理の仕組みから理解したい」 | 文字列の挿入・削除・インデックス移動のミニマル動作 |
| **📦 ミニマルI/Oファースト** | 「とにかくファイルを開いて保存できる一番小さなエディタが欲しい」 | ファイルを読み込んで変更して保存する最短パイプライン |

---

## ⏱ 40分の進行モデル（標準フロー例）

順番は自由に変えられますが、全体で40分に収めるためのコアコンポーネントと目安です。どのルートから入っても、この5つの要素が対話を通じて自然と揃うように進行します。

| フェーズ | 時間目安 | 実装内容 | 学べること |
| :--- | :--- | :--- | :--- |
| **0. セットアップ & ヒアリング** | 0〜5分 | 言語選択、キーバインドの好み、エディタの名前決め | 環境準備、プロジェクト方針策定 |
| **Step 1: ターミナルの生モード** | 5〜12分 | Raw Modeの有効化、キー入力の即時受け取り、終了キー（Ctrl+Q等）の実装 | ターミナルの入力モデル、終了処理 |
| **Step 2: 画面描画 & 状態管理** | 12〜20分 | 画面クリア、バッファ（テキストデータ）の表示、ステータスライン | ANSIエスケープコード、画面再描画 |
| **Step 3: カーソル移動** | 20〜27分 | 矢印キー / Vim風キーでのカーソル移動、画面端の境界チェック | 座標系（行・列）とテキストインデックスの対応 |
| **Step 4: 文字入力 & 削除** | 27〜35分 | タイピングによる文字挿入、Backspaceでの削除、改行処理 | バッファ操作、文字の挿入/削除ロジック |
| **Step 5: 保存 & 完成！** | 35〜40分 | ファイル書き出し（Ctrl+S等）、動作確認、完成セレブレーション | ファイルI/O、達成感 |

---

## 🧩 対話型ステップバイステップの特徴

ユーザーのスキルレベルや好みに応じて、分岐とカスタマイズを用意します。

### 1. 「どこから動かす？」をその場で決めるアドリブ進行
AIメンターは最初に「まず画面の見た目から作りたい？それともキーボードを押したときの反応から作りたい？」と問いかけます。
- **見た目から入りたい場合**: まず固定テキストやステータスラインを描画させ、「おっ、エディタっぽい画面が出た！」を体験してから入力処理へ接続
- **入力から入りたい場合**: 生モードで押したキーを表示するミニプログラムから始め、「リアルタイムにキーが取れた！」を体験してから描画へ接続
- **どの順番で進めても**: 必要な5要素（生モード、描画、カーソル、バッファ、保存）が最終的に結合され、40分で一つのエディタとして動く状態へ収束させます。

### 2. キーバインドの選択
- **スタンダード派**: 矢印キー移動 + Ctrl+S 保存 + Ctrl+Q 終了
- **Vim / モーダル派**: ノーマルモード（hjkl移動、:w 保存、:q 終了） + インサートモード（i）
- **Emacs / ナード派**: Ctrl+P/N/B/F 移動 + Ctrl+X Ctrl+S 保存

### 3. 見た目・UIのカスタマイズ
- 行番号表示の有無
- ステータスバー（ファイル名、行数、文字数、モード表示）
- ヘルプメッセージ（「Ctrl+Q で終了」などのガイド表示）

### 4. 次の一歩（40分完了後 / 時間が余ったときのデザートメニュー）
40分の基本実装がサクッと終わった場合、さらに実用性を高める追加機能レシピを用意しています（詳細は `docs/extension-ideas.md` を参照）：
- **⚡️ QuickRun (`Ctrl+R`)**: タイムアウト付きで現在ファイルを即時実行し、`q` でエディタに復帰（TypeScript, Python, PHP, Ruby, Bash等）
- **✂️ 行キル・行複製 (`Ctrl+K` / `Ctrl+D`)**: 1行削除・複製
- **🛡 未保存終了ガード (Safe Quit)**: 変更破棄の二重確認
- **🎨 簡易シンタックスハイライト / テーマ切り替え**: キーワードやコメントの色付け
- **🔍 Git Diff ビューア / フォーマッター連携**: 差分確認やコード整形連携

---

## 🌐 対応想定言語とアプローチ

主要な言語ごとのターミナル制御手法（Raw Mode・入力受付）のパターンです。外部依存を最小限（できれば標準ライブラリのみ）に抑え、素早く立ち上げられる構成を重視します。

| 言語 | ターミナル制御・入力手法 | 特徴・おすすめポイント |
| :--- | :--- | :--- |
| **Ruby** | `io/console` (`IO#raw`, `IO#getch`) | 標準ライブラリだけで驚くほど数行でRaw Modeとキー取得が書ける |
| **Python** | `termios` + `tty` + `os.read` | 標準モジュールのみで完結。スクリプト1つで即実行可能 |
| **Go** | `golang.org/x/term` | 単一バイナリ配布可能。ゴルーチンとの親和性も高い |
| **Rust** | `crossterm` / `termion` / `Tauri v2` | 高速・堅牢。CLI版に加え、イベント駆動コア＋`xterm.js`の独立デスクトップアプリ構成も実装 |
| **Java** | `jline3` または `System.console()` + ANSI | オブジェクト指向で設計しやすい。JLineで簡単にTUI化 |
| **PHP** | `stty` 呼び出し + `fgetc(STDIN)` | CLIスクリプトとして手軽に動く。Web開発者のCLI入門に |
| **TypeScript (Bun / Node.js)** | `process.stdin.setRawMode(true)` / `Bun.write` | **Bun推奨**（tsconfig不要・`bun run editor.ts`だけで1秒起動。40分開発に最適）。Node.jsでも`tsx`で同様に動作可能 |
| **MoonBit (WASM / WASI)** | イベント駆動コア + `xterm.js` (WasmGC) / `wasip1` | 同じコアコードからブラウザアプリ（約29KB）と WASI CLI バイナリの両方をビルド可能 |
| **Zig** | `std.posix.termios` / `wasm32-freestanding` | 明示的 `Allocator` による Piece Table・無制限 Undo/Redo・約54KB のブラウザ WASM |
| **C** | `<termios.h>` | ターミナルの低レイヤ制御を極めたい人向けの王道 |

※ 上記以外の言語（Elixir, Kotlin, Swift 等）でも、ターミナルの生モード切り替えと標準入出力さえあれば同様のパターンで実装可能です。
※ **ブラウザ（WASM + `xterm.js`）ターゲット**で作りたい場合は、ビルドが速く単体 `.wasm` を出しやすい **MoonBit / Rust (`wasm-bindgen`) / Go (TinyGo) / Zig / AssemblyScript / C** などがおすすめです（詳細は [`docs/browser-wasm-runtime.md`](docs/browser-wasm-runtime.md) を参照）。

---

## 📂 本リポジトリの構成

```text
├── README.md               # プロジェクト概要・コンセプト（本ファイル）
├── AGENTS.md               # AIメンター用の最優先トリガーと行動指針
├── docs/                   # ターミナル基礎知識・技術ドキュメント
│   ├── raw-mode.md         # ターミナルのRaw Modeとは（stty / termiosの仕組み）
│   ├── ansi-escapes.md     # よく使うANSIエスケープシーケンス一覧
│   ├── architecture.md     # 40分エディタの基本アーキテクチャ
│   ├── browser-wasm-runtime.md # ターミナル以外のターゲット：WASM経由ブラウザランタイム設計
│   ├── unicode-and-width.md # 文字幅とGrapheme Clusterの深淵（発展トピック）
│   ├── extension-ideas.md  # 40分完了後の拡張アイデア集（デザートメニュー）
│   └── editorconfig.md     # EditorConfig統合とアーキテクチャ設計
├── guides/                 # 言語別クイックリファレンス
│   ├── ruby.md             # Ruby版ガイド (io/console)
│   ├── python.md           # Python版ガイド (termios / tty)
│   ├── go.md               # Go版ガイド (golang.org/x/term)
│   ├── rust.md             # Rust版ガイド (crossterm)
│   ├── java.md             # Java版ガイド (JLine / termios)
│   ├── php.md              # PHP版ガイド (stty / fgetc)
│   ├── typescript.md       # TypeScriptガイド (Bun推奨 / Node.js + tsx)
│   ├── moonbit.md          # MoonBit版ガイド (WasmGC + xterm.js / WASI Preview 1)
│   ├── zig.md              # Zig版ガイド (termios / wasm32-freestanding)
│   └── c.md                # C言語版ガイド (termios)
├── examples/               # 完成サンプル実装集
│   ├── bun-ts/             # inzm (Bun + TypeScript版: Shikiハイライト & QuickRun)
│   ├── ruby/               # inzm (Ruby版: bin/lib構成, Emacsキーマップ & init.rb自己拡張)
│   ├── go/                 # inzm (Go版: Vimモーダル編集 & マルチバッファ管理)
│   ├── php/                # ZONU inzm (PHP版: nano風レイアウト & 操作体系, EAW自動検知)
│   ├── bash/               # inzm.sh (Bash版: ed/ex風ラインエディタ, sed/awk/Readline活用)
│   ├── python/             # inzm.py (Python版: JOE/ZOE風, WordStarキーバインド, FSD Amoebaリスペクト)
│   ├── rust/               # inzm (Rust版: MinEd風, Unicodeファーストクラス, 書記素クラスタ完全対応)
│   ├── tauri-rust/         # inzm-tauri (Rust + Tauri v2 + xterm.js: 独立デスクトップアプリ, タブUI & 範囲選択)
│   ├── java/               # inzm (Java版: Gosling Emacs & Mocklisp, RSyntaxTextAreaハイライト)
│   ├── lua/                # inzm.lua (Lua版: micro風モダンPC操作 & コマンドバー, フルLua実装)
│   ├── moonbit/            # inzm.mbt (MoonBit版: WasmGC + xterm.js ブラウザアプリ & WASI Preview 1 CLI)
│   └── zig/                # inzm.zig (Zig版: Piece Table + 無制限Undo/Redo + Live Inspector + wasm32-freestanding)
└── skills/                 # AIエージェント用スキル定義
    └── lightning-editor/SKILL.md
```

---

## 🤝 このリポジトリの使い方

1. **AIエージェントに進行役を任せる場合**:
   - 本リポジトリの `AGENTS.md` / `skills/` を読み込ませたAIに「テキストエディタを作りたい」と話しかけるだけで、AIがメンターとして40分の対話開発をリードします。
2. **教材・カリキュラムとして使う場合**:
   - 各ステップのドキュメントとアーキテクチャ設計を参考に、ハンズオンイベントや勉強会の教材として利用できます。

---

## Copyright & License

[lightning-text-editor](https://github.com/zonuexe/lightning-text-editor) © 2026 by [USAMI Kenta &lt;tadsan@zonu.me&gt;](https://github.com/zonuexe).

- **ドキュメント・教材・スキル本文**（`README.md`, `AGENTS.md`, `docs/`, `guides/`, `skills/` 内のテキスト）: **[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)**（クリエイティブ・コモンズ 表示 - 継承 4.0 国際）。詳細は [LICENSE](LICENSE) をご覧ください。
- **ソフトウェア・サンプルコード**（`examples/` 以下の実装、およびドキュメント・ガイド内のソースコード例）: **[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)**（Apache License, Version 2.0）。詳細は [LICENSE-APACHE](LICENSE-APACHE) をご覧ください。

