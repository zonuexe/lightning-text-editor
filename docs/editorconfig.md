# EditorConfig の統合とアーキテクチャ設計

[EditorConfig](https://editorconfig.org/) は、異なるエディタやIDE間でもコーディングスタイル（インデント幅、改行コード、末尾改行など）を一貫して維持するための標準仕様です。

自作エディタに EditorConfig を組み込むことで、ユーザーがプロジェクトを開いた瞬間に **「そのリポジトリのルールに自動で適応する本物のエディタ」** へと昇華します。

---

## 🎯 サポートする主要プロパティとフック先

| プロパティ | 設定値の例 | エディタ内部での適用タイミング |
| :--- | :--- | :--- |
| **`insert_final_newline`** | `true` / `false` | **ファイル保存時**: バッファ末尾に `\n` を付与するかどうか |
| **`trim_trailing_whitespace`** | `true` / `false` | **ファイル保存時**: 各行の末尾にある不要な半角スペース・タブを除去 |
| **`indent_style`** | `space` / `tab` | **Tabキー押下時**: スペース文字列を挿入するか、タブ文字 `\t` を挿入するか |
| **`indent_size`** / **`tab_width`** | `2`, `4`, `8` | **Tabキー押下時 & 画面描画時**: インデントの幅 |
| **`end_of_line`** | `lf` / `crlf` / `cr` | **ファイル保存時**: 改行コード（`\n` または `\r\n`）の統一 |
| **`charset`** | `utf-8` / `latin1` 等 | **ファイル読み書き時**: エンコーディング |

---

## 🔍 `.editorconfig` の探索アルゴリズム

エディタはファイルを開いた際、以下の手順で設定を解決します：

```text
/project/src/sub/file.ts
   ├── 1. /project/src/sub/.editorconfig を探す
   ├── 2. なければ /project/src/.editorconfig を探す
   ├── 3. なければ /project/.editorconfig を探す
   └── 'root = true' が見つかったディレクトリで探索停止
```

セクションの Glob パターン（`[*]`, `[*.{ts,js}]`, `[*.go]` 等）をファイル名にマッチさせ、設定プロパティを合成（カスケード）します。

---

## 🌐 各言語での公式ライブラリ & バンドル戦略

| 言語 | ライブラリ選定 | 使い方 / 特徴 |
| :--- | :--- | :--- |
| **TypeScript (Bun)** | **`editorconfig` (公式 npm)** | `import editorconfig from "editorconfig"`<br>`const conf = await editorconfig.parse(filepath)` |
| **Go** | **`editorconfig-core-go/v2` (公式)** | `github.com/editorconfig/editorconfig-core-go/v2`<br>`def, _ := editorconfig.GetDefinitionForFilename(filepath)` |
| **Python** | **`editorconfig` (公式 PyPI)** | `import editorconfig`<br>`conf = editorconfig.get_configurations(filepath)` |
| **Ruby** | **`editorconfig` (公式 gem)** または バンドル | `require 'editorconfig'`<br>`conf = EditorConfig.resolve(filepath)` |
| **Java** | **`org.ec4j.core:ec4j-core`** または バンドル | Maven/Gradle で導入し、ASTまたは設定マップを取得 |
| **Bash / PHP / Lua** | **組み込み軽量パーサー** | 外部依存なしで単一ファイル完結させるため、約50行のミニINI＋Globパーサーを内蔵 |
