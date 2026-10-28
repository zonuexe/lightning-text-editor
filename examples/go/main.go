package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

// --- 0. 文字幅計算 (EAW & DSRプローブ) ---
var isEaw = true

func runeWidth(r rune) int {
	// 1. 確定全角 (Wide / Fullwidth)
	if (r >= 0x1100 && r <= 0x115f) ||
		(r >= 0x2e80 && r <= 0xa4cf) ||
		(r >= 0xac00 && r <= 0xd7a3) ||
		(r >= 0xf900 && r <= 0xfaff) ||
		(r >= 0xfe10 && r <= 0xfe19) ||
		(r >= 0xfe30 && r <= 0xfe6f) ||
		(r >= 0xff01 && r <= 0xff60) ||
		(r >= 0xffe0 && r <= 0xffe6) {
		return 2
	}

	// 2. 東アジア曖昧幅 (Ambiguous Width): ギリシャ、キリル、記号、矢印など
	if (r >= 0x0370 && r <= 0x03ff) || // ギリシャ文字
		(r >= 0x0400 && r <= 0x04ff) || // キリル文字
		(r >= 0x2010 && r <= 0x205e) || // 句読点
		(r >= 0x2100 && r <= 0x214f) || // 文字様記号 (℃ 等)
		(r >= 0x2190 && r <= 0x21ff) || // 矢印
		(r >= 0x2200 && r <= 0x22ff) || // 数学記号
		(r >= 0x25a0 && r <= 0x25ff) || // 幾何学模様 (■, ★, ○)
		(r >= 0x2600 && r <= 0x26ff) { // 記号 (※ 等)
		if isEaw {
			return 2
		}
		return 1
	}

	return 1
}

func probeEaw() bool {
	os.Stdout.WriteString("\x1b[1;1H\x1b[2Kα\x1b[6n")
	ch := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 32)
		n, err := os.Stdin.Read(buf)
		if err == nil && n > 0 {
			ch <- buf[:n]
		} else {
			ch <- nil
		}
	}()

	var resp []byte
	select {
	case resp = <-ch:
	case <-time.After(100 * time.Millisecond):
	}

	os.Stdout.WriteString("\x1b[1;1H\x1b[2K")
	if resp != nil {
		str := string(resp)
		if idx := strings.Index(str, ";"); idx != -1 {
			if end := strings.Index(str[idx:], "R"); end != -1 {
				colStr := str[idx+1 : idx+end]
				if col, err := strconv.Atoi(colStr); err == nil {
					return col == 3
				}
			}
		}
	}
	return true
}

func stringWidth(s string) int {
	w := 0
	for _, r := range s {
		w += runeWidth(r)
	}
	return w
}

func truncateToWidth(s string, maxW int) string {
	curW := 0
	var sb strings.Builder
	for _, r := range s {
		rw := runeWidth(r)
		if curW+rw > maxW {
			break
		}
		sb.WriteRune(r)
		curW += rw
	}
	return sb.String()
}

// --- 1. モード定義 ---
type Mode int

const (
	ModeNormal Mode = iota
	ModeInsert
	ModeCommand
)

func (m Mode) String() string {
	switch m {
	case ModeNormal:
		return "NORMAL"
	case ModeInsert:
		return "INSERT"
	case ModeCommand:
		return "COMMAND"
	default:
		return "NORMAL"
	}
}

// --- 2. バッファ構造体 (マルチバッファ用) ---
type Buffer struct {
	Filename   string
	Lines      []string
	CursorX    int // rune index
	CursorY    int // line index
	RowOffset  int
	IsModified bool
}

func NewBuffer(filename string) *Buffer {
	if filename == "" {
		filename = "untitled.txt"
	}
	buf := &Buffer{
		Filename: filename,
		Lines:    []string{""},
	}
	buf.Load()
	return buf
}

func (b *Buffer) Load() {
	data, err := os.ReadFile(b.Filename)
	if err != nil {
		b.Lines = []string{""}
		return
	}
	content := strings.ReplaceAll(string(data), "\r\n", "\n")
	content = strings.TrimSuffix(content, "\n")
	b.Lines = strings.Split(content, "\n")
	if len(b.Lines) == 0 {
		b.Lines = []string{""}
	}
}

