# Go版 クイックリファレンス

Goでは準標準パッケージ `golang.org/x/term` を利用すると、シンプルかつ堅牢にターミナル生モードと画面サイズ取得が実現できます。単一バイナリとしてビルド・配布できるのが強みです。

---

## ⚡️ クイックスタート

```bash
mkdir my-go-editor && cd my-go-editor
go mod init my-editor
# 下の「最小コード」を main.go として保存してから:
go mod tidy   # import から golang.org/x/term を取得して go.mod / go.sum に記録
go run .
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

`os.Stdin.Read` の1回分を「1キー」とみなすと、単独 `Esc`・`Shift+矢印`（`\x1b[1;2A`）・高速入力や貼り付けでまとめて届いたバイト列を正しく扱えません。読み取り専用のゴルーチンでバイトをチャネルへ流し、`readKey` で「1キー分」（UTF-8 の1文字、または終端バイトまでの ESC シーケンス）を切り出します。壊れた UTF-8 バイトは本文に入れずに捨て、読みすぎたバイトは `unread` で次のキーに回します。

```go
// main.go
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

const escTimeout = 50 * time.Millisecond

// keyReader は標準入力のバイト列から「1キー分」を切り出す
type keyReader struct {
	ch      <-chan byte
	pending []byte // 読みすぎたバイトを次のキーのために戻しておく
}

// newKeyReader は標準入力を読み続けるゴルーチンを起動し、バイトをチャネルへ流す。
// このゴルーチンは止められないため、外部コマンドに端末を渡す QuickRun 等とは併用できない
func newKeyReader() *keyReader {
	ch := make(chan byte, 1024)
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				close(ch)
				return
			}
			for _, b := range buf[:n] {
				ch <- b
			}
		}
	}()
	return &keyReader{ch: ch}
}

// next は1バイト返す。timeout > 0 なら、その時間内に届かなければ ok=false
func (r *keyReader) next(timeout time.Duration) (byte, bool) {
	if len(r.pending) > 0 {
		b := r.pending[0]
		r.pending = r.pending[1:]
		return b, true
	}
	if timeout <= 0 {
		b, ok := <-r.ch
		return b, ok
	}
	select {
	case b, ok := <-r.ch:
		return b, ok
	case <-time.After(timeout):
		return 0, false
	}
}

func (r *keyReader) unread(b byte) { r.pending = append([]byte{b}, r.pending...) }

// readKey は「1キー分」を返す: 通常文字は UTF-8 の1文字、特殊キーは ESC シーケンス丸ごと
func (r *keyReader) readKey() (string, bool) {
	for {
		b, ok := r.next(0)
		if !ok {
			return "", false
		}
		if b == 0x1b {
			return r.readEscape(), true
		}
		if b < 0x80 {
			return string([]byte{b}), true
		}
		// UTF-8 の先頭バイトから長さを決め、継続バイト（0x80..0xBF）だけを読み足す
		extra := 0
		switch {
		case b >= 0xC2 && b <= 0xDF:
			extra = 1
		case b >= 0xE0 && b <= 0xEF:
			extra = 2
		case b >= 0xF0 && b <= 0xF4:
			extra = 3
		default:
			continue // 先頭になれないバイトは捨てる
		}
		seq := []byte{b}
		for i := 0; i < extra; i++ {
			c, ok := r.next(escTimeout)
			if !ok {
				break
			}
			if c < 0x80 || c > 0xBF {
				r.unread(c) // 継続バイトでなければ次のキーとして読み直す
				break
			}
			seq = append(seq, c)
		}
		if utf8.Valid(seq) {
			return string(seq), true
		}
		// 壊れた UTF-8 は本文に入れずに捨てる
	}
}

// readEscape は ESC の後ろを読み、単独 Esc・Alt+文字・CSI / SS3 シーケンスを1キーにまとめる
func (r *keyReader) readEscape() string {
	b2, ok := r.next(escTimeout)
	if !ok {
		return "\x1b" // 50ms 以内に後続が無ければ単独 Esc
	}
	if b2 == 0x1b || b2 >= 0x80 {
		// Esc の直後に別のキー（Esc+矢印、Alt+日本語など）: Esc を単独で返し、残りは次のキーにする
		r.unread(b2)
		return "\x1b"
	}
	seq := []byte{0x1b, b2}
	switch b2 {
	case 'O': // SS3（F1〜F4 や一部端末の矢印）は1バイトで終わる
		if c, ok := r.next(escTimeout); ok {
			seq = append(seq, c)
		}
		return string(seq)
	case '[': // CSI は終端バイト（0x40..0x7E）まで読む。\x1b[1;2A のような長い列も1キーになる
		for {
			c, ok := r.next(escTimeout)
			if !ok {
				return string(seq)
			}
			seq = append(seq, c)
			if len(seq) == 3 && c == '[' {
				continue // Linux コンソールの F1〜F5（\x1b[[A 等）は '[' の次が終端
			}
			if c >= 0x40 && c <= 0x7e {
				return string(seq)
			}
		}
	default:
		return string(seq) // Alt+文字
	}
}

