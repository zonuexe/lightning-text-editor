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
import sys
import tty
import termios
import atexit

fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)

def cleanup():
    sys.stdout.write("\x1b[2J\x1b[H\x1b[?25h")
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

atexit.register(cleanup)

def read_key():
    ch = sys.stdin.read(1)
    if ch == '\x1b':
        # エスケープシーケンス（矢印キーなど）の簡易判定
        ch2 = sys.stdin.read(1)
        if ch2 == '[':
            ch3 = sys.stdin.read(1)
            return f"\x1b[{ch3}"
    return ch

# 生モードに切り替え
tty.setraw(fd)
cleanup()
sys.stdout.write("エディタ起動！ Ctrl+Q で終了\r\n")
sys.stdout.flush()

while True:
    key = read_key()

    # Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if key in ('\x11', '\x03'):
        break

    if key == '\x1b[A':  # 上矢印
        pass
    elif key == '\x1b[B':  # 下矢印
        pass
    elif key == '\x1b[C':  # 右矢印
        pass
    elif key == '\x1b[D':  # 左矢印
        pass
    elif key in ('\r', '\n'):  # Enter
        pass
    elif key in ('\x7f', '\x08'):  # Backspace
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
    f.write("\n".join(lines))
```