func (b *Buffer) Save() error {
	content := strings.Join(b.Lines, "\n") + "\n"
	err := os.WriteFile(b.Filename, []byte(content), 0644)
	if err == nil {
		b.IsModified = false
	}
	return err
}

func (b *Buffer) RunesAt(y int) []rune {
	if y < 0 || y >= len(b.Lines) {
		return nil
	}
	return []rune(b.Lines[y])
}

func (b *Buffer) SetRunesAt(y int, rs []rune) {
	if y < 0 || y >= len(b.Lines) {
		return
	}
	b.Lines[y] = string(rs)
	b.IsModified = true
}

// --- 3. エディタ構造体 ---
type Editor struct {
	Buffers       []*Buffer
	ActiveBuf     int
	Mode          Mode
	CommandLine   string
	StatusMessage string
	Running       bool
	PendingKey    rune // 'd' や 'y' などの2ストローク用
	YankRegister  string
	OldState      *term.State
	Fd            int
}

func NewEditor(filenames []string) *Editor {
	ed := &Editor{
		Buffers:   make([]*Buffer, 0),
		ActiveBuf: 0,
		Mode:      ModeNormal,
		Running:   true,
		Fd:        int(os.Stdin.Fd()),
	}

	if len(filenames) == 0 {
		ed.Buffers = append(ed.Buffers, NewBuffer("untitled.txt"))
	} else {
		for _, fn := range filenames {
			ed.Buffers = append(ed.Buffers, NewBuffer(fn))
		}
	}
	return ed
}

func (ed *Editor) CurrentBuffer() *Buffer {
	if len(ed.Buffers) == 0 {
		return nil
	}
	if ed.ActiveBuf >= len(ed.Buffers) {
		ed.ActiveBuf = len(ed.Buffers) - 1
	}
	return ed.Buffers[ed.ActiveBuf]
}

func (ed *Editor) NextBuffer() {
	if len(ed.Buffers) <= 1 {
		return
	}
	ed.ActiveBuf = (ed.ActiveBuf + 1) % len(ed.Buffers)
	ed.StatusMessage = fmt.Sprintf("Switched to buffer %d: %s", ed.ActiveBuf+1, ed.CurrentBuffer().Filename)
}

func (ed *Editor) PrevBuffer() {
	if len(ed.Buffers) <= 1 {
		return
	}
	ed.ActiveBuf = (ed.ActiveBuf - 1 + len(ed.Buffers)) % len(ed.Buffers)
	ed.StatusMessage = fmt.Sprintf("Switched to buffer %d: %s", ed.ActiveBuf+1, ed.CurrentBuffer().Filename)
}

func (ed *Editor) CloseCurrentBuffer() {
	if len(ed.Buffers) <= 1 {
		ed.StatusMessage = "Cannot close the only buffer (use :q to quit)"
		return
	}
	cur := ed.CurrentBuffer()
	if cur.IsModified {
		ed.StatusMessage = "No write since last change (use :bd! to force)"
		return
	}
	ed.Buffers = append(ed.Buffers[:ed.ActiveBuf], ed.Buffers[ed.ActiveBuf+1:]...)
	if ed.ActiveBuf >= len(ed.Buffers) {
		ed.ActiveBuf = len(ed.Buffers) - 1
	}
	ed.StatusMessage = fmt.Sprintf("Buffer closed. Now on: %s", ed.CurrentBuffer().Filename)
}

func (ed *Editor) OpenBuffer(filename string) {
	for i, b := range ed.Buffers {
		if b.Filename == filename {
			ed.ActiveBuf = i
			ed.StatusMessage = fmt.Sprintf("Jumped to existing buffer: %s", filename)
			return
		}
	}
	nb := NewBuffer(filename)
	ed.Buffers = append(ed.Buffers, nb)
	ed.ActiveBuf = len(ed.Buffers) - 1
	ed.StatusMessage = fmt.Sprintf("Opened new buffer: %s", filename)
}

// --- 4. 画面描画 (タブバー + テキスト + ステータス + コマンドライン) ---
const LineNumWidth = 4

func (ed *Editor) WindowSize() (int, int) {
	w, h, err := term.GetSize(ed.Fd)
	if err != nil {
		return 80, 24
	}
	return w, h
}

