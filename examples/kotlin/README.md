# inzm - Kotlin (jEdit 風操作性 & 循環 Kill Ring 搭載 TUI エディタ)

**Kotlin** + **Gradle** で実装された、**[jEdit](https://www.jedit.org/)** に着想を得た 2 ストロークプレフィックス (`Ctrl+E`)・Action Bar・**循環キルリング (Kill Ring)** 搭載のターミナルテキストエディタです。

---

## 🌟 特徴

1. **循環キルリング (Kill Ring) の本格実装 (`KillRing.kt`)**:
   - **`Ctrl+K`（連続キル結合）**: 行末までキルします（行末が空なら改行をキル）。連続して `Ctrl+K` や `Alt+D` を押すと、リングを増やさず **先頭エントリに自動連結** します（カーソル移動や別操作を挟むと新しいエントリとして積まれます）。
   - **`Ctrl+Y` → `Alt+Y`（Yank & Yank-Pop 循環置換）**: `Ctrl+Y` で最新エントリを貼り付けた直後に `Alt+Y`（`Esc` → `y` でも可）を押すと、今貼り付けた範囲を **Kill Ring 内の過去のキル履歴で順次差し替え・循環** します。
   - **`Ctrl+E Ctrl+K`（Kill Ring 一覧選択）**: 過去のキル履歴（最大 32 件）を一覧表示し、`↑/↓` または数字 `1〜9` + `Enter` で任意のエントリを選択挿入できます。
2. **jEdit 風 2 ストローク (`Ctrl+E`) & Action Bar**:
   - **2 ストロークコマンド**: `Ctrl+E d`（行複製）、`Ctrl+E x` / `Ctrl+E Ctrl+D`（行丸ごとキル → Kill Ring）、`Ctrl+E n/p`（バッファ切替）、`Ctrl+E w`（バッファ閉じる）、`Ctrl+E j`（行ジャンプ）。
   - **Action Bar (`F2` / `Esc Enter` / `Ctrl+E a`)**: 画面最下部にアクションプロンプトを開き、`save [file]`、`open <file>`、`goto <line>`、`killring`、`eaw`、`quit` 等のコマンドを直接実行できます。
3. **マルチバッファ・範囲選択・SGR 1006 マウス対応**:
   - `Shift+矢印` / `Ctrl+Space`（マーク）/ マウスドラッグによる範囲選択と、選択領域の `Ctrl+W`（Kill）・`Alt+W`（Copy → Kill Ring）・置換入力に対応。
   - ビューポート固定マウスホイールスクロール（カーソルを編集位置に残したままスクロール）。
4. **Unicode / サロゲートペア・DSR EAW・EditorConfig 準拠**:
   - コードポイント単位のインデックス操作で日本語・絵文字（`🍣` 等）を破壊せず、`ble.sh` 知見に基づいた UTF-8 分割安全デコーダ・同期描画（`\x1b[?2026h/l`）・クリーンアップ順序制御（終了シーケンス flush 後 `stty` 復元）を備えています。

---

## 🚀 ビルド & 起動・テスト

```bash
cd examples/kotlin

# ビルドしてネイティブ端末直結で起動
./inzm sample.txt

# JUnit 5 ユニットテストの実行
./gradlew test
```

---

## ⌨️ 主なキーバインド

| キー | 動作 |
| :--- | :--- |
| **Ctrl+K** | 行末までキル（連続押下で Kill Ring 先頭へ連結） |
| **Ctrl+Y** | Kill Ring 先頭を貼り付け（Yank） |
| **Alt+Y** (`Esc` → `y`) | 直前の Yank を Kill Ring 履歴で順次差し替え（Yank-Pop） |
| **Alt+D** / **Alt+Backspace** | 前方 / 後方の単語をキル（連結対応） |
| **Ctrl+W** / **Alt+W** | 選択範囲をキル / コピーして Kill Ring へ積む |
| **Ctrl+E Ctrl+K** | Kill Ring 履歴一覧オーバーレイを表示して選択挿入 |
| **Ctrl+E d** / **Ctrl+E x** | 現在行を複製 / 現在行を丸ごとキル |
| **F2** / **Esc Enter** / **Ctrl+E a** | jEdit Action Bar を開く |
| **Ctrl+N** / **Ctrl+P** | 次のバッファ / 前のバッファへ切替 |
| **Ctrl+F** | インクリメンタル検索 |
| **Ctrl+S** / **Ctrl+O** | 保存 / 別ファイルを開く |
| **Ctrl+Q** | 安全終了（未保存時は警告、2回目で終了） |
| **Ctrl+T** | EAW（曖昧幅 1セル ⇄ 2セル）のトグル |

---

## 📂 構成

- `src/main/kotlin/inzm/KillRing.kt` — 最大 32 件の循環 Kill Ring と連続連結 / Yank-Pop 状態機械
- `src/main/kotlin/inzm/UnicodeAndWidth.kt` — Unicode コードポイント操作、EAW 幅、`.editorconfig` 解決
- `src/main/kotlin/inzm/InputDecoder.kt` — 分断対応 UTF-8 / CSI / `Alt+Key` / SGR マウス / Bracketed Paste デコーダ
- `src/main/kotlin/inzm/EditorCore.kt` — jEdit 操作体系、マルチバッファ、Action Bar、レンダリングコア
- `src/main/kotlin/inzm/Main.kt` — `stty` Raw Mode 管理、DSR プローブ、単一イベントループ統合
- `src/test/kotlin/inzm/InzmTest.kt` — Kill Ring・Unicode・デコーダ・Action Bar のユニットテスト
