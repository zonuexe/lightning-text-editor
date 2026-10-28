# inzm - Java (Gosling Emacs & Mocklisp, RSyntaxTextArea ハイライト搭載)

**Gradle** によるビルドと **RSyntaxTextArea** による本格シンタックスハイライトを搭載した、**James Gosling**（Javaの父）の原点である伝説の **Gosling Emacs (Gosmacs)** およびその拡張言語 **Mocklisp (MLisp)** オマージュエディタです。

---

## 🌟 特徴

1. **RSyntaxTextArea による本格シンタックスハイライト**:
   - Java 界で長年愛される名門字句解析エンジン RSyntaxTextArea をヘッドレス統合。
   - `.java`, `.py`, `.rb`, `.c`, `.cpp`, `.js`, `.json`, `.html`, `.xml`, `.ml` (Lisp) などを自動判別し、キーワード・コメント・文字列・データ型を ANSI フルカラーで着色。
   - 編集時のみ差分解析するハイライトキャッシュにより、カーソル移動やスクロールはゼロ遅延。
2. **内蔵 Mocklisp (MLisp) 実行エンジン**:
   - リスト構造（cons）を持たず、文字列・整数とエディタのバッファ駆動に特化したゴスリンのオリジナル手続き型S式体系を再現。
   - `(insert-string "...")`, `(beginning-of-line)`, `(end-of-line)`, `(kill-to-end-of-line)`, `(message "...")` などの Gosmacs 伝統プリミティブを網羅。
3. **`M-:` による動的 S式 Eval & `init.ml` 自動評価**:
   - 起動時にカレントディレクトリの `./init.ml` を自動探索して評価。
   - エディタ実行中に **`M-:`**（Alt + `:` または Esc → `:`）を押すと、S式を入力してその場でエディタを直接操作・自動編集可能！
4. **Emacs キーバインド & ターミナル作法**:
   - `C-p`, `C-n`, `C-f`, `C-b`, `C-a`, `C-e`, `C-d`, `C-k`
   - `C-x C-s`（保存）、`C-x C-c`（終了）
   - 代替画面バッファ (`\033[?1049h`)、DSRプローブによる EAW 自動検知、動的ウィンドウタイトル設定完備。

---

## 🚀 起動方法

```bash
cd examples/java
./gradlew run --args="sample.txt"
```
（Gradle Wrapper により、環境に Gradle がインストールされていなくても即座にビルド＆起動します）

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

**`M-:`**（Alt + `:` または Esc を押した後に `:`）を押すと、最下部に `Eval (MLisp): ` プロンプトが出現します：

```lisp
;; 現在行の末尾に移動してコメントを挿入
(progn (end-of-line) (insert-string " /* Gosmacs */"))

;; ミニバッファにメッセージを表示
(message "Hello from James Gosling's Mocklisp!")

;; 変数を代入
(setq count (+ 10 20))
```

---

## 📜 主な Mocklisp プリミティブ

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