func (ed *Editor) Scroll(screenRows int) {
	buf := ed.CurrentBuffer()
	if buf.CursorY < buf.RowOffset {
		buf.RowOffset = buf.CursorY
	}
	if buf.CursorY >= buf.RowOffset+screenRows {
		buf.RowOffset = buf.CursorY - screenRows + 1
	}
}

func (ed *Editor) Render() {
	ed.UpdateTitle()
	cols, rows := ed.WindowSize()
	buf := ed.CurrentBuffer()

	// 画面レイアウト:
	// Row 1: バッファタブバー
	// Row 2 .. rows-2: 本文テキスト (screenRows = rows - 3)
	// Row rows-1: ステータスライン
	// Row rows: コマンドライン / メッセージエリア
	screenRows := rows - 3
	if screenRows < 1 {
		screenRows = 1
	}
	ed.Scroll(screenRows)

	var sb strings.Builder
	sb.WriteString("\x1b[?25l") // カーソル隠す

	// 1. バッファタブバーの描画 (Row 1)
	sb.WriteString("\x1b[1;1H\x1b[7m")
	var tabText strings.Builder
	for i, b := range ed.Buffers {
		mark := ""
		if b.IsModified {
			mark = "*"
		}
		baseName := filepath.Base(b.Filename)
		if i == ed.ActiveBuf {
			tabText.WriteString(fmt.Sprintf(" [%d: %s%s] ", i+1, baseName, mark))
		} else {
			tabText.WriteString(fmt.Sprintf("  %d: %s%s  ", i+1, baseName, mark))
		}
	}
	tabStr := tabText.String()
	tabStr = truncateToWidth(tabStr, cols-1)
	sb.WriteString(tabStr)
	sb.WriteString("\x1b[0m\x1b[K")

	// 2. 本文テキストの描画 (Row 2 .. screenRows+1)
	for i := 0; i < screenRows; i++ {
		fileRow := buf.RowOffset + i
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", i+2))

		if fileRow < len(buf.Lines) {
			lineNum := fmt.Sprintf("%3d ", fileRow+1)
			sb.WriteString("\x1b[90m" + lineNum + "\x1b[0m")
			sb.WriteString(buf.Lines[fileRow])
			sb.WriteString("\x1b[K")
		} else {
			sb.WriteString("\x1b[90m  ~ \x1b[0m\x1b[K")
		}
	}

	// 3. ステータスラインの描画 (Row rows-1)
	sb.WriteString(fmt.Sprintf("\x1b[%d;1H\x1b[7m", rows-1))
	modeName := ed.Mode.String()
	modMark := ""
	if buf.IsModified {
		modMark = " [+]"
	}
	eawLabel := "[EAW]"
	if !isEaw {
		eawLabel = "[Non-EAW]"
	}
	leftStatus := fmt.Sprintf(" -- %s --  %s%s  %s", modeName, buf.Filename, modMark, eawLabel)
	rightStatus := fmt.Sprintf("%d/%d Ln, Col %d ", buf.CursorY+1, len(buf.Lines), buf.CursorX+1)

	leftW := stringWidth(leftStatus)
	rightW := stringWidth(rightStatus)
	maxBarW := cols - 1
	padding := maxBarW - leftW - rightW
	if padding < 0 {
		padding = 0
	}
	statusLine := leftStatus + strings.Repeat(" ", padding) + rightStatus
	sb.WriteString(truncateToWidth(statusLine, maxBarW))
	sb.WriteString("\x1b[0m\x1b[K")

	// 4. 最下行（コマンドライン / メッセージエリア） (Row rows)
	sb.WriteString(fmt.Sprintf("\x1b[%d;1H", rows))
	if ed.Mode == ModeCommand {
		sb.WriteString(":" + ed.CommandLine + "\x1b[K")
	} else if ed.StatusMessage != "" {
		sb.WriteString("\x1b[36m" + ed.StatusMessage + "\x1b[0m\x1b[K")
	} else {
		sb.WriteString("\x1b[90mCtrl+N/P: バッファ切替 | :w: 保存 | :q: 終了 | i: 挿入モード\x1b[0m\x1b[K")
	}

	// 5. カーソル位置の設定
	if ed.Mode == ModeCommand {
		cmdCursorX := 2 + stringWidth(ed.CommandLine)
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", rows, cmdCursorX))
	} else {
		screenY := buf.CursorY - buf.RowOffset + 2 // タブバー(1行) + 1-indexed
		runes := buf.RunesAt(buf.CursorY)
		visualX := 0
		if runes != nil && buf.CursorX <= len(runes) {
			visualX = stringWidth(string(runes[:buf.CursorX]))
		}
		screenX := visualX + LineNumWidth + 1
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", screenY, screenX))
	}

	sb.WriteString("\x1b[?25h") // カーソル表示
	os.Stdout.WriteString(sb.String())
}

