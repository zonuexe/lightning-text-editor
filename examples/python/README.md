# inzm.py - Python (JOE / ZOE: WordStar風 & FSD Amoeba リスペクト) 実装サンプル

外部ライブラリ一切不要（pip不要、Python標準のみ）！
Unixの分散OS「Amoeba」（後年のオープンソース版 FSD Amoeba）に移植されていた名作エディタ **[JOE (Joe's Own Editor)](https://joe-editor.sourceforge.io/)** にリスペクトを捧げた、**Zonu's Own Editor (ZOE)** 実装サンプルです。

---

## 🌟 特徴と背景

1. **FSD Amoeba & JOE へのリスペクト**:
   - 分散OS「Amoeba」のオープンソース後継である FSD Amoeba に移植され利用されていたフルスクリーンエディタ JOE の画面設計・操作体系をオマージュしています。
2. **JOE 伝統の画面レイアウト**:
   - **画面最上行（Row 1）**: Emacs のモードラインのように、画面の一番上に反転ステータスライン（`*sample.py Row 1 Col 1 14:30 Ctrl+K H for help`）を常時表示。
   - **起動時バナーメッセージ**:
     起動直後、画面下端左端に反転表示で
     `** Zonu's Own Editor v4.1 ** <utf-8> ** Copyright (C) 2026 **`
     が出現し、キーを1つでも押すとスッと自然に消滅します。
   - **ヘルプウィンドウ (`Ctrl+K H`)**:
     `Ctrl+K H` を押すと、画面上部に4行のキー操作ヘルプがニョキッと現れ、もう一度押すと引っ込む JOE 名物機能を再現！
3. **WordStar / JOE の `Ctrl+K` プレフィックスキー体系**:
   - `Ctrl+K` を押すと、ステータス行に `^K_` が点灯。
   - `^K D`（保存）、`^K X`（保存して終了）、`^K Q`（破棄して終了）。
   - `Ctrl+Y` で行キル（行削除）。
4. **DSRプローブによる EAW 自動検知 & 代替画面バッファ**:
   - 起動時に `\x1b[6n` で端末の曖昧文字描画幅を測定し、日本語や記号のカーソルズレを完全防止。
   - 代替画面バッファにより、終了時にシェル履歴を一切汚しません。

---

## 🚀 起動方法

```bash
cd examples/python
./inzm.py sample.py
```
または
```bash
python3 inzm.py sample.py
```

---

## ⌨️ JOE / WordStar キーバインド

### コマンド (`Ctrl+K` プレフィックス)
| キー | 動作 |
| :--- | :--- |
| **Ctrl+K H** | **ヘルプウィンドウの表示 / 非表示トグル（名物機能！）** |
| **Ctrl+K D** (または `^K S`) | ファイル保存（末尾 `\n` 保証） |
| **Ctrl+K X** | ファイル保存してエディタ終了 |
| **Ctrl+K Q** | 変更を破棄して終了 |
| **Ctrl+C** | 終了（未保存時は警告） |
| **Ctrl+Y** | **行キル（現在行を1行まるごと削除）** |

### 移動・ナビゲーション
| キー | 動作 |
| :--- | :--- |
| **矢印キー (↑ ↓ ← →)** | カーソル移動（全角・日本語対応、行末クランプ、行跨ぎ） |
| **Ctrl+P** / **Ctrl+N** | 上 / 下 移動 |
| **Ctrl+B** / **Ctrl+F** | 左 / 右 移動 |
| **Ctrl+A** / **Home** | 行頭へジャンプ |
| **Ctrl+E** / **End** | 行末へジャンプ |
| **Ctrl+U** / **PageUp** | 1画面分上へスクロール (Prev Page) |
| **Ctrl+V** / **PageDown** | 1画面分下へスクロール (Next Page) |
| **Enter / Backspace** | 改行 / 1文字削除（行結合対応） |
