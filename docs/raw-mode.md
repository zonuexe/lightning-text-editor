# ターミナルの生モード（Raw Mode）入門

普段私たちが使っているターミナルは、プログラムに文字が渡される前にシェルやOSが様々な前処理を行っています。これを**通常モード（Cooked / Canonical Mode）**と呼びます。

テキストエディタを作るためには、この前処理をオフにして、キー入力を生（Raw）のまま受け取る**生モード（Raw Mode）**に切り替える必要があります。

---

## 🍳 Cooked Mode と 🥩 Raw Mode の違い

| 動作 | Cooked Mode（通常） | Raw Mode（生モード） |
| :--- | :--- | :--- |
| **入力の引き渡し** | **Enterキーを押すまでプログラムに渡らない**（行バッファリング） | **1キー押した瞬間に即座に渡る** |
| **画面へのエコー** | 入力した文字が自動で画面に表示される | **自動表示されない**（プログラムが自前で描画する） |
| **Ctrl+C / Ctrl+Z / Ctrl+\\** | OSが割り込み信号（SIGINT / SIGTSTP / SIGQUIT）として拾う | **ただの1バイト（`\x03` 等）の文字として受け取れる**（`ISIG` 無効時） |
| **Ctrl+S / Ctrl+Q** | **XOFF/XON フロー制御として端末が画面出力を一時停止/再開する** | **`-ixon` を指定しないとエディタにキーが届かない** |
| **Enter (`\r`) の扱い** | `\r` が自動的に `\n` に変換される（`ICRNL`） | **`-icrnl` を指定しないと `Ctrl+M` と `Ctrl+J` が区別できない** |
| **Ctrl+V / Ctrl+O / Ctrl+Y** | 端末ドライバの拡張機能（`IEXTEN`）が「次の1文字をリテラル化（`lnext`）」「出力破棄（`discard`）」「遅延サスペンド（`dsusp`）」として横取りする（主に macOS / BSD。Linux は `discard` / `dsusp` 非対応で、`lnext` も ICANON 有効時のみ） | **`-iexten` を指定しないとエディタにキーが届かない**（nano の `^O` 保存や Emacs の `C-y` が壊れる） |

---

## ⚠️ シグナル（`-isig`）・拡張処理（`-iexten`）・フロー制御（`-ixon`）・改行変換（`-icrnl`）の無効化

ターミナルの歴史的遺産として、**`Ctrl+S`** は画面出力の一時停止（XOFF）、**`Ctrl+Q`** は出力再開（XON）として端末ドライバ自身が処理してしまいます。また `ICRNL` が有効なままだと、Enter キー（`\r`, `0x0d`）が `\n`（`0x0a`）に変換されて `Ctrl+J` と区別がつきません。さらに `IEXTEN` が有効なままだと `Ctrl+V` / `Ctrl+O`（macOS では `Ctrl+Y` も）が端末ドライバに食われます。

テキストエディタで制御キーを正確に受け取るには、**`-isig -iexten -ixon -icrnl`** をまとめて無効化します。

```bash
# 推奨される生モード化コマンド（元の設定を stty -g で必ず退避してから実行）
ORIG_STTY=$(stty -g)
stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0
```