// --- 5. コマンドラインの実行 (:w, :q, :e, :bn, :bp, :bd) ---
func (ed *Editor) ExecuteCommand() {
	cmd := strings.TrimSpace(ed.CommandLine)
	ed.CommandLine = ""
	ed.Mode = ModeNormal

	if cmd == "" {
		return
	}

	parts := strings.Fields(cmd)
	op := parts[0]

	switch op {
	case "w":
		cur := ed.CurrentBuffer()
		if len(parts) > 1 {
			cur.Filename = parts[1]
		}
		err := cur.Save()
		if err != nil {
			ed.StatusMessage = "Save error: " + err.Error()
		} else {
			ed.StatusMessage = fmt.Sprintf("\"%s\" %dL written", cur.Filename, len(cur.Lines))
		}
	case "q":
		cur := ed.CurrentBuffer()
		if cur.IsModified {
			ed.StatusMessage = "No write since last change (use :q! to override)"
		} else {
			ed.Running = false
		}
	case "q!":
		ed.Running = false
	case "wq":
		cur := ed.CurrentBuffer()
		if err := cur.Save(); err != nil {
			ed.StatusMessage = "Save error: " + err.Error()
		} else {
			ed.Running = false
		}
	case "e":
		if len(parts) > 1 {
			ed.OpenBuffer(parts[1])
		} else {
			ed.StatusMessage = "Argument required: :e <filename>"
		}
	case "bn", "bnext":
		ed.NextBuffer()
	case "bp", "bprev":
		ed.PrevBuffer()
	case "bd", "bdelete":
		ed.CloseCurrentBuffer()
	case "bd!":
		cur := ed.CurrentBuffer()
		cur.IsModified = false
		ed.CloseCurrentBuffer()
	case "ls", "buffers":
		var list []string
		for i, b := range ed.Buffers {
			m := ""
			if b.IsModified {
				m = "*"
			}
			list = append(list, fmt.Sprintf("%d:%s%s", i+1, b.Filename, m))
		}
		ed.StatusMessage = strings.Join(list, "  ")
	default:
		// :123 のような数値行ジャンプ
		if lineNum, err := strconv.Atoi(op); err == nil {
			cur := ed.CurrentBuffer()
			targetY := lineNum - 1
			if targetY < 0 {
				targetY = 0
			}
			if targetY >= len(cur.Lines) {
				targetY = len(cur.Lines) - 1
			}
			cur.CursorY = targetY
			cur.CursorX = 0
			ed.StatusMessage = fmt.Sprintf("Jumped to line %d", targetY+1)
			return
		}
		ed.StatusMessage = "Not an editor command: :" + cmd
	}
}

// --- 6. 入力ハンドリング (Vim モーダル) ---
func (ed *Editor) MoveCursor(dx, dy int) {
	buf := ed.CurrentBuffer()
	newY := buf.CursorY + dy
	if newY < 0 {
		newY = 0
	}
	if newY >= len(buf.Lines) {
		newY = len(buf.Lines) - 1
	}
	buf.CursorY = newY

	runes := buf.RunesAt(buf.CursorY)
	maxLen := len(runes)
	// ノーマルモードでは行末文字の上まで（maxLen - 1）
	if ed.Mode == ModeNormal && maxLen > 0 {
		if buf.CursorX >= maxLen {
			buf.CursorX = maxLen - 1
		}
	} else {
		if buf.CursorX > maxLen {
			buf.CursorX = maxLen
		}
	}
	if dx != 0 {
		buf.CursorX += dx
		if buf.CursorX < 0 {
			buf.CursorX = 0
		}
		limit := maxLen
		if ed.Mode == ModeNormal && limit > 0 {
			limit = maxLen - 1
		}
		if buf.CursorX > limit {
			buf.CursorX = limit
		}
	}
}

