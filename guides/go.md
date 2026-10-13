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
		term.Restore(fd, oldState)
		cleanup()
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
err = os.WriteFile("sample.txt", []byte(strings.Join(lines, "\n")), 0644)
```
