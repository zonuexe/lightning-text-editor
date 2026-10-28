# inzm.java - Java (Gosling Emacs & Mocklisp オマージュ) 実装サンプル

ビルドツール（Maven / Gradle）不要・外部ライブラリ一切なし！
**Java 21+ 単一ソースファイル直接実行** で動く、**James Gosling**（Javaの父）が1981年に開発した伝説の **Gosling Emacs (Gosmacs)** およびその拡張言語 **Mocklisp (MLisp)** に深いリスペクトを捧げたエディタ実装です。

---

## 🌟 歴史的背景とロマン

1. **Java の父がかつて作ったエディタ**:
   - 1981年、CMUのジェームズ・ゴスリン（James Gosling）は、Unix向け初の実用的Emacsクローンである「Gosling Emacs」を開発しました。
   - そのエディタを拡張するためにゴスリン自身が考案したS式スクリプト言語が **「Mocklisp（MLisp）」** です。
   - のちにゴスリンが生み出す言語「Java」自身を使って、ゴスリンの原点である「Gosling Emacs」と「Mocklisp」を再現するという、計算機科学史における究極のオマージュです。
2. **Mocklisp（MLisp）の内包**:
   - 外部ライブラリを一切使わず、Java標準機能のみで軽量S式パーサ＆評価器を内蔵。
   - `(insert-string "...")`, `(beginning-of-line)`, `(end-of-line)`, `(progn ...)`, `(setq ...)` などの伝統的なGosmacsプリミティブを解釈・実行します。
3. **`M-:` による動的 Mocklisp 評価 & `init.ml` の自動実行**:
   - 起動時に `./init.ml` を自動探索して評価。
   - エディタ実行中に **`M-:`**（Alt + `:` または Esc → `:`）を押すと、S式を入力して動いているエディタをリアルタイム操作可能！

---

## 🚀 起動方法

```bash
cd examples/java
java inzm.java sample.txt
```
（単一ファイル直接実行により、事前コンパイルなしで即座に起動します）

---

## ⌨️ キーバインド & 操作方法

### 1. Emacs キーバインド
| キー | 動作 |
| :--- | :--- |
| **C-p / C-n** | 前の行 / 次の行（↑ / ↓） |
| **C-b / C-f** | 前の文字 / 次の文字（← / →） |
| **C-a / C-e** | 行頭へ / 行末へ |
| **C-d** | 1文字削除 (Delete) |
| **C-k** | 行末まで削除 (Kill line) |
| **C-g** | キャンセル (Quit) |
| **C-x C-s** | ファイル保存（末尾 `\n` 保証） |
| **C-x C-c** | 終了 |
| **矢印キー** | 端末標準の矢印キーでも移動可能 |

---

### 2. Mocklisp (MLisp) 式の評価 (`M-:`)

**`M-:`**（Alt + `:` または Esc を押した後に `:`）を押すと、最下部に `Eval (MLisp): ` プロンプトが出現します。以下のS式を入力して Enter を押してみてください：

```lisp
;; 現在行の末尾に移動してコメントを挿入
(progn (end-of-line) (insert-string " /* Gosmacs */"))

;; ミニバッファにメッセージを表示
(message "Hello from James Gosling's Mocklisp!")

;; 変数を代入
(setq count (+ 10 20))
```

---

## 📜 サポートしている主な Mocklisp プリミティブ

| S式 | 動作 |
| :--- | :--- |
| `(insert-string <str>)` | 現在位置に文字列を挿入 |
| `(insert-character <int>)` | 文字コードに対応する文字を挿入 |
| `(beginning-of-line)` | 行頭へ移動 |
| `(end-of-line)` | 行末へ移動 |
| `(next-line)` / `(previous-line)` | 次の行 / 前の行へ移動 |
| `(forward-character)` / `(backward-character)` | 1文字進む / 戻る |
| `(delete-previous-character)` | Backspace（直前の文字削除） |
| `(kill-to-end-of-line)` | 行末までキル |
| `(write-current-file)` | ファイル保存 |
| `(exit-emacs)` | エディタ終了 |
| `(message <str>)` | ステータスバーにメッセージ表示 |
| `(setq <var> <val>)` | 大域変数へ代入 |
| `(progn <exp1> <exp2> ...)` | 順次実行（最後の式の値を返す） |
| `(if <cond> <then> [else])` | 条件分岐 |
| `(+ <a> <b> ...)` / `(- <a> <b> ...)` | 整数演算 |