※ `-isig` を付けないと、ユーザーが `Ctrl+\`（`SIGQUIT`）や `Ctrl+Z`（`SIGTSTP`）を押した瞬間に終了処理を通らず異常終了・サスペンドし、端末が壊れたまま残ることがあります。`intr undef quit undef susp undef` で個別に無効化する方法もありますが、macOS の `dsusp`（`Ctrl+Y`）など取りこぼしが出るため、`-isig` で一括無効化するほうが安全です。
※ `min 1 time 0` は「1バイト届くまで待ち、届いたら即返す」設定です（`termios` の `VMIN=1` / `VTIME=0` に相当）。

---

## ⚠️ 鉄則：終了時のモード復元と TTY チェック

生モードにしたままプログラムが異常終了すると、ターミナルが「キーを押しても画面に文字が出ない」「Enterを押しても改行されない」という状態（いわゆる**ターミナルが壊れた状態**）になります。

### 安全のための4大原則
1. **TTY チェック (`isatty`) を最初に行う**:
   - パイプ（`cat foo | editor`）や出力リダイレクト時に生モード化すると失敗・出力汚染するため、`stdin`/`stdout` が TTY かどうかを確認します。
2. **元の端末設定を保存し、必ず元の状態に戻す**:
   - `stty sane` のような決め打ちリセットはユーザーの元設定を上書きしてしまいます。可能なら `tcgetattr` や `stty -g` で取得した**起動前の設定そのもの**へ戻します。
   - `atexit` / `finally` / `defer` / `Drop` に加え、`SIGINT` / `SIGTERM` / `SIGHUP` でも復元処理が走るようにします。
3. **「出力フラッシュ → 端末復元」の順を守る**:
   - 終了時はまず通常画面バッファ復帰（`\x1b[?1049l`）、マウス・Bracketed Paste 解除（`\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?2004l`）、カーソル再表示（`\x1b[?25h`）、色リセット（`\x1b[0m`）を出力して **`flush` してから** Cooked Mode に戻します。
4. **万が一壊れた場合の救済コマンド**:
   - 画面が壊れたら、見えなくても `reset`（または `stty sane`）とタイプして Enter を押せば復旧します。

### 発展：外部コマンド実行（QuickRun 等）は `leave` / `enter` を対称にする
QuickRun や Git Diff ビューアなどで子プロセス（シェル・ページャ・インタプリタ）を実行するときは、**開始時に一度 Raw Mode と代替画面を解除（`leave`）し、子プロセス終了後に再び有効化（`enter`）する**と端末状態が衝突しません。

> 💡 **macOS 環境の豆知識**: Homebrew の GNU coreutils を PATH 先頭に入れていると、`gnubin/stty` が BSD/macOS 固有オプションで差異を生むことがあります。シェルスクリプト等から `stty` を呼ぶ場合は `/bin/stty` を明示すると安定します。

---

## 💻 言語別：Raw Mode の切り替えコード例

### Ruby (`io/console`)
```ruby
require 'io/console'

# ブロックを抜けると自動で通常モードに戻る安全設計
$stdin.raw do |io|
  char = io.getch
  puts "押されたキー: #{char.inspect}\r"
end
```

### TypeScript / Bun (`process.stdin.setRawMode`)
```typescript
if (!process.stdin.isTTY) process.exit(1);
process.stdin.setRawMode(true);
process.stdin.resume();

// 終了時は制御シーケンスを返してから Cooked Mode に戻す
process.on("exit", () => {
  process.stdout.write("\x1b[?25h\x1b[0m");
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
});
```

### Python (`termios` + `tty`)
```python
import os, sys, tty, termios

if not sys.stdin.isatty():
    sys.exit(1)
fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)

try:
    tty.setraw(fd)
    ch = os.read(fd, 1)
finally:
    sys.stdout.write("\x1b[?25h\x1b[0m")
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
```

### Go (`golang.org/x/term`)
```go
import (
    "os"
    "golang.org/x/term"
)

oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
if err != nil {
    panic(err)
}
defer term.Restore(int(os.Stdin.Fd()), oldState)
```

### PHP (`stty`)
```php
if (!stream_isatty(STDIN)) {
    fwrite(STDERR, "Not a TTY\n");
    exit(1);
}
// 起動前の端末設定を保存してから生モード化
$origStty = trim((string)shell_exec('stty -g'));
system('stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0');

// 終了時に必ず元の設定へ復元
register_shutdown_function(function () use ($origStty) {
    echo "\x1b[?1049l\x1b[?25h\x1b[0m";
    fflush(STDOUT);
    if ($origStty !== '') {
        system('stty ' . escapeshellarg($origStty));
    } else {
        system('stty sane');
    }
});
```
