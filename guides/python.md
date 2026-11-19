# Python版 クイックリファレンス

Pythonでは標準モジュールの `termios` と `tty` を使うことで、サードパーティ製ライブラリのインストールなしでターミナルエディタを実装できます。
さらに現代の Python では、**PEP 723（Inline script metadata）** を使うことで、`uv run` や `pipx run` を用いて仮想環境の作成不要で外部ライブラリ（`editorconfig` 等）を即座に利用できます。

---

## ⚡️ クイックスタート

### モダン手法: `uv run` + PEP 723 (推奨)
```bash
# スクリプト先頭に依存関係を宣言するだけ（仮想環境の事前作成不要）
uv run inzm.py sample.py
```

### 伝統手法: Python 3 標準
```bash
python3 inzm.py sample.py
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```python
# editor.py
import os
import sys
import tty
import termios
import atexit
import codecs
import select
import signal

fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)
utf8_dec = codecs.getincrementaldecoder("utf-8")("replace")
char_buf = ""

def cleanup():
    sys.stdout.write("\x1b[2J\x1b[H\x1b[?25h")
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

def read_char_timeout(timeout=None):
    global char_buf
    while not char_buf:
        if timeout is not None and not select.select([fd], [], [], timeout)[0]:
            return None
        chunk = os.read(fd, 1024)
        if not chunk:
            char_buf += utf8_dec.decode(b"", final=True)
            if not char_buf:
                return ""
            break
        char_buf += utf8_dec.decode(chunk)
    ch, char_buf = char_buf[0], char_buf[1:]
    return ch

def read_key():
    ch = read_char_timeout(None)
    if not ch:
        return ""
    if ch == "\x1b":
        # 50ms以内に後続が来なければ単独の Esc キーとして確定（ハング防止）
        ch2 = read_char_timeout(0.05)
        if not ch2:
            return "\x1b"
        if ch2 == "[":
            seq = "\x1b["
            while True:
                c = read_char_timeout(0.05)
                if not c:
                    break
                seq += c
                if 0x40 <= ord(c) <= 0x7E:  # CSI 終端バイト
                    break
            return seq
        return "\x1b" + ch2
    return ch

# 生モードに切り替え
tty.setraw(fd)
sys.stdout.write("\x1b[2J\x1b[H\x1b[?25h")
sys.stdout.write("エディタ起動！ Ctrl+Q で終了\r\n")
sys.stdout.flush()

while True:
    key = read_key()
    if not key:  # EOF
        break

    # Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if key in ("\x11", "\x03"):
        break

    if key == "\x1b[A":  # 上矢印
        pass
    elif key == "\x1b[B":  # 下矢印
        pass
    elif key == "\x1b[C":  # 右矢印
        pass
    elif key == "\x1b[D":  # 左矢印
        pass
    elif key in ("\r", "\n"):  # Enter
        pass
    elif key in ("\x7f", "\x08"):  # Backspace
        pass
    else:
        # 通常の文字入力
        pass
```

---

## 💾 ファイル保存と読み込み

```python
# 読み込み
import os

filename = "sample.txt"
if os.path.exists(filename):
    with open(filename, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\r\n") for line in f.readlines()]
else:
    lines = [""]

# 保存
with open(filename, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`Ctrl+Q` や `Ctrl+S` を文字 `'q'` や `'s'` と比較してはいけない**:
   - `Ctrl+Q` は ASCII `17` (`'\x11'`)、`Ctrl+S` は ASCII `19` (`'\x13'`) です。通常の文字 `'q'` と比較すると 'q' をタイプした瞬間にエディタが終了してしまいます。
2. **キー入力文字列を `.strip()` してはいけない**:
   - スペースキー（`" "`）が消えて空白が入力できなくなります。
3. **行内 Backspace のスライスミスに注意**:
   - カーソル直前の文字を消す正しいスライスは `line[:cx-1] + line[cx:]` です（`line[:cx] + line[cx:]` だと何も消えません）。
4. **終了時の `atexit` 登録と `Esc` タイムアウト、`select` + `TextIOWrapper` 禁止**:
   - 例外発生時に生モードのままだとターミナルが壊れます。必ず `termios.tcsetattr` で元に戻すクリーンアップ（と `SIGTERM` 対策）を登録してください。また `tty.setraw(fd)` の直後に `cleanup()` を呼んで即座に Cooked Mode へ戻してしまわないよう注意してください。
   - **アンチパターン（NG）**: `select.select([sys.stdin], ...)` と `sys.stdin.read(1)` の併用。`sys.stdin` は最初の `read(1)` で `\x1b[A` 全体をユーザー空間バッファへ先読みするため、直後の `select` が「入力なし」と誤判定して矢印キーが壊れます。必ず上記のように **`os.read(fd, 1024)` + アプリ側バッファ + `codecs.getincrementaldecoder("utf-8")`** を使います。
   - `SIGWINCH`（ウィンドウサイズ変更）を扱う場合は、ハンドラでフラグだけ立ててメインループ側でサイズ再取得・再描画します。
5. **行番号ガター幅とカーソル X 計算を一致させる**:
   - 行描画で `f"{i+1:4d} "`（5列）を出力したなら、カーソル X 座標も固定 `+ 5`（＋1-indexed の `+ 1`）で揃えます。`len(str(cursor_y + 1))` を使うとカーソル表示位置が左へズレます。また毎フレーム `\x1b[2J` を呼ぶとチラつくため、`\x1b[H` + 各行 `\x1b[K` で上書き描画します。
