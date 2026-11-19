package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestVimFeatures(t *testing.T) {
	ed := NewEditor([]string{"sample1.txt"})
	cur := ed.CurrentBuffer()
	initialLine := cur.Lines[0]

	// 1. テスト yy -> p
	ed.HandleInput("y")
	ed.HandleInput("y")
	if ed.YankRegister != initialLine {
		t.Fatalf("Expected yanked '%s', got '%s'", initialLine, ed.YankRegister)
	}

	ed.HandleInput("p")
	if len(cur.Lines) <= 1 || cur.Lines[1] != initialLine {
		t.Fatalf("Expected pasted '%s' at line 1, got '%s'", initialLine, cur.Lines[1])
	}

	// 2. テスト D
	cur.CursorX = 5
	ed.HandleInput("D")
	if cur.Lines[cur.CursorY] != "Hello" {
		t.Fatalf("Expected 'Hello' after D at pos 5, got '%s'", cur.Lines[cur.CursorY])
	}

	// 3. テスト :1 行ジャンプ
	ed.HandleInput(":")
	ed.HandleInput("1")
	ed.HandleInput("\r")
	// 4. テスト EditorConfig
	if cur.EditorConfig != nil {
		t.Logf("EditorConfig resolved for sample1.txt: IndentStyle=%s", cur.EditorConfig.IndentStyle)
	}
}

func TestDrainStreamTokensStreamingPaste(t *testing.T) {
	// 1. UTF-8 multi-byte rune split right at the 5-byte guard boundary
	// "\x1b[200~" enters paste mode. Next chunk is "a\xe3\x81" + 5 guard bytes "\x82bcde" ->
	// wait: len("a\xe3\x81") + 5 = 8, so safe = 8 - 5 = 3 -> "a\xe3\x81" would be emitted if not walked back!
	var pending []byte
	inPaste := false
	pending = append(pending, []byte("\x1b[200~a\xe3\x81\x82bcde")...)
	toks := drainStreamTokens(&pending, &inPaste, false)
	if !inPaste {
		t.Fatalf("expected inPaste=true")
	}
	if !reflect.DeepEqual(toks, []string{"PASTE:a"}) {
		t.Fatalf("expected [\"PASTE:a\"] without splitting UTF-8, got %#v", toks)
	}
	pending = append(pending, []byte("\x1b[201~")...)
	toks2 := drainStreamTokens(&pending, &inPaste, false)
	if inPaste {
		t.Fatalf("expected inPaste=false after end marker")
	}
	if !reflect.DeepEqual(toks2, []string{"PASTE:あbcde"}) {
		t.Fatalf("expected [\"PASTE:あbcde\"], got %#v", toks2)
	}
	if len(pending) != 0 {
		t.Fatalf("expected empty pending, got %q", pending)
	}

	// 2. CRLF split across streaming boundary must not split '\r' from '\n'
	pending = []byte("\x1b[200~hello\r\n1234")
	inPaste = false
	toks = drainStreamTokens(&pending, &inPaste, false)
	if !reflect.DeepEqual(toks, []string{"PASTE:hello"}) {
		t.Fatalf("expected [\"PASTE:hello\"] holding back '\\r', got %#v", toks)
	}
	pending = append(pending, []byte("\x1b[201~")...)
	toks2 = drainStreamTokens(&pending, &inPaste, false)
	if !reflect.DeepEqual(toks2, []string{"PASTE:\r\n1234"}) {
		t.Fatalf("expected [\"PASTE:\\r\\n1234\"], got %#v", toks2)
	}
}

func TestProbeEawPreservesTypeAhead(t *testing.T) {
	// Type-ahead CSI before CPR and after CPR
	ch := make(chan []byte, 4)
	ch <- []byte("\x1b[A\x1b[1;3R\x1b[B")
	close(ch)
	var pending []byte
	eaw := probeEaw(ch, &pending)
	if !eaw {
		t.Fatalf("expected EAW=true for col 3")
	}
	if string(pending) != "\x1b[A\x1b[B" {
		t.Fatalf("expected pending %q, got %q", "\x1b[A\x1b[B", string(pending))
	}

	// CSI + 'R' before real Non-EAW CPR (\x1b[1;2R)
	ch2 := make(chan []byte, 4)
	ch2 <- []byte("\x1b[AR")
	ch2 <- []byte("\x1b[1;2R")
	close(ch2)
	var pending2 []byte
	eaw2 := probeEaw(ch2, &pending2)
	if eaw2 {
		t.Fatalf("expected EAW=false for col 2")
	}
	if string(pending2) != "\x1b[AR" {
		t.Fatalf("expected pending %q, got %q", "\x1b[AR", string(pending2))
	}
}

func TestModeInsertEscPlusKeyAndPasteRouting(t *testing.T) {
	ed := NewEditor([]string{"nonexistent_test_file.txt"})
	cur := ed.CurrentBuffer()
	cur.Lines = []string{"line1", "line2"}

	// Enter Insert mode, type "ab", then fast Esc + j
	ed.HandleInput("i")
	ed.HandleInput("a")
	ed.HandleInput("b")
	ed.HandleInput("\x1bj")
	if ed.Mode != ModeNormal {
		t.Fatalf("expected ModeNormal after \\x1bj, got %v", ed.Mode)
	}
	if cur.CursorY != 1 || cur.CursorX != 1 {
		t.Fatalf("expected cursor at (1, 1), got (%d, %d)", cur.CursorX, cur.CursorY)
	}

	// Re-enter Insert mode and press fast Esc + ':'
	ed.HandleInput("i")
	ed.HandleInput("\x1b:")
	if ed.Mode != ModeCommand {
		t.Fatalf("expected ModeCommand after \\x1b:, got %v", ed.Mode)
	}

	// Paste in ModeCommand appends sanitized single-line to CommandLine
	ed.InsertPastedText("w foo\x1b[31m\nignored")
	if strings.Contains(ed.CommandLine, "\n") || strings.Contains(ed.CommandLine, "\x1b") {
		t.Fatalf("CommandLine should be sanitized single-line, got %q", ed.CommandLine)
	}
	if ed.CommandLine != "w foo[31m" {
		t.Fatalf("unexpected CommandLine: %q", ed.CommandLine)
	}

	// Paste in ModeNormal clamps CursorX < len(runes)
	ed.Mode = ModeNormal
	cur.Lines = []string{""}
	cur.CursorY = 0
	cur.CursorX = 0
	ed.InsertPastedText("XYZ")
	if cur.Lines[0] != "XYZ" {
		t.Fatalf("expected 'XYZ', got %q", cur.Lines[0])
	}
	if cur.CursorX != 2 {
		t.Fatalf("expected CursorX clamped to 2 in ModeNormal, got %d", cur.CursorX)
	}
}
