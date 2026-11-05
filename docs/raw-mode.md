# ターミナルの生モード（Raw Mode）入門

普段私たちが使っているターミナルは、プログラムに文字が渡される前にシェルやOSが様々な前処理を行っています。これを**通常モード（Cooked / Canonical Mode）**と呼びます。

テキストエディタを作るためには、この前処理をオフにして、キー入力を生（Raw）のまま受け取る**生モード（Raw Mode）**に切り替える必要があります。

---

## 🍳 Cooked Mode と 🥩 Raw Mode の違い

| 動作 | Cooked Mode（通常） | Raw Mode（生モード） |
| :--- | :--- | :--- |
| **入力の引き渡し** | **Enterキーを押すまでプログラムに渡らない**（行バッファリング） | **1キー押した瞬間に即座に渡る** |
| **画面へのエコー** | 入力した文字が自動で画面に表示される | **自動表示されない**（プログラムが自前で描画する） |
| **Ctrl+C / Ctrl+Z** | OSが割り込み信号（SIGINT等）として拾い強制終了する | **ただの1バイト（\x03等）の文字として受け取れる** |
| **Ctrl+S / Ctrl+Q** | **XOFF/XON フロー制御として端末が画面出力を一時停止/再開する** | **`-ixon` を指定しないとエディタにキーが届かない** |
| **改行の扱い** | `\n` が自動的に `\r\n` に変換される | `\n` と `\r` は厳密に別物として扱われる |

---

## ⚠️ フロー制御（XON/XOFF）の無効化 (`-ixon`)

ターミナルの歴史的遺産として、**`Ctrl+S`** は画面出力の一時停止（XOFF）、**`Ctrl+Q`** は出力再開（XON）として端末ドライバ自身が処理してしまう仕様があります。
テキストエディタで `Ctrl+S`（保存）や `Ctrl+Q`（終了）を正常に受け取るためには、必ず **`-ixon`** フラグを渡してソフトウェアフロー制御を無効化する必要があります。

```bash
# 推奨される完全な生モード化コマンド
stty -icanon -echo -ixon
```

---

## ⚠️ 鉄則：終了時のモード復元

生モードにしたままプログラムが異常終了すると、ターミナルが「キーを押しても画面に文字が出ない」「Enterを押しても改行されない」という状態（いわゆる**ターミナルが壊れた状態**）になります。

### 安全のための3大原則
1. **必ず終了処理（クリーンアップ）を用意する**:
   - `try ... finally` や `process.on('exit')`、`atexit` などを活用し、どんな終了の仕方（Ctrl+Cやエラー）でもCooked Modeに戻す。
2. **画面をクリアしてカーソルを戻す**:
   - 終了時に画面を整えてからプロンプトを返す。
3. **万が一壊れた場合の救済コマンド**:
   - 画面が壊れたら、見えなくても `reset` とタイプしてEnterを押せば復旧します。

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
process.stdin.setRawMode(true);
process.stdin.resume();

// 終了時に必ず復元
process.on("exit", () => {
  process.stdin.setRawMode(false);
});
```

### Python (`termios` + `tty`)
```python
import sys, tty, termios

fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)

try:
    tty.setraw(fd)
    ch = sys.stdin.read(1)
finally:
    # 必ず元に戻す
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
// 生モード化
system("stty -icanon -echo");

// 終了時に復元
register_shutdown_function(function() {
    system("stty sane");
});
```
