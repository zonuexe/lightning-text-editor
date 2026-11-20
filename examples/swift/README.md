# inzm - Swift (CotEditor 風 macOS ネイティブテキストエディタ)

**Pure Swift + AppKit** のみ（外部ライブラリ・Xcode プロジェクトファイル不要）で構成された、**CotEditor** のような macOS 標準操作体系と Unicode インスペクタを備えたネイティブテキストエディタ実装サンプルです。

---

## 🌟 特徴

1. **CotEditor 風の macOS 標準操作体系 (`NSMenu` + `NSTextView`)**:
   - **ファイル・タブ操作**: `⌘N`（新規ウィンドウ）、`⌘T`（macOS ネイティブタブ）、`⌘O`（開くダイアログ）、`⌘S` / `⇧⌘S`（保存・別名保存）、`⌘W`（閉じる）、`⌘Q`（終了）。未保存の変更がある場合は、赤い閉じるボタンの未保存ドット表示と保存確認アラートで安全に保護。
   - **macOS 標準編集ショートカット & Cocoa キーバインド**: `⌘Z` / `⇧⌘Z`（Undo/Redo）、`⌘X`/`⌘C`/`⌘V`/`⌘A`、`⌘←`/`→`（行頭/行末）、`⌘↑`/`↓`（先頭/末尾）、`⌥←`/`→`（単語移動）、`⌥⌫` / `⌘⌫`、さらに Cocoa 標準の `^A` / `^E` / `^P` / `^N` / `^B` / `^F` / `^K` / `^D` や日本語 IME（macSKK / ことえり等）が OS ネイティブのまま自然に使えます。
   - **便利なテキスト編集コマンド**: `⌘D`（行複製）、`⇧⌘K`（行削除）、`⌘L`（指定行ジャンプ）、標準 Find Bar（`⌘F` 検索・`⌥⌘F` 置換・`⌘G` / `⇧⌘G` 次/前へ・`⌘E` 選択文字を検索へ）。
2. **Unicode 書記素クラスタ解析 & 文字情報インスペクタ (`⌥⌘I`)**:
   - Swift 標準の `Character`（Extended Grapheme Cluster）により、`👨‍👩‍👧‍👦` や `か゚`（結合文字）も 1 文字として正確にカウント・表示。
   - 下部ステータスバーにカーソル下の Unicode コードポイントをリアルタイム表示し、`⌥⌘I`（または `U+` ボタン）で **CotEditor 名物の文字インスペクタ風のポップオーバー**（各 Unicode スカラーの `U+XXXX` と正式名称一覧）を確認できます。
3. **行番号ルーラー & 一時属性シンタックスハイライト**:
   - `NSLayoutManager` に連動した行番号ガター（現在行の太字強調・自動幅調整・`⌘+` / `⌘-` / `⌘0` フォントサイズ変更追従）。
   - `NSLayoutManager.addTemporaryAttribute` を用いた Undo スタック非汚染のリアルタイムハイライト（Swift / Markdown / JSON / 各種コード対応）。
4. **改行コード・UTF-8 BOM 切替 & EditorConfig 統合**:
   - ステータスバーのポップアップから **文字コード (`UTF-8` / `UTF-8 with BOM`)** や **改行コード (`LF` / `CRLF` / `CR`)** を即時切替可能。
   - 開いたファイルごとに `.editorconfig` を自動解決し、Tab キーのスペース展開（`indent_style` / `indent_size`）および保存時の `trim_trailing_whitespace` / `insert_final_newline` / `end_of_line` を適用。

---

## 🚀 ビルド & 起動・テスト

macOS 環境（CommandLineTools または Xcode）のターミナルでそのまま実行できます：

```bash
cd examples/swift

# 起動（sample.txt を開く）
swift run inzm sample.txt

# コアロジック (InzmCore) のユニットテスト実行
swift test

# （補足）Xcode.app を入れず CommandLineTools のみ使用している環境で TestingMacros が解決できない場合:
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

---

## 📂 構成

- `Package.swift` — SwiftPM パッケージ定義（外部依存ゼロ、macOS 14+）
- `Sources/InzmCore/DocumentModel.swift` — 改行コード/BOM変換、Unicode 書記素/スカラー解析、`.editorconfig` 解決、軽量シンタックスハイライト（GUI 非依存コア）
- `Sources/inzm/main.swift` — `NSApplication` エントリポイント & フル `NSMenu` 構築
- `Sources/inzm/EditorWindowController.swift` — `NSTextView`・ステータスバー・文字情報ポップオーバー・保存確認ダイアログ統合
- `Sources/inzm/LineNumberRulerView.swift` — `NSRulerView` ベースの行番号ガター描画
- `Tests/InzmCoreTests/InzmCoreTests.swift` — Swift Testing (`import Testing`) によるコアユニットテスト
