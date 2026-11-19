///|
#derive(Eq)
pub struct Pos {
  line : Int32
  col : Int32
}

///|
/// Core text editor state machine, completely independent of host I/O (Browser / WASI).
pub struct Editor {
  mut lines : Array[String]
  mut cursor_x : Int32
  mut cursor_y : Int32
  mut anchor : Pos?
  mut row_offset : Int32
  mut col_offset : Int32
  mut cols : Int32
  mut rows : Int32
  mut filename : String
  mut is_modified : Bool
  mut status_message : String
  mut quit_confirm : Bool
  mut clipboard_line : String?
  mut is_eaw : Bool
  mut should_quit : Bool
  mut save_requested : Bool
  decoder : InputDecoder
}

///|
fn normalize_lines(content : String) -> Array[String] {
  if content == "" {
    return [""]
  }
  let lines : Array[String] = []
  let buf = StringBuilder()
  let chars = chars_of(content)
  let n = chars.length()
  let mut i = 0
  while i < n {
    let ch = chars[i]
    if ch == '\r' {
      lines.push(buf.to_string())
      buf.reset()
      if i + 1 < n && chars[i + 1] == '\n' {
        i += 2
      } else {
        i += 1
      }
    } else if ch == '\n' {
      lines.push(buf.to_string())
      buf.reset()
      i += 1
    } else {
      buf.write_char(ch)
      i += 1
    }
  }
  // Drop trailing empty line caused by final POSIX newline, unless content was only "\n"
  let tail = buf.to_string()
  if tail != "" || lines.is_empty() {
    lines.push(tail)
  }
  if lines.is_empty() {
    [""]
  } else {
    lines
  }
}

///|
/// Create a new `Editor` instance with initial terminal dimensions and file content.
pub fn Editor::new(
  cols~ : Int32,
  rows~ : Int32,
  filename~ : String,
  content~ : String,
) -> Editor {
  let safe_cols = if cols < 20 { 20 } else { cols }
  let safe_rows = if rows < 4 { 4 } else { rows }
  let fname = if filename == "" { "untitled.txt" } else { filename }
  {
    lines: normalize_lines(content),
    cursor_x: 0,
    cursor_y: 0,
    anchor: None,
    row_offset: 0,
    col_offset: 0,
    cols: safe_cols,
    rows: safe_rows,
    filename: fname,
    is_modified: false,
    status_message: "Ctrl+S: Save | Ctrl+Q: Quit | Ctrl+T: Toggle EAW",
    quit_confirm: false,
    clipboard_line: None,
    is_eaw: false,
    should_quit: false,
    save_requested: false,
    decoder: InputDecoder::new(),
  }
}

///|
/// Load a new file into the editor buffer and reset cursor/scroll state.
pub fn Editor::load_file(
  self : Editor,
  filename : String,
  content : String,
) -> Unit {
  self.filename = if filename == "" { "untitled.txt" } else { filename }
  self.lines = normalize_lines(content)
  self.cursor_x = 0
  self.cursor_y = 0
  self.anchor = None
  self.row_offset = 0
  self.col_offset = 0
  self.is_modified = false
  self.quit_confirm = false
  self.should_quit = false
  self.save_requested = false
  self.status_message = "Opened \{self.filename} (\{self.lines.length()} lines)"
}

///|
/// Update terminal dimensions.
pub fn Editor::resize(self : Editor, cols : Int32, rows : Int32) -> Unit {
  self.cols = if cols < 20 { 20 } else { cols }
  self.rows = if rows < 4 { 4 } else { rows }
  self.ensure_cursor_visible()
}

///|
pub fn Editor::should_quit(self : Editor) -> Bool {
  self.should_quit
}

///|
pub fn Editor::filename(self : Editor) -> String {
  self.filename
}

///|
pub fn Editor::take_save_request(self : Editor) -> Bool {
  let flag = self.save_requested
  self.save_requested = false
  flag
}

///|
pub fn Editor::mark_saved(self : Editor) -> Unit {
  self.is_modified = false
  self.quit_confirm = false
  self.status_message = "Saved \{self.filename} (\{self.lines.length()} lines)"
}

///|
pub fn Editor::set_status(self : Editor, msg : String) -> Unit {
  self.status_message = msg
}

