package main

import (
	"bytes"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/editorconfig/editorconfig-core-go/v2"
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

var cprRegex = regexp.MustCompile("\x1b\\[(\\d+);(\\d+)R")

func probeEaw(stdinCh <-chan []byte, pending *[]byte) bool {
	os.Stdout.WriteString("\x1b7\x1b[1;1H\x1b[2K\x1b[8mα\x1b[6n\x1b[0m")
	os.Stdout.Sync()

	var resp []byte
	deadline := time.NewTimer(100 * time.Millisecond)
	defer deadline.Stop()

probeLoop:
	for {
		select {
		case chunk, ok := <-stdinCh:
			if !ok {
				break probeLoop
			}
			resp = append(resp, chunk...)
			if loc := cprRegex.FindSubmatchIndex(resp); loc != nil {
				colStr := string(resp[loc[4]:loc[5]])
				*pending = append(*pending, resp[:loc[0]]...)
				*pending = append(*pending, resp[loc[1]:]...)
				os.Stdout.WriteString("\x1b[1;1H\x1b[2K\x1b8")
				os.Stdout.Sync()
				if col, err := strconv.Atoi(colStr); err == nil {
					return col == 3
				}
				return true
			}
		case <-deadline.C:
			break probeLoop
		}
	}

	if len(resp) > 0 {
		*pending = append(*pending, resp...)
	}
	os.Stdout.WriteString("\x1b[1;1H\x1b[2K\x1b8")
	os.Stdout.Sync()
	return true
}

func sanitizeAndMeasure(s string, maxW int, tabWidth int) (string, int) {
	col := 0
	var sb strings.Builder
	for _, r := range s {
		var w int
		var disp string
		if r == '\t' {
			w = tabWidth - (col % tabWidth)
			disp = strings.Repeat(" ", w)
		} else if r < 0x20 {
			w = 2
			disp = "^" + string(rune(r+64))
		} else if r == 0x7f {
			w = 2
			disp = "^?"
		} else if r >= 0x80 && r < 0xa0 {
			w = 1
			disp = "?"
		} else {
			w = runeWidth(r)
			disp = string(r)
		}
		if maxW >= 0 && col+w > maxW {
			break
		}
		sb.WriteString(disp)
		col += w
	}
	return sb.String(), col
}

func stringWidth(s string) int {
	_, w := sanitizeAndMeasure(s, -1, 4)
	return w
}

func truncateToWidth(s string, maxW int) string {
	out, _ := sanitizeAndMeasure(s, maxW, 4)
	return out
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
	Filename     string
	Lines        []string
	CursorX      int // rune index
	CursorY      int // line index
	RowOffset    int
	IsModified   bool
	EditorConfig *editorconfig.Definition
}

func NewBuffer(filename string) *Buffer {
	if filename == "" {
		filename = "untitled.txt"
	}
	buf := &Buffer{
		Filename: filename,
		Lines:    []string{""},
	}
	buf.ResolveEditorConfig()
	buf.Load()
	return buf
}

func (b *Buffer) ResolveEditorConfig() {
	def, err := editorconfig.GetDefinitionForFilename(b.Filename)
	if err == nil {
		b.EditorConfig = def
	}
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
	linesToSave := make([]string, len(b.Lines))
	copy(linesToSave, b.Lines)

	// EditorConfig: trim_trailing_whitespace
	if b.EditorConfig != nil && b.EditorConfig.TrimTrailingWhitespace != nil && *b.EditorConfig.TrimTrailingWhitespace {
		for i, l := range linesToSave {
			linesToSave[i] = strings.TrimRight(l, " \t")
		}
	}

	// EditorConfig: end_of_line
	eol := "\n"
	if b.EditorConfig != nil && b.EditorConfig.EndOfLine == "crlf" {
		eol = "\r\n"
	}

	content := strings.Join(linesToSave, eol)

	// EditorConfig: insert_final_newline
	if b.EditorConfig == nil || b.EditorConfig.InsertFinalNewline == nil || *b.EditorConfig.InsertFinalNewline {
		content += eol
	}

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
	sb.WriteString("\x1b[?2026h\x1b[?25l") // 同期描画開始 & カーソル隠す

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
	textCols := cols - LineNumWidth - 1
	if textCols < 1 {
		textCols = 1
	}
	for i := 0; i < screenRows; i++ {
		fileRow := buf.RowOffset + i
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", i+2))

		if fileRow < len(buf.Lines) {
			lineNum := fmt.Sprintf("%3d ", fileRow+1)
			sb.WriteString("\x1b[90m" + lineNum + "\x1b[0m")
			sb.WriteString(truncateToWidth(buf.Lines[fileRow], textCols))
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
	ecLabel := ""
	if buf.EditorConfig != nil {
		ind := buf.EditorConfig.IndentStyle
		if ind == "" {
			ind = "space"
		}
		size := buf.EditorConfig.IndentSize
		if size == "" {
			size = "4"
		}
		ecLabel = fmt.Sprintf("[EC:%s/%s]", ind, size)
	}
	leftStatus := fmt.Sprintf(" -- %s --  %s%s  %s %s", modeName, buf.Filename, modMark, eawLabel, ecLabel)
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
		sb.WriteString(truncateToWidth(":"+ed.CommandLine, maxBarW) + "\x1b[K")
	} else if ed.StatusMessage != "" {
		sb.WriteString("\x1b[36m" + truncateToWidth(ed.StatusMessage, maxBarW) + "\x1b[0m\x1b[K")
	} else {
		sb.WriteString("\x1b[90m" + truncateToWidth("Ctrl+N/P: バッファ切替 | :w: 保存 | :q: 終了 | i: 挿入モード", maxBarW) + "\x1b[0m\x1b[K")
	}

	// 5. カーソル位置の設定
	if ed.Mode == ModeCommand {
		cmdCursorX := 2 + stringWidth(ed.CommandLine)
		if cmdCursorX > cols {
			cmdCursorX = cols
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", rows, cmdCursorX))
	} else {
		screenY := buf.CursorY - buf.RowOffset + 2 // タブバー(1行) + 1-indexed
		runes := buf.RunesAt(buf.CursorY)
		visualX := 0
		if runes != nil && buf.CursorX <= len(runes) {
			visualX = stringWidth(string(runes[:buf.CursorX]))
		}
		screenX := visualX + LineNumWidth + 1
		if screenX > cols {
			screenX = cols
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", screenY, screenX))
	}

	sb.WriteString("\x1b[?25h\x1b[?2026l") // カーソル表示 & 同期描画終了
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
func drainStreamTokens(pending *[]byte, inPaste *bool, flushEsc bool) []string {
	var tokens []string
	buf := *pending
	i := 0
	for i < len(buf) {
		if *inPaste {
			endIdx := bytes.Index(buf[i:], []byte("\x1b[201~"))
			if endIdx == -1 {
				safe := len(buf) - i - 5
				if safe > 0 {
					k := safe - 1
					for k > 0 && safe-k < utf8.UTFMax && (buf[i+k]&0xC0) == 0x80 {
						k--
					}
					if !utf8.FullRune(buf[i+k : i+safe]) {
						safe = k
					}
				}
				if safe > 0 && buf[i+safe-1] == '\r' {
					safe--
				}
				if safe > 0 {
					tokens = append(tokens, "PASTE:"+string(buf[i:i+safe]))
					i += safe
				}
				break
			}
			if endIdx > 0 {
				tokens = append(tokens, "PASTE:"+string(buf[i:i+endIdx]))
			}
			i += endIdx + 6
			*inPaste = false
			continue
		}

		if buf[i] == 0x1b {
			if i+1 >= len(buf) {
				if flushEsc {
					tokens = append(tokens, "\x1b")
					i++
				}
				break
			}
			if buf[i+1] == '[' {
				j := i + 2
				found := false
				for j < len(buf) {
					if buf[j] >= 0x40 && buf[j] <= 0x7e {
						found = true
						break
					}
					j++
				}
				if !found {
					break
				}
				seq := string(buf[i : j+1])
				if seq == "\x1b[200~" {
					*inPaste = true
				} else {
					tokens = append(tokens, seq)
				}
				i = j + 1
				continue
			} else if buf[i+1] == 'O' {
				if i+2 >= len(buf) {
					break
				}
				switch buf[i+2] {
				case 'A':
					tokens = append(tokens, "\x1b[A")
				case 'B':
					tokens = append(tokens, "\x1b[B")
				case 'C':
					tokens = append(tokens, "\x1b[C")
				case 'D':
					tokens = append(tokens, "\x1b[D")
				case 'H':
					tokens = append(tokens, "\x1b[H")
				case 'F':
					tokens = append(tokens, "\x1b[F")
				default:
					tokens = append(tokens, string(buf[i:i+3]))
				}
				i += 3
				continue
			} else {
				tokens = append(tokens, string(buf[i:i+2]))
				i += 2
				continue
			}
		}

		if !utf8.FullRune(buf[i:]) {
			if len(buf)-i < utf8.UTFMax {
				break
			}
		}
		r, sz := utf8.DecodeRune(buf[i:])
		if sz == 0 {
			break
		}
		tokens = append(tokens, string(r))
		i += sz
	}
	*pending = append((*pending)[:0], buf[i:]...)
	return tokens
}

func (ed *Editor) InsertPastedText(pasted string) {
	pasted = strings.ReplaceAll(pasted, "\r\n", "\n")
	pasted = strings.ReplaceAll(pasted, "\r", "\n")

	if ed.Mode == ModeCommand {
		firstLine := strings.SplitN(pasted, "\n", 2)[0]
		var sb strings.Builder
		for _, ch := range firstLine {
			if ch == '\t' {
				sb.WriteRune(' ')
			} else if ch >= ' ' && ch != 0x7f && !(ch >= 0x80 && ch < 0xa0) {
				sb.WriteRune(ch)
			}
		}
		ed.CommandLine += sb.String()
		return
	}

	for _, ch := range pasted {
		if ch == '\n' {
			ed.InsertNewline()
		} else {
			ed.InsertRune(ch)
		}
	}

	if ed.Mode == ModeNormal {
		cur := ed.CurrentBuffer()
		runes := cur.RunesAt(cur.CursorY)
		if len(runes) > 0 && cur.CursorX >= len(runes) {
			cur.CursorX = len(runes) - 1
		}
	}
}

func (ed *Editor) Run() {
	if !term.IsTerminal(ed.Fd) {
		fmt.Fprintln(os.Stderr, "エラー: inzm は対話型ターミナル (TTY) で実行してください。")
		return
	}

	oldState, err := term.MakeRaw(ed.Fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "MakeRaw error: %v\n", err)
		return
	}
	ed.OldState = oldState
	defer func() {
		ed.SetTitle("")
		// Bracketed Paste 解除 & 代替画面から通常画面に戻してカーソル復帰
		os.Stdout.WriteString("\x1b[?2004l\x1b[?1049l\x1b[?25h\x1b[0m")
		os.Stdout.Sync()
		term.Restore(ed.Fd, ed.OldState)
	}()

	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGWINCH)
	defer signal.Stop(sigCh)

	stdinCh := make(chan []byte, 16)
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil || n == 0 {
				close(stdinCh)
				return
			}
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			stdinCh <- chunk
		}
	}()

	// 代替画面バッファ & Bracketed Paste 有効化
	os.Stdout.WriteString("\x1b[?1049h\x1b[?2004h\x1b[2J\x1b[H")
	os.Stdout.Sync()
	var pending []byte
	isEaw = probeEaw(stdinCh, &pending)
	ed.UpdateTitle()
	ed.Render()

	inPaste := false
	var escTimer *time.Timer
	var escC <-chan time.Time

	dispatchTokens := func(tokens []string) {
		for _, tok := range tokens {
			if strings.HasPrefix(tok, "PASTE:") {
				ed.InsertPastedText(strings.TrimPrefix(tok, "PASTE:"))
			} else {
				ed.HandleInput(tok)
			}
			if !ed.Running {
				break
			}
		}
		if ed.Running {
			ed.Render()
		}
	}

	if len(pending) > 0 {
		if tokens := drainStreamTokens(&pending, &inPaste, false); len(tokens) > 0 {
			dispatchTokens(tokens)
		}
	}

	for ed.Running {
		if len(pending) == 1 && pending[0] == 0x1b && !inPaste && escTimer == nil {
			escTimer = time.NewTimer(40 * time.Millisecond)
			escC = escTimer.C
		}

		select {
		case sig := <-sigCh:
			if sig == syscall.SIGWINCH {
				ed.Render()
			} else {
				ed.Running = false
			}
		case chunk, ok := <-stdinCh:
			if escTimer != nil {
				escTimer.Stop()
				escTimer = nil
				escC = nil
			}
			if !ok {
				ed.Running = false
				break
			}
			pending = append(pending, chunk...)
			dispatchTokens(drainStreamTokens(&pending, &inPaste, false))
		case <-escC:
			escTimer = nil
			escC = nil
			dispatchTokens(drainStreamTokens(&pending, &inPaste, true))
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
		if len(input) == 2 && input[0] == 0x1b {
			ed.Mode = ModeNormal
			if curBuf.CursorX > 0 {
				curBuf.CursorX--
			}
			ed.HandleInput(input[1:])
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

		// Tab キー (EditorConfig indent_style / indent_size 準拠)
		if input == "\t" {
			if curBuf.EditorConfig != nil && curBuf.EditorConfig.IndentStyle == "tab" {
				ed.InsertRune('\t')
			} else {
				spaces := 4
				if curBuf.EditorConfig != nil && curBuf.EditorConfig.IndentSize != "" {
					if n, err := strconv.Atoi(curBuf.EditorConfig.IndentSize); err == nil && n > 0 {
						spaces = n
					}
				}
				for i := 0; i < spaces; i++ {
					ed.InsertRune(' ')
				}
			}
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
