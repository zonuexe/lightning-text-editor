# Go版 クイックリファレンス

Goでは準標準パッケージ `golang.org/x/term` を利用すると、シンプルかつ堅牢にターミナル生モードと画面サイズ取得が実現できます。単一バイナリとしてビルド・配布できるのが強みです。

---

## ⚡️ クイックスタート

```bash
mkdir my-go-editor && cd my-go-editor
go mod init my-editor
go get golang.org/x/term
touch main.go
go run main.go
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```go
// main.go
package main

import (
	"fmt"
	"os"

	"golang.org/x/term"
)

func cleanup() {
	fmt.Print("\x1b[2J\x1b[H\x1b[?25h")
}

func main() {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		panic(err)
	}
	defer func() {
		cleanup()
		term.Restore(fd, oldState)
	}()

	cleanup()
	fmt.Print("Goエディタ起動！ Ctrl+Q で終了\r\n")

	buf := make([]byte, 3)
	for {
		n, err := os.Stdin.Read(buf)
		if err != nil {
			break
		}

		// Ctrl+Q (0x11) または Ctrl+C (0x03) で終了
		if n == 1 && (buf[0] == 0x11 || buf[0] == 0x03) {
			break
		}

		// 特殊キー判定
		if n == 3 && buf[0] == 0x1b && buf[1] == '[' {
			switch buf[2] {
			case 'A': // 上矢印
			case 'B': // 下矢印
			case 'C': // 右矢印
			case 'D': // 左矢印
			}
			continue
		}

		if buf[0] == '\r' || buf[0] == '\n' {
			// Enter
		} else if buf[0] == 127 || buf[0] == 8 {
			// Backspace
		} else {
			// 通常文字
		}
	}
}
```

---

## 💾 ファイル保存と読み込み

Go標準の `os.ReadFile` と `os.WriteFile` で手軽に処理できます。

```go
import (
	"os"
	"strings"
)

// 読み込み
data, err := os.ReadFile("sample.txt")
var lines []string
if err == nil {
	lines = strings.Split(string(data), "\n")
} else {
	lines = []string{""}
}

// 保存
err = os.WriteFile("sample.txt", []byte(strings.Join(lines, "\n") + "\n"), 0644)
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`os.Stdin.Read(buf)` は必ず `for` ループの内側で呼ぶ**:
   - ループの外で1度だけ読んでしまうと、最初の入力バイトを永久に処理し続ける無限ループになります。
2. **文字列スライスはバイト単位ではなく `[]rune` で扱う**:
   - Go の `string` インデックスはバイト長です。日本語（3バイト）をバイト単位でスライスすると文字化けします。必ず `[]rune(line)` に変換して操作しましょう。
3. **非推奨の `golang.org/x/crypto/ssh/terminal` ではなく `golang.org/x/term` を使う**:
   - 古い記事では `golang.org/x/crypto/ssh/terminal` が使われることがありますが、現在は非推奨です。現代の Go では準標準の `golang.org/x/term` を利用します。
4. **3バイト固定バッファと `SIGWINCH` / `SIGTERM` の並行性に注意**:
   - 最小コードの `make([]byte, 3)` は `Shift+矢印`（`\x1b[1;2A`: 6バイト）や 4 バイト絵文字・貼り付け入力を取りこぼすため、実運用では大きめのバッファ＋シーケンス切り出しパーサにします。また `os/signal` で `SIGWINCH` や `SIGTERM` を別ゴルーチンで受ける場合、そのゴルーチンから直接 `Render()` や `Editor` 状態を書き換えると入力ループとデータ競合します。必ず `resizeCh` 等でイベントループへ通知するか、適切に同期して「単一ループ内でサイズ更新＆再描画」を行い、さらにガター描画（例: `%*d │ ` の実表示列数）とカーソル/マウス X オフセットは単一の `GutterWidth()` 関数で一致させてください。
5. **まず縦切りの最小エディタを動かしてから拡張を重ねる**:
   - マルチバッファ・マウス・範囲選択・検索を最初から一度に書こうとすると結合前に破綻しやすいため、まず 1 バッファの描画・Raw Mode・文字入力・保存を動かした上で、`HandleInput` 等をテスト可能な関数として切り出しながら機能とユニットテストを積み上げてください（参照実装: [examples/go/](../examples/go/)）。
