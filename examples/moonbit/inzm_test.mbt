///|
test "insert, newline, backspace, and utf8 streaming" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="test.txt",
    content="hello\nworld",
  )
  assert_eq(ed.content(), "hello\nworld\n")
  let _ = ed.feed_str("!")
  assert_eq(ed.content(), "!hello\nworld\n")
  let _ = ed.feed_str("\u{1B}[C\u{1B}[C") // move right twice
  let _ = ed.feed_str("\r") // split line
  assert_eq(ed.content(), "!he\nllo\nworld\n")
  let _ = ed.feed_str("\u{7F}") // backspace joins lines back
  assert_eq(ed.content(), "!hello\nworld\n")
}

///|
test "japanese wide char width and fragmented utf8 bytes" {
  let ed = @inzm.Editor::new(cols=80, rows=24, filename="ja.txt", content="")
  // 'あ' in UTF-8 is E3 81 82; feed split across two reads
  let _ = ed.feed_bytes(b"\xe3\x81")
  assert_eq(ed.content(), "\n")
  let _ = ed.feed_bytes(b"\x82")
  assert_eq(ed.content(), "あ\n")
  assert_eq(@inzm.string_width("あa🍣", false), 5)
  // Ambiguous width toggle: '※' is 1 cell when is_eaw=false, 2 cells when is_eaw=true
  assert_eq(@inzm.string_width("※", false), 1)
  assert_eq(@inzm.string_width("※", true), 2)
}

///|
test "cut, paste, duplicate, and safe quit guard" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="clip.txt",
    content="first\nsecond",
  )
  let _ = ed.feed_str("\u{04}") // Ctrl+D duplicate
  assert_eq(ed.content(), "first\nfirst\nsecond\n")
  let _ = ed.feed_str("\u{0B}") // Ctrl+K cut
  assert_eq(ed.content(), "first\nsecond\n")
  let _ = ed.feed_str("\u{1B}[B\u{15}") // Down, Ctrl+U paste
  assert_eq(ed.content(), "first\nfirst\nsecond\n")
  // First Ctrl+Q warns when modified
  let _ = ed.feed_str("\u{11}")
  assert_eq(ed.should_quit(), false)
  // Second Ctrl+Q quits
  let _ = ed.feed_str("\u{11}")
  assert_eq(ed.should_quit(), true)
}

///|
test "save request lifecycle" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="save.txt",
    content="abc",
  )
  let _ = ed.feed_str("z")
  let _ = ed.feed_str("\u{13}") // Ctrl+S
  assert_eq(ed.take_save_request(), true)
  assert_eq(ed.take_save_request(), false)
  ed.mark_saved()
  let _ = ed.feed_str("\u{11}") // Ctrl+Q exits cleanly once saved
  assert_eq(ed.should_quit(), true)
}

///|
test "macos shortcuts: word jump, doc start/end, delete word and line start" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="mac.txt",
    content="alpha beta\ngamma delta",
  )
  // Cmd+Down -> doc end, Cmd+Backspace -> delete current line to start
  let _ = ed.feed_str("\u{1B}[1;5F")
  let _ = ed.feed_str("\u{1B}[127;9u")
  assert_eq(ed.content(), "alpha beta\n\n")
  // Cmd+Up -> doc start, Option+Right -> jump over "alpha ", Option+Backspace -> delete "alpha "
  let _ = ed.feed_str("\u{1B}[1;5H")
  let _ = ed.feed_str("\u{1B}[1;3C")
  let _ = ed.feed_str("\u{1B}\u{7F}")
  assert_eq(ed.content(), "beta\n\n")
  // Ctrl+N / Ctrl+F / Ctrl+P / Ctrl+B Cocoa navigation
  let _ = ed.feed_str("\u{0E}x") // Ctrl+N then 'x' on line 2
  assert_eq(ed.content(), "beta\nx\n")
}

///|
test "sgr mouse click moves cursor across wide chars" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="mouse.txt",
    content="first\nあいうえお",
  )
  // Gutter width for 2 lines is 4 cols (3 digits + 1 space), so col 5 is char 0.
  // Line 2 is row 2. "あ"(2 cols) + "い"(2 cols) => visual offset 4 => 1-based col 9.
  let _ = ed.feed_str("\u{1B}[<0;9;2M")
  let _ = ed.feed_str("X")
  assert_eq(ed.content(), "first\nあいXうえお\n")
}

///|
test "mouse wheel scrolls viewport without moving cursor" {
  let buf = StringBuilder()
  for i = 1; i <= 20; i = i + 1 {
    buf.write_string("line\{i}\n")
  }
  // 8 rows total => 6 visible text rows
  let ed = @inzm.Editor::new(
    cols=80,
    rows=8,
    filename="scroll.txt",
    content=buf.to_string(),
  )
  // Wheel down 3 lines: viewport moves to line4..line9, cursor stays at Ln 1, Col 1, hidden offscreen
  let frame = ed.feed_str("\u{1B}[<65;10;2M")
  assert_true(frame.contains("line4"))
  assert_true(frame.contains("Ln 1, Col 1"))
  assert_eq(frame.contains("\u{1B}[?25h"), false)
  // Typing snaps viewport back to cursor on line1
  let back = ed.feed_str("Z")
  assert_true(back.contains("Zline1"))
  assert_true(back.contains("\u{1B}[?25h"))
}

///|
test "range selection via shift arrows, mouse drag, select all, and replace" {
  let ed = @inzm.Editor::new(
    cols=80,
    rows=24,
    filename="sel.txt",
    content="hello world\nsecond line",
  )
  // Shift+Right 5 times selects "hello"
  let frame = ed.feed_str(
    "\u{1B}[1;2C\u{1B}[1;2C\u{1B}[1;2C\u{1B}[1;2C\u{1B}[1;2C",
  )
  assert_eq(ed.selected_text(), "hello")
  assert_true(frame.contains("\u{1B}[44;97m"))
  // Typing replaces selected range
  let _ = ed.feed_str("hi")
  assert_eq(ed.content(), "hi world\nsecond line\n")
  // Mouse press at row 1 col 8 ('w') then drag down to row 2 col 11 ('d')
  let _ = ed.feed_str("\u{1B}[<0;8;1M\u{1B}[<32;11;2M")
  assert_eq(ed.selected_text(), "world\nsecond")
  // Backspace deletes multi-line selection
  let _ = ed.feed_str("\u{7F}")
  assert_eq(ed.content(), "hi  line\n")
  // SelectAll + replace
  let _ = ed.feed_str("\u{1B}[97;9uX")
  assert_eq(ed.content(), "X\n")
}