///|
/// Return the serialized file content with a trailing newline.
pub fn Editor::content(self : Editor) -> String {
  let buf = StringBuilder()
  for i = 0; i < self.lines.length(); i = i + 1 {
    buf.write_string(self.lines[i])
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
fn Editor::text_rows(self : Editor) -> Int32 {
  let r = self.rows - 2
  if r < 1 {
    1
  } else {
    r
  }
}

///|
fn Editor::gutter_width(self : Editor) -> Int32 {
  let total = self.lines.length()
  let digits = total.to_string().length()
  let w = if digits < 3 { 3 } else { digits }
  w + 1 // digits + trailing space
}

///|
fn Editor::line_chars(self : Editor, y : Int32) -> Array[Char] {
  if y >= 0 && y < self.lines.length() {
    chars_of(self.lines[y])
  } else {
    []
  }
}

///|
fn Editor::clamp_cursor_x(self : Editor) -> Unit {
  let len = self.line_chars(self.cursor_y).length()
  if self.cursor_x > len {
    self.cursor_x = len
  }
  if self.cursor_x < 0 {
    self.cursor_x = 0
  }
}

///|
fn Editor::cursor_visual_x(self : Editor) -> Int32 {
  let chars = self.line_chars(self.cursor_y)
  let limit = if self.cursor_x < chars.length() {
    self.cursor_x
  } else {
    chars.length()
  }
  let mut w = 0
  for i = 0; i < limit; i = i + 1 {
    let (_, cw) = sanitize_char_at(chars[i], w, self.is_eaw)
    w += cw
  }
  w
}

///|
fn Editor::text_cols(self : Editor) -> Int32 {
  let gw = self.gutter_width()
  if self.cols > gw + 1 {
    self.cols - gw - 1
  } else {
    1
  }
}

///|
fn Editor::ensure_cursor_visible(self : Editor) -> Unit {
  let visible_rows = self.text_rows()
  if self.cursor_y < self.row_offset {
    self.row_offset = self.cursor_y
  }
  if self.cursor_y >= self.row_offset + visible_rows {
    self.row_offset = self.cursor_y - visible_rows + 1
  }
  let text_cols = self.text_cols()
  let safe_cols = if text_cols < 4 { 4 } else { text_cols }
  let vx = self.cursor_visual_x()
  if vx < self.col_offset {
    self.col_offset = vx
  }
  if vx >= self.col_offset + safe_cols {
    self.col_offset = vx - safe_cols + 1
  }
}

///|
fn Editor::insert_char(self : Editor, ch : Char) -> Unit {
  let chars = self.line_chars(self.cursor_y)
  let next : Array[Char] = []
  for i = 0; i < chars.length(); i = i + 1 {
    if i == self.cursor_x {
      next.push(ch)
    }
    next.push(chars[i])
  }
  if self.cursor_x >= chars.length() {
    next.push(ch)
  }
  self.lines[self.cursor_y] = chars_to_string(next)
  self.cursor_x += 1
  self.is_modified = true
}

///|
fn Editor::insert_newline(self : Editor) -> Unit {
  let chars = self.line_chars(self.cursor_y)
  let left = chars_to_string(chars[0:self.cursor_x])
  let right = chars_to_string(chars[self.cursor_x:chars.length()])
  self.lines[self.cursor_y] = left
  let next_lines : Array[String] = []
  for i = 0; i < self.lines.length(); i = i + 1 {
    next_lines.push(self.lines[i])
    if i == self.cursor_y {
      next_lines.push(right)
    }
  }
  self.lines = next_lines
  self.cursor_y += 1
  self.cursor_x = 0
  self.is_modified = true
}

///|
fn Editor::backspace(self : Editor) -> Unit {
  if self.cursor_x > 0 {
    let chars = self.line_chars(self.cursor_y)
    let next : Array[Char] = []
    for i = 0; i < chars.length(); i = i + 1 {
      if i != self.cursor_x - 1 {
        next.push(chars[i])
      }
    }
    self.lines[self.cursor_y] = chars_to_string(next)
    self.cursor_x -= 1
    self.is_modified = true
  } else if self.cursor_y > 0 {
    let prev_chars = self.line_chars(self.cursor_y - 1)
    let cur_line = self.lines[self.cursor_y]
    self.lines[self.cursor_y - 1] = self.lines[self.cursor_y - 1] + cur_line
    let next_lines : Array[String] = []
    for i = 0; i < self.lines.length(); i = i + 1 {
      if i != self.cursor_y {
        next_lines.push(self.lines[i])
      }
    }
    self.lines = next_lines
    self.cursor_y -= 1
    self.cursor_x = prev_chars.length()
    self.is_modified = true
  }
}

///|
fn Editor::delete_char(self : Editor) -> Unit {
  let chars = self.line_chars(self.cursor_y)
  if self.cursor_x < chars.length() {
    let next : Array[Char] = []
    for i = 0; i < chars.length(); i = i + 1 {
      if i != self.cursor_x {
        next.push(chars[i])
      }
    }
    self.lines[self.cursor_y] = chars_to_string(next)
    self.is_modified = true
  } else if self.cursor_y + 1 < self.lines.length() {
    let next_line = self.lines[self.cursor_y + 1]
    self.lines[self.cursor_y] = self.lines[self.cursor_y] + next_line
    let next_lines : Array[String] = []
    for i = 0; i < self.lines.length(); i = i + 1 {
      if i != self.cursor_y + 1 {
        next_lines.push(self.lines[i])
      }
    }
    self.lines = next_lines
    self.is_modified = true
  }
}

///|
fn Editor::cut_line(self : Editor) -> Unit {
  self.clipboard_line = Some(self.lines[self.cursor_y])
  if self.lines.length() == 1 {
    self.lines[0] = ""
    self.cursor_x = 0
  } else {
    let next_lines : Array[String] = []
    for i = 0; i < self.lines.length(); i = i + 1 {
      if i != self.cursor_y {
        next_lines.push(self.lines[i])
      }
    }
    self.lines = next_lines
    if self.cursor_y >= self.lines.length() {
      self.cursor_y = self.lines.length() - 1
    }
    self.clamp_cursor_x()
  }
  self.is_modified = true
  self.status_message = "Cut line to clipboard (Ctrl+U to paste)"
}

///|
fn Editor::paste_line(self : Editor) -> Unit {
  match self.clipboard_line {
    Some(clip) => {
      let next_lines : Array[String] = []
      for i = 0; i < self.lines.length(); i = i + 1 {
        if i == self.cursor_y {
          next_lines.push(clip)
        }
        next_lines.push(self.lines[i])
      }
      self.lines = next_lines
      self.cursor_y += 1
      self.clamp_cursor_x()
      self.is_modified = true
      self.status_message = "Pasted line"
    }
    None => self.status_message = "Clipboard is empty"
  }
}

///|
fn Editor::duplicate_line(self : Editor) -> Unit {
  let cur = self.lines[self.cursor_y]
  let next_lines : Array[String] = []
  for i = 0; i < self.lines.length(); i = i + 1 {
    next_lines.push(self.lines[i])
    if i == self.cursor_y {
      next_lines.push(cur)
    }
  }
  self.lines = next_lines
  self.cursor_y += 1
  self.is_modified = true
  self.status_message = "Duplicated line"
}

///|
fn is_space_char(ch : Char) -> Bool {
  ch == ' ' || ch == '\t'
}

///|
fn is_word_char(ch : Char) -> Bool {
  let cp = ch.to_int()
  ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_' || cp >= 0x80
}

///|
fn prev_word_index(chars : Array[Char], from : Int32) -> Int32 {
  let mut idx = if from > chars.length() { chars.length() } else { from }
  while idx > 0 && is_space_char(chars[idx - 1]) {
    idx -= 1
  }
  if idx == 0 {
    return 0
  }
  let target_word = is_word_char(chars[idx - 1])
  if target_word {
    while idx > 0 && is_word_char(chars[idx - 1]) {
      idx -= 1
    }
  } else {
    while idx > 0 &&
          !is_space_char(chars[idx - 1]) &&
          !is_word_char(chars[idx - 1]) {
      idx -= 1
    }
  }
  idx
}

///|
fn next_word_index(chars : Array[Char], from : Int32) -> Int32 {
  let n = chars.length()
  let mut idx = if from < 0 { 0 } else { from }
  if idx >= n {
    return n
  }
  if !is_space_char(chars[idx]) {
    let target_word = is_word_char(chars[idx])
    if target_word {
      while idx < n && is_word_char(chars[idx]) {
        idx += 1
      }
    } else {
      while idx < n && !is_space_char(chars[idx]) && !is_word_char(chars[idx]) {
        idx += 1
      }
    }
  }
  while idx < n && is_space_char(chars[idx]) {
    idx += 1
  }
  idx
}

///|
fn Editor::move_word_left(self : Editor) -> Unit {
  if self.cursor_x == 0 {
    if self.cursor_y > 0 {
      self.cursor_y -= 1
      self.cursor_x = self.line_chars(self.cursor_y).length()
    }
    return
  }
  let chars = self.line_chars(self.cursor_y)
  self.cursor_x = prev_word_index(chars, self.cursor_x)
}

///|
fn Editor::move_word_right(self : Editor) -> Unit {
  let chars = self.line_chars(self.cursor_y)
  if self.cursor_x >= chars.length() {
    if self.cursor_y + 1 < self.lines.length() {
      self.cursor_y += 1
      self.cursor_x = 0
    }
    return
  }
  self.cursor_x = next_word_index(chars, self.cursor_x)
}

///|
fn Editor::delete_word_back(self : Editor) -> Unit {
  if self.cursor_x == 0 {
    self.backspace()
    return
  }
  let chars = self.line_chars(self.cursor_y)
  let target = prev_word_index(chars, self.cursor_x)
  let left = chars_to_string(chars[0:target])
  let right = chars_to_string(chars[self.cursor_x:chars.length()])
  self.lines[self.cursor_y] = left + right
  self.cursor_x = target
  self.is_modified = true
}

///|
fn Editor::delete_word_forward(self : Editor) -> Unit {
  let chars = self.line_chars(self.cursor_y)
  if self.cursor_x >= chars.length() {
    self.delete_char()
    return
  }
  let target = next_word_index(chars, self.cursor_x)
  let left = chars_to_string(chars[0:self.cursor_x])
  let right = chars_to_string(chars[target:chars.length()])
  self.lines[self.cursor_y] = left + right
  self.is_modified = true
}

///|
fn Editor::delete_to_line_start(self : Editor) -> Unit {
  if self.cursor_x == 0 {
    return
  }
  let chars = self.line_chars(self.cursor_y)
  self.lines[self.cursor_y] = chars_to_string(
    chars[self.cursor_x:chars.length()],
  )
  self.cursor_x = 0
  self.is_modified = true
}

///|
fn pos_lt(a : Pos, b : Pos) -> Bool {
  a.line < b.line || (a.line == b.line && a.col < b.col)
}

///|
fn Editor::selection_range(self : Editor) -> (Pos, Pos)? {
  match self.anchor {
    None => None
    Some(a) => {
      let cur : Pos = { line: self.cursor_y, col: self.cursor_x, }
      if a == cur {
        None
      } else if pos_lt(a, cur) {
        Some((a, cur))
      } else {
        Some((cur, a))
      }
    }
  }
}

///|
pub fn Editor::selected_text(self : Editor) -> String {
  match self.selection_range() {
    None => ""
    Some((s, e)) =>
      if s.line == e.line {
        let chars = self.line_chars(s.line)
        chars_to_string(chars[s.col:e.col])
      } else {
        let buf = StringBuilder()
        let first_chars = self.line_chars(s.line)
        buf.write_string(
          chars_to_string(first_chars[s.col:first_chars.length()]),
        )
        buf.write_char('\n')
        for row = s.line + 1; row < e.line; row = row + 1 {
          buf.write_string(self.lines[row])
          buf.write_char('\n')
        }
        let last_chars = self.line_chars(e.line)
        buf.write_string(chars_to_string(last_chars[0:e.col]))
        buf.to_string()
      }
  }
}

///|
pub fn Editor::delete_selection(self : Editor) -> Bool {
  match self.selection_range() {
    None => false
    Some((s, e)) => {
      let start_chars = self.line_chars(s.line)
      let end_chars = self.line_chars(e.line)
      let prefix = chars_to_string(start_chars[0:s.col])
      let suffix = chars_to_string(end_chars[e.col:end_chars.length()])
      let next_lines : Array[String] = []
      for i = 0; i < self.lines.length(); i = i + 1 {
        if i < s.line || i > e.line {
          next_lines.push(self.lines[i])
        } else if i == s.line {
          next_lines.push(prefix + suffix)
        }
      }
      self.lines = next_lines
      self.cursor_y = s.line
      self.cursor_x = s.col
      self.anchor = None
      self.is_modified = true
      true
    }
  }
}

///|
fn Editor::begin_selection_if_none(self : Editor) -> Unit {
  if self.anchor is None {
    self.anchor = Some({ line: self.cursor_y, col: self.cursor_x, })
  }
}

///|
fn Editor::pos_from_click(self : Editor, col1 : Int32, row1 : Int32) -> Pos? {
  let text_rows = self.text_rows()
  if row1 < 1 || row1 > text_rows {
    return None
  }
  let target_y = self.row_offset + (row1 - 1)
  if target_y >= self.lines.length() {
    let last_y = self.lines.length() - 1
    return Some({ line: last_y, col: self.line_chars(last_y).length(), })
  }
  let gw = self.gutter_width()
  let rel_col = if col1 - 1 > gw { col1 - 1 - gw } else { 0 }
  let target_vx = self.col_offset + rel_col
  let chars = self.line_chars(target_y)
  let mut vx = 0
  let mut x = 0
  for i = 0; i < chars.length(); i = i + 1 {
    let (_, w) = sanitize_char_at(chars[i], vx, self.is_eaw)
    if vx + w > target_vx {
      break
    }
    vx += w
    x += 1
  }
  Some({ line: target_y, col: x, })
}

///|
fn Editor::handle_click(self : Editor, col1 : Int32, row1 : Int32) -> Unit {
  match self.pos_from_click(col1, row1) {
    Some(p) => {
      self.cursor_y = p.line
      self.cursor_x = p.col
      self.anchor = None
    }
    None => ()
  }
}

///|
fn Editor::handle_drag(self : Editor, col1 : Int32, row1 : Int32) -> Unit {
  match self.pos_from_click(col1, row1) {
    Some(p) => {
      self.begin_selection_if_none()
      self.cursor_y = p.line
      self.cursor_x = p.col
    }
    None => ()
  }
}

///|
fn Editor::scroll_viewport(self : Editor, delta : Int32) -> Unit {
  let visible = self.text_rows()
  let max_offset = if self.lines.length() > visible {
    self.lines.length() - visible
  } else {
    0
  }
  let mut next = self.row_offset + delta
  if next < 0 {
    next = 0
  }
  if next > max_offset {
    next = max_offset
  }
  self.row_offset = next
}

///|
fn Editor::move_cursor_simple(self : Editor, ev : KeyEvent) -> Unit {
  match ev {
    KeyEvent::Up | KeyEvent::ShiftUp | KeyEvent::Ctrl('p') => {
      if self.cursor_y > 0 {
        self.cursor_y -= 1
      }
      self.clamp_cursor_x()
    }
    KeyEvent::Down | KeyEvent::ShiftDown | KeyEvent::Ctrl('n') => {
      if self.cursor_y + 1 < self.lines.length() {
        self.cursor_y += 1
      }
      self.clamp_cursor_x()
    }
    KeyEvent::Left | KeyEvent::ShiftLeft | KeyEvent::Ctrl('b') =>
      if self.cursor_x > 0 {
        self.cursor_x -= 1
      } else if self.cursor_y > 0 {
        self.cursor_y -= 1
        self.cursor_x = self.line_chars(self.cursor_y).length()
      }
    KeyEvent::Right | KeyEvent::ShiftRight | KeyEvent::Ctrl('f') => {
      let len = self.line_chars(self.cursor_y).length()
      if self.cursor_x < len {
        self.cursor_x += 1
      } else if self.cursor_y + 1 < self.lines.length() {
        self.cursor_y += 1
        self.cursor_x = 0
      }
    }
    KeyEvent::Home | KeyEvent::ShiftHome | KeyEvent::Ctrl('a') =>
      self.cursor_x = 0
    KeyEvent::End | KeyEvent::ShiftEnd | KeyEvent::Ctrl('e') =>
      self.cursor_x = self.line_chars(self.cursor_y).length()
    KeyEvent::WordLeft | KeyEvent::ShiftWordLeft => self.move_word_left()
    KeyEvent::WordRight | KeyEvent::ShiftWordRight => self.move_word_right()
    KeyEvent::DocStart | KeyEvent::ShiftDocStart => {
      self.cursor_y = 0
      self.cursor_x = 0
    }
    KeyEvent::DocEnd | KeyEvent::ShiftDocEnd => {
      self.cursor_y = self.lines.length() - 1
      self.cursor_x = self.line_chars(self.cursor_y).length()
    }
    KeyEvent::PageUp => {
      let step = self.text_rows()
      self.cursor_y = if self.cursor_y > step {
        self.cursor_y - step
      } else {
        0
      }
      self.clamp_cursor_x()
    }
    KeyEvent::PageDown => {
      let step = self.text_rows()
      let max_y = self.lines.length() - 1
      self.cursor_y = if self.cursor_y + step < max_y {
        self.cursor_y + step
      } else {
        max_y
      }
      self.clamp_cursor_x()
    }
    _ => ()
  }
}

///|
/// Apply a single decoded `KeyEvent` to the editor state.
pub fn Editor::handle_key(self : Editor, ev : KeyEvent) -> Unit {
  if ev != KeyEvent::Ctrl('q') {
    self.quit_confirm = false
  }
  match ev {
    KeyEvent::Left | KeyEvent::Ctrl('b') =>
      match self.selection_range() {
        Some((s, _)) => {
          self.cursor_y = s.line
          self.cursor_x = s.col
          self.anchor = None
        }
        None => self.move_cursor_simple(ev)
      }
    KeyEvent::Right | KeyEvent::Ctrl('f') =>
      match self.selection_range() {
        Some((_, e)) => {
          self.cursor_y = e.line
          self.cursor_x = e.col
          self.anchor = None
        }
        None => self.move_cursor_simple(ev)
      }
    KeyEvent::Up
    | KeyEvent::Down
    | KeyEvent::Home
    | KeyEvent::End
    | KeyEvent::WordLeft
    | KeyEvent::WordRight
    | KeyEvent::DocStart
    | KeyEvent::DocEnd
    | KeyEvent::PageUp
    | KeyEvent::PageDown
    | KeyEvent::Ctrl('p')
    | KeyEvent::Ctrl('n')
    | KeyEvent::Ctrl('a')
    | KeyEvent::Ctrl('e') => {
      self.anchor = None
      self.move_cursor_simple(ev)
    }
    KeyEvent::ShiftUp
    | KeyEvent::ShiftDown
    | KeyEvent::ShiftLeft
    | KeyEvent::ShiftRight
    | KeyEvent::ShiftHome
    | KeyEvent::ShiftEnd
    | KeyEvent::ShiftWordLeft
    | KeyEvent::ShiftWordRight
    | KeyEvent::ShiftDocStart
    | KeyEvent::ShiftDocEnd => {
      self.begin_selection_if_none()
      self.move_cursor_simple(ev)
    }
    KeyEvent::SelectAll => {
      self.anchor = Some({ line: 0, col: 0, })
      self.cursor_y = self.lines.length() - 1
      self.cursor_x = self.line_chars(self.cursor_y).length()
      self.status_message = "Selected all"
    }
    KeyEvent::Enter => {
      ignore(self.delete_selection())
      self.insert_newline()
    }
    KeyEvent::Backspace => if !self.delete_selection() { self.backspace() }
    KeyEvent::Delete => if !self.delete_selection() { self.delete_char() }
    KeyEvent::DeleteWordBack =>
      if !self.delete_selection() {
        self.delete_word_back()
      }
    KeyEvent::DeleteWordForward =>
      if !self.delete_selection() {
        self.delete_word_forward()
      }
    KeyEvent::DeleteToLineStart =>
      if !self.delete_selection() {
        self.delete_to_line_start()
      }
    KeyEvent::Tab => {
      ignore(self.delete_selection())
      self.insert_char(' ')
      self.insert_char(' ')
    }
    KeyEvent::Char(ch) => {
      ignore(self.delete_selection())
      self.insert_char(ch)
    }
    KeyEvent::Ctrl('s') => {
      self.save_requested = true
      self.status_message = "Saving \{self.filename}..."
    }
    KeyEvent::Ctrl('q') =>
      if self.is_modified && !self.quit_confirm {
        self.quit_confirm = true
        self.status_message = "Unsaved changes! Press Ctrl+Q again to quit without saving."
      } else {
        self.should_quit = true
      }
    KeyEvent::Ctrl('k') => {
      self.anchor = None
      self.cut_line()
    }
    KeyEvent::Ctrl('u') => {
      ignore(self.delete_selection())
      self.paste_line()
    }
    KeyEvent::Ctrl('d') => {
      self.anchor = None
      self.duplicate_line()
    }
    KeyEvent::Ctrl('t') => {
      self.is_eaw = !self.is_eaw
      let mode = if self.is_eaw { "EAW=2 (Wide)" } else { "EAW=1 (Narrow)" }
      self.status_message = "Ambiguous width switched to \{mode}"
    }
    KeyEvent::Ctrl('l') => self.status_message = "Refreshed"
    KeyEvent::MouseClick(col, row) => self.handle_click(col, row)
    KeyEvent::MouseDrag(col, row) => self.handle_drag(col, row)
    KeyEvent::MouseWheelUp => self.scroll_viewport(-3)
    KeyEvent::MouseWheelDown => self.scroll_viewport(3)
    KeyEvent::Escape => self.anchor = None
    KeyEvent::Ctrl(_) => ()
  }
  match ev {
    KeyEvent::MouseWheelUp | KeyEvent::MouseWheelDown => ()
    _ => self.ensure_cursor_visible()
  }
}

///|
/// Process an input string chunk (e.g. from `xterm.js` `onData`) and return
/// the updated ANSI terminal output.
pub fn Editor::feed_str(self : Editor, chunk : String) -> String {
  let events = self.decoder.parse_str(chunk)
  for ev in events {
    if self.should_quit {
      break
    }
    self.handle_key(ev)
  }
  if self.should_quit {
    Editor::leave_alt_screen()
  } else {
    self.render()
  }
}

///|
/// Process raw input bytes (e.g. from WASI `fd_read`) and return the updated
/// ANSI terminal output.
pub fn Editor::feed_bytes(self : Editor, chunk : BytesView) -> String {
  let decoded = self.decoder.decode_bytes(chunk)
  self.feed_str(decoded)
}

///|
pub fn Editor::enter_alt_screen() -> String {
  "\u{1B}[?1049h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[2J\u{1B}[H"
}

///|
pub fn Editor::leave_alt_screen() -> String {
  "\u{1B}[?2004l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1049l\u{1B}[?25h\u{1B}[0m"
}

///|
fn pad_left(s : String, width : Int32, fill : Char) -> String {
  let len = s.length()
  if len >= width {
    return s
  }
  let buf = StringBuilder()
  for i = 0; i < width - len; i = i + 1 {
    buf.write_char(fill)
  }
  buf.write_string(s)
  buf.to_string()
}

///|
fn sanitize_and_measure(s : String, is_eaw : Bool) -> (String, Int32) {
  let buf = StringBuilder()
  let mut w = 0
  for ch in s {
    let (disp, cw) = sanitize_char_at(ch, w, is_eaw)
    buf.write_string(disp)
    w += cw
  }
  (buf.to_string(), w)
}

///|
fn slice_by_display_cols(
  line : String,
  col_offset : Int32,
  max_cols : Int32,
  is_eaw : Bool,
) -> String {
  let buf = StringBuilder()
  let mut x = 0
  let mut out_w = 0
  for ch in line {
    let (disp, w) = sanitize_char_at(ch, x, is_eaw)
    if x + w <= col_offset {
      x += w
      continue
    }
    if x < col_offset && x + w > col_offset {
      // Wide char partially clipped at left edge: emit space padding
      let pad = x + w - col_offset
      for p = 0; p < pad && out_w < max_cols; p = p + 1 {
        buf.write_char(' ')
        out_w += 1
      }
      x += w
      continue
    }
    if out_w + w > max_cols {
      break
    }
    buf.write_string(disp)
    x += w
    out_w += w
  }
  buf.to_string()
}

///|
fn truncate_by_display_cols(
  s : String,
  max_cols : Int32,
  is_eaw : Bool,
) -> String {
  slice_by_display_cols(s, 0, max_cols, is_eaw)
}

///|
fn Editor::current_char_badge(self : Editor) -> String {
  let chars = self.line_chars(self.cursor_y)
  if self.cursor_x >= chars.length() {
    return "<EOL>"
  }
  let ch = chars[self.cursor_x]
  let vx = self.cursor_visual_x()
  let (_, w) = sanitize_char_at(ch, vx, self.is_eaw)
  let cp = format_codepoint(ch)
  "\{cp} (\{w}c)"
}

///|
fn render_line_with_selection(
  line : String,
  col_offset : Int32,
  max_cols : Int32,
  is_eaw : Bool,
  sel_start_col : Int32?,
  sel_end_col : Int32?,
  sel_newline : Bool,
) -> String {
  let buf = StringBuilder()
  let mut x = 0
  let mut out_w = 0
  let mut idx = 0
  let mut in_sel = false
  for ch in line {
    let selected = match (sel_start_col, sel_end_col) {
      (Some(s), Some(e)) => idx >= s && idx < e
      _ => false
    }
    let (disp, w) = sanitize_char_at(ch, x, is_eaw)
    if x + w <= col_offset {
      x += w
      idx += 1
      continue
    }
    if x < col_offset && x + w > col_offset {
      if in_sel {
        buf.write_string("\u{1B}[0m")
        in_sel = false
      }
      let pad = x + w - col_offset
      for p = 0; p < pad && out_w < max_cols; p = p + 1 {
        buf.write_char(' ')
        out_w += 1
      }
      x += w
      idx += 1
      continue
    }
    if out_w + w > max_cols {
      break
    }
    if selected && !in_sel {
      buf.write_string("\u{1B}[44;97m")
      in_sel = true
    } else if !selected && in_sel {
      buf.write_string("\u{1B}[0m")
      in_sel = false
    }
    buf.write_string(disp)
    x += w
    out_w += w
    idx += 1
  }
  if in_sel {
    buf.write_string("\u{1B}[0m")
  }
  if sel_newline && x >= col_offset && out_w < max_cols {
    buf.write_string("\u{1B}[44;97m \u{1B}[0m")
  }
  buf.to_string()
}

///|
/// Render the complete editor frame as an ANSI escape sequence string.
pub fn Editor::render(self : Editor) -> String {
  let buf = StringBuilder()
  let gw = self.gutter_width()
  let num_w = gw - 1
  let text_rows = self.text_rows()
  let text_cols = self.text_cols()
  let sel = self.selection_range()
  buf.write_string("\u{1B}[?2026h\u{1B}[?25l\u{1B}[H")
  for row = 0; row < text_rows; row = row + 1 {
    let file_row = self.row_offset + row
    if file_row < self.lines.length() {
      let line_num = pad_left((file_row + 1).to_string(), num_w, ' ')
      buf.write_string("\u{1B}[90m")
      buf.write_string(line_num)
      buf.write_string(" \u{1B}[0m")
      let (sc, ec, snl) : (Int32?, Int32?, Bool) = match sel {
        None => (None, None, false)
        Some((s, e)) =>
          if file_row < s.line || file_row > e.line {
            (None, None, false)
          } else if s.line == e.line {
            (Some(s.col), Some(e.col), false)
          } else if file_row == s.line {
            (Some(s.col), Some(self.line_chars(file_row).length()), true)
          } else if file_row == e.line {
            (Some(0), Some(e.col), false)
          } else {
            (Some(0), Some(self.line_chars(file_row).length()), true)
          }
      }
      let visible = render_line_with_selection(
        self.lines[file_row],
        self.col_offset,
        text_cols,
        self.is_eaw,
        sc,
        ec,
        snl,
      )
      buf.write_string(visible)
    } else {
      let tilde_pad = pad_left("~", num_w, ' ')
      buf.write_string("\u{1B}[90m")
      buf.write_string(tilde_pad)
      buf.write_string(" \u{1B}[0m")
    }
    buf.write_string("\u{1B}[K\r\n")
  }
  // Status bar (row: rows - 1)
  let mod_flag = if self.is_modified { " [+]" } else { "" }
  let eaw_flag = if self.is_eaw { "EAW:2" } else { "EAW:1" }
  let sel_len = self.selected_text().iter().count()
  let sel_badge = if sel_len > 0 { " | Sel:\{sel_len}c" } else { "" }
  let status_cols = if self.cols > 1 { self.cols - 1 } else { 1 }
  let left_status = " inzm (MoonBit) - \{self.filename}\{mod_flag} "
  let right_status = " Ln \{self.cursor_y + 1}, Col \{self.cursor_x + 1}\{sel_badge} | \{self.current_char_badge()} | \{eaw_flag} "
  let (safe_left, lw) = sanitize_and_measure(left_status, self.is_eaw)
  let (safe_right, rw) = sanitize_and_measure(right_status, self.is_eaw)
  buf.write_string("\u{1B}[7m")
  if lw + rw <= status_cols {
    buf.write_string(safe_left)
    for i = 0; i < status_cols - lw - rw; i = i + 1 {
      buf.write_char(' ')
    }
    buf.write_string(safe_right)
  } else {
    let combined = truncate_by_display_cols(
      left_status + right_status,
      status_cols,
      self.is_eaw,
    )
    buf.write_string(combined)
    let cw = string_width(combined, self.is_eaw)
    for i = 0; i < status_cols - cw; i = i + 1 {
      buf.write_char(' ')
    }
  }
  buf.write_string("\u{1B}[0m\u{1B}[K\r\n")
  // Help / message line (row: rows)
  let safe_msg_cols = if self.cols > 1 { self.cols - 1 } else { 1 }
  let msg = truncate_by_display_cols(
    self.status_message,
    safe_msg_cols,
    self.is_eaw,
  )
  buf.write_string("\u{1B}[36m")
  buf.write_string(msg)
  buf.write_string("\u{1B}[0m\u{1B}[K")
  // Position cursor only when it is inside the visible viewport
  let vx = self.cursor_visual_x()
  if self.cursor_y >= self.row_offset &&
    self.cursor_y < self.row_offset + text_rows &&
    vx >= self.col_offset &&
    vx < self.col_offset + text_cols {
    let screen_y = self.cursor_y - self.row_offset + 1
    let screen_x = gw + (vx - self.col_offset) + 1
    buf.write_string("\u{1B}[\{screen_y};\{screen_x}H\u{1B}[?25h")
  }
  buf.write_string("\u{1B}[?2026l")
  buf.to_string()
}