func (ed *Editor) InsertRune(r rune) {
	buf := ed.CurrentBuffer()
	runes := buf.RunesAt(buf.CursorY)
	newRunes := make([]rune, 0, len(runes)+1)
	newRunes = append(newRunes, runes[:buf.CursorX]...)
	newRunes = append(newRunes, r)
	newRunes = append(newRunes, runes[buf.CursorX:]...)
	buf.SetRunesAt(buf.CursorY, newRunes)
	buf.CursorX++
}

func (ed *Editor) InsertNewline() {
	buf := ed.CurrentBuffer()
	runes := buf.RunesAt(buf.CursorY)
	before := runes[:buf.CursorX]
	after := runes[buf.CursorX:]

	buf.SetRunesAt(buf.CursorY, before)
	newLines := make([]string, 0, len(buf.Lines)+1)
	newLines = append(newLines, buf.Lines[:buf.CursorY+1]...)
	newLines = append(newLines, string(after))
	newLines = append(newLines, buf.Lines[buf.CursorY+1:]...)
	buf.Lines = newLines

	buf.CursorY++
	buf.CursorX = 0
	buf.IsModified = true
}

func (ed *Editor) DeleteBackward() {
	buf := ed.CurrentBuffer()
	runes := buf.RunesAt(buf.CursorY)
	if buf.CursorX > 0 {
		newRunes := append(runes[:buf.CursorX-1], runes[buf.CursorX:]...)
		buf.SetRunesAt(buf.CursorY, newRunes)
		buf.CursorX--
	} else if buf.CursorY > 0 {
		prevRunes := buf.RunesAt(buf.CursorY - 1)
		prevLen := len(prevRunes)
		merged := append(prevRunes, runes...)
		buf.SetRunesAt(buf.CursorY-1, merged)

		buf.Lines = append(buf.Lines[:buf.CursorY], buf.Lines[buf.CursorY+1:]...)
		buf.CursorY--
		buf.CursorX = prevLen
		buf.IsModified = true
	}
}

func (ed *Editor) DeleteCharUnderCursor() {
	buf := ed.CurrentBuffer()
	runes := buf.RunesAt(buf.CursorY)
	if len(runes) == 0 {
		return
	}
	if buf.CursorX < len(runes) {
		newRunes := append(runes[:buf.CursorX], runes[buf.CursorX+1:]...)
		buf.SetRunesAt(buf.CursorY, newRunes)
		if buf.CursorX >= len(newRunes) && buf.CursorX > 0 {
			buf.CursorX--
		}
	}
}

func (ed *Editor) DeleteLine() {
	buf := ed.CurrentBuffer()
	if len(buf.Lines) <= 1 {
		buf.Lines = []string{""}
		buf.CursorX = 0
		buf.CursorY = 0
		buf.IsModified = true
		return
	}
	buf.Lines = append(buf.Lines[:buf.CursorY], buf.Lines[buf.CursorY+1:]...)
	if buf.CursorY >= len(buf.Lines) {
		buf.CursorY = len(buf.Lines) - 1
	}
	runes := buf.RunesAt(buf.CursorY)
	if buf.CursorX >= len(runes) && len(runes) > 0 {
		buf.CursorX = len(runes) - 1
	}
	buf.IsModified = true
}

func (ed *Editor) DeleteToEndOfLine() {
	buf := ed.CurrentBuffer()
	runes := buf.RunesAt(buf.CursorY)
	if len(runes) == 0 {
		return
	}
	if buf.CursorX < len(runes) {
		buf.SetRunesAt(buf.CursorY, runes[:buf.CursorX])
		if buf.CursorX > 0 && buf.CursorX >= len(runes[:buf.CursorX]) {
			buf.CursorX = len(runes[:buf.CursorX]) - 1
		}
		ed.StatusMessage = "Deleted to end of line"
	}
}