func main() {
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) || !term.IsTerminal(int(os.Stdout.Fd())) {
		fmt.Fprintln(os.Stderr, "Not a TTY")
		os.Exit(1)
	}
	oldState, err := term.MakeRaw(fd) // ICANON/ECHO/ISIG/IEXTEN/IXON/ICRNL などを無効化
	if err != nil {
		panic(err)
	}
	defer func() {
		// 通常画面へ戻し、カーソルと色を戻してから端末設定を復元する
		fmt.Print("\x1b[?1049l\x1b[?25h\x1b[0m")
		term.Restore(fd, oldState)
	}()

	fmt.Print("\x1b[?1049h\x1b[2J\x1b[H") // 代替画面へ（シェルの履歴を消さない）
	fmt.Print("Goエディタ起動！ Ctrl+Q で終了\r\n")

	keys := newKeyReader()
	for {
		key, ok := keys.readKey()
		if !ok {
			break
		}

		switch key {
		case "\x11", "\x03": // Ctrl+Q または Ctrl+C で終了
			return
		case "\x1b[A": // 上矢印
		case "\x1b[B": // 下矢印
		case "\x1b[C": // 右矢印
		case "\x1b[D": // 左矢印
		case "\x1b": // 単独 Esc（Vim 風ならノーマルモードへ）
		case "\r":
			// Enter
		case "\x7f", "\x08":
			// Backspace
		default:
			if key[0] == 0x1b || key[0] < 0x20 {
				// 未対応の特殊キー・制御文字は本文に入れずに無視する
				continue
			}
			// 通常文字（日本語も1文字ずつ届く）
		}
		fmt.Print("key: " + strconv.Quote(key) + "\r\n") // 動作確認用。本実装では削除して再描画する
	}
}
```

---

## 💾 ファイル保存と読み込み

Go標準の `os.ReadFile` と `os.WriteFile` で手軽に処理できます。

```go
import (
	"errors"
	"io/fs"
	"os"
	"strings"
)

// 読み込み（ファイルが無いときだけ空バッファ。それ以外のエラーは開かずに中断する）
data, err := os.ReadFile("sample.txt")
lines := []string{""}
if err == nil {
	// 末尾の改行を1つ外してから分割する（外さないと保存のたびに空行が1行ずつ増える）
	lines = strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
} else if !errors.Is(err, fs.ErrNotExist) {
	return err // 読めないファイルを空バッファで開くと、保存した瞬間に中身が消える
}

// 保存（書き込みエラーを必ず確認する）
if err := os.WriteFile("sample.txt", []byte(strings.Join(lines, "\n")+"\n"), 0644); err != nil {
	// 未保存フラグを下ろさず、ステータスバーにエラーを出す
}
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`os.Stdin.Read(buf)` は必ず `for` ループの内側で呼ぶ**:
   - ループの外で1度だけ読んでしまうと、最初の入力バイトを永久に処理し続ける無限ループになります。
2. **文字列スライスはバイト単位ではなく `[]rune` で扱う**:
   - Go の `string` インデックスはバイト長です。日本語（3バイト）をバイト単位でスライスすると文字化けします。必ず `[]rune(line)` に変換して操作しましょう。
3. **非推奨の `golang.org/x/crypto/ssh/terminal` ではなく `golang.org/x/term` を使う**:
   - 古い記事では `golang.org/x/crypto/ssh/terminal` が使われることがありますが、現在は非推奨です。現代の Go では準標準の `golang.org/x/term` を利用します。
4. **`Read` 1回 = 1キーと決め打ちしない／`SIGWINCH` / `SIGTERM` の並行性に注意**:
   - 別ゴルーチンで `panic` すると `main` の `defer` は実行されず、生モードのまま終了します。別ゴルーチンではイベント通知だけを行い、描画や編集ロジックは入力ループと同じゴルーチンで実行してください。
   - 最小コードの読み取りゴルーチンは止められないため、QuickRun 等で外部コマンドに端末を渡すと子プロセスへのキー入力を横取りします。外部コマンドを実行する場合は、読み取りを止められる設計（`term.MakeRaw` の解除と読み取りの一時停止を同期させる等）が必要です。
   - `make([]byte, 3)` で `n == 3` を矢印キーとみなすような判定は、`Shift+矢印`（`\x1b[1;2A`: 6バイト）・単独 `Esc`・まとめて届いた貼り付け入力を取りこぼし、`[3~` のような断片が本文に入る原因になります。最小コードの `readKey` のように終端バイトまで読んで1キーを切り出してください。また `os/signal` で `SIGWINCH` や `SIGTERM` を別ゴルーチンで受ける場合、そのゴルーチンから直接 `Render()` や `Editor` 状態を書き換えると入力ループとデータ競合します。必ず `resizeCh` 等でイベントループへ通知するか、適切に同期して「単一ループ内でサイズ更新＆再描画」を行い、さらにガター描画（例: `%*d │ ` の実表示列数）とカーソル/マウス X オフセットは単一の `GutterWidth()` 関数で一致させてください。
5. **まず縦切りの最小エディタを動かしてから拡張を重ねる**:
   - マルチバッファ・マウス・範囲選択・検索を最初から一度に書こうとすると結合前に破綻しやすいため、まず 1 バッファの描画・Raw Mode・文字入力・保存を動かした上で、`HandleInput` 等をテスト可能な関数として切り出しながら機能とユニットテストを積み上げてください（参照実装: [examples/go/](../examples/go/)）。
