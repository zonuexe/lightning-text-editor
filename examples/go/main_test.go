package main

import (
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
	if cur.CursorY != 0 {
		t.Fatalf("Expected jump to line 0, got %d", cur.CursorY)
	}
}