func (ed *Editor) PasteYanked() {
	if ed.YankRegister == "" {
		ed.StatusMessage = "Nothing to paste"
		return
	}
	buf := ed.CurrentBuffer()
	newLines := make([]string, 0, len(buf.Lines)+1)
	newLines = append(newLines, buf.Lines[:buf.CursorY+1]...)
	newLines = append(newLines, ed.YankRegister)
	newLines = append(newLines, buf.Lines[buf.CursorY+1:]...)
	buf.Lines = newLines
	buf.CursorY++
	buf.CursorX = 0
	buf.IsModified = true
	ed.StatusMessage = "1 line pasted"
}

func (ed *Editor) SetTitle(title string) {
	os.Stdout.WriteString(fmt.Sprintf("\x1b]0;%s\x07", title))
}

func (ed *Editor) UpdateTitle() {
	cur := ed.CurrentBuffer()
	if cur != nil {
		mod := ""
		if cur.IsModified {
			mod = "*"
		}
		ed.SetTitle(fmt.Sprintf("inzm - %s%s", cur.Filename, mod))
	}
}

// --- 7. メインループ ---
func (ed *Editor) Run() {
	oldState, err := term.MakeRaw(ed.Fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "MakeRaw error: %v\n", err)
		return
	}
	ed.OldState = oldState
	defer func() {
		ed.SetTitle("")
		// 代替画面から通常画面に戻してカーソル復帰
		os.Stdout.WriteString("\x1b[?1049l\x1b[?25h")
		term.Restore(ed.Fd, ed.OldState)
	}()

	// 代替画面バッファに入る
	os.Stdout.WriteString("\x1b[?1049h\x1b[2J\x1b[H")
	isEaw = probeEaw()
	ed.UpdateTitle()
	ed.Render()

	buf := make([]byte, 64)
	for ed.Running {
		n, err := os.Stdin.Read(buf)
		if err != nil || n == 0 {
			break
		}

		input := string(buf[:n])
		ed.HandleInput(input)
		if ed.Running {
			ed.Render()
		}
	}
}

func (ed *Editor) HandleInput(input string) {
	// 未知キー通知クリア（コマンドモード以外）
	if ed.Mode != ModeCommand && ed.StatusMessage != "" && !strings.HasPrefix(ed.StatusMessage, "Switched") && !strings.HasPrefix(ed.StatusMessage, "Opened") && !strings.HasPrefix(ed.StatusMessage, "\"") {
		ed.StatusMessage = ""
	}

	curBuf := ed.CurrentBuffer()
	r, _ := utf8.DecodeRuneInString(input)

	// グローバルバッファ切替ショートカット: Ctrl+N (0x0E) / Ctrl+P (0x10)
	if input == "\x0e" {
		ed.NextBuffer()
		return
	}
	if input == "\x10" {
		ed.PrevBuffer()
		return
	}

	switch ed.Mode {
	// ==================== 1. NORMAL モード ====================
	case ModeNormal:
		// 矢印キー
		if input == "\x1b[A" {
			ed.MoveCursor(0, -1)
			return
		} else if input == "\x1b[B" {
			ed.MoveCursor(0, 1)
			return
		} else if input == "\x1b[C" {
			ed.MoveCursor(1, 0)
			return
		} else if input == "\x1b[D" {
			ed.MoveCursor(-1, 0)
			return
		}

		// PageUp / PageDown
		if input == "\x1b[5~" || input == "\x1b[V" {
			_, rows := ed.WindowSize()
			ed.MoveCursor(0, -(rows - 3))
			return
		} else if input == "\x1b[6~" || input == "\x1b[U" {
			_, rows := ed.WindowSize()
			ed.MoveCursor(0, rows-3)
			return
		}

		// 2ストロークキー処理 (dd, yy)
		if ed.PendingKey == 'd' {
			if r == 'd' {
				ed.DeleteLine()
				ed.StatusMessage = "1 line deleted"
			}
			ed.PendingKey = 0
			return
		}
		if ed.PendingKey == 'y' {
			if r == 'y' {
				ed.YankRegister = curBuf.Lines[curBuf.CursorY]
				ed.StatusMessage = "1 line yanked"
			}
			ed.PendingKey = 0
			return
		}

		switch r {
		// 移動
		case 'h':
			ed.MoveCursor(-1, 0)
		case 'j':
			ed.MoveCursor(0, 1)
		case 'k':
			ed.MoveCursor(0, -1)
		case 'l':
			ed.MoveCursor(1, 0)
		case '0':
			curBuf.CursorX = 0
		case '$':
			runes := curBuf.RunesAt(curBuf.CursorY)
			if len(runes) > 0 {
				curBuf.CursorX = len(runes) - 1
			} else {
				curBuf.CursorX = 0
			}
		// インサート移行
		case 'i':
			ed.Mode = ModeInsert
		case 'a':
			runes := curBuf.RunesAt(curBuf.CursorY)
			if curBuf.CursorX < len(runes) {
				curBuf.CursorX++
			}
			ed.Mode = ModeInsert
		case 'A':
			runes := curBuf.RunesAt(curBuf.CursorY)
			curBuf.CursorX = len(runes)
			ed.Mode = ModeInsert
		case 'o':
			// 下に空行を追加してインサート
			curBuf.CursorX = len(curBuf.RunesAt(curBuf.CursorY))
			ed.InsertNewline()
			ed.Mode = ModeInsert
		case 'O':
			// 現在行の上に空行を追加してインサート
			newLines := make([]string, 0, len(curBuf.Lines)+1)
			newLines = append(newLines, curBuf.Lines[:curBuf.CursorY]...)
			newLines = append(newLines, "")
			newLines = append(newLines, curBuf.Lines[curBuf.CursorY:]...)
			curBuf.Lines = newLines
			curBuf.CursorX = 0
			curBuf.IsModified = true
			ed.Mode = ModeInsert

		// 削除 & ヤンク & ペースト
		case 'x':
			ed.DeleteCharUnderCursor()
		case 'D':
			ed.DeleteToEndOfLine()
		case 'd':
			ed.PendingKey = 'd'
		case 'y':
			ed.PendingKey = 'y'
		case 'p':
			ed.PasteYanked()

		// コマンドラインへ
		case ':':
			ed.Mode = ModeCommand
			ed.CommandLine = ""

		// バッファ切替 (gt / gT 簡易版)
		case ']':
			ed.NextBuffer()
		case '[':
			ed.PrevBuffer()
		}

	// ==================== 2. INSERT モード ====================
	case ModeInsert:
		// Esc または Ctrl+[ でノーマルモードへ
		if input == "\x1b" || input == "\x1b\x1b" || input == "\x1b[" {
			ed.Mode = ModeNormal
			if curBuf.CursorX > 0 {
				curBuf.CursorX--
			}
			return
		}

		// 矢印キー
		if input == "\x1b[A" {
			ed.MoveCursor(0, -1)
			return
		} else if input == "\x1b[B" {
			ed.MoveCursor(0, 1)
			return
		} else if input == "\x1b[C" {
			ed.MoveCursor(1, 0)
			return
		} else if input == "\x1b[D" {
			ed.MoveCursor(-1, 0)
			return
		}

		// Enter / 改行
		if input == "\r" || input == "\n" {
			ed.InsertNewline()
			return
		}

		// Backspace (DEL)
		if input == "\x7f" || input == "\x08" {
			ed.DeleteBackward()
			return
		}

		// 通常の文字入力 (UTF-8 全角・半角)
		if !strings.HasPrefix(input, "\x1b") && r >= ' ' {
			for _, ch := range input {
				ed.InsertRune(ch)
			}
		}

	// ==================== 3. COMMAND モード ====================
	case ModeCommand:
		if input == "\x1b" || input == "\x03" { // Esc または Ctrl+C でキャンセル
			ed.Mode = ModeNormal
			ed.CommandLine = ""
			ed.StatusMessage = ""
			return
		}
		if input == "\r" || input == "\n" {
			ed.ExecuteCommand()
			return
		}
		if input == "\x7f" || input == "\x08" {
			runes := []rune(ed.CommandLine)
			if len(runes) > 0 {
				ed.CommandLine = string(runes[:len(runes)-1])
			} else {
				ed.Mode = ModeNormal
			}
			return
		}
		// コマンドライン文字追加
		if !strings.HasPrefix(input, "\x1b") && r >= ' ' {
			ed.CommandLine += input
		}
	}
}

func main() {
	editor := NewEditor(os.Args[1:])
	editor.Run()
}
