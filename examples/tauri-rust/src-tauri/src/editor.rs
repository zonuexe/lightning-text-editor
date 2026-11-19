//! Pure-Rust event-driven multi-buffer editor core outputting ANSI VT sequences for xterm.js.

use std::fmt::Write as _;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::highlight::{tokenize_line, Language, TokenKind};
use crate::input::{InputDecoder, InputEvent, MouseKind};

const MAX_UNDO: usize = 500;
const TAB_WIDTH: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pos {
    pub row: usize,
    pub col: usize, // grapheme index in line
}

#[derive(Debug, Clone)]
struct UndoEntry {
    lines: Vec<String>,
    cursor: Pos,
    anchor: Option<Pos>,
}

#[derive(Debug, Clone)]
pub struct Buffer {
    pub id: usize,
    pub path: Option<String>,
    pub title: String,
    pub lines: Vec<String>,
    pub cursor: Pos,
    pub anchor: Option<Pos>,
    pub row_offset: usize,
    pub col_offset: usize,
    pub preferred_x: usize,
    pub dirty: bool,
    undo_stack: Vec<UndoEntry>,
    redo_stack: Vec<UndoEntry>,
}

impl Buffer {
    pub fn new(id: usize, title: impl Into<String>, path: Option<String>, content: &str) -> Self {
        let lines = split_lines_preserving_empty(content);
        Self {
            id,
            path,
            title: title.into(),
            lines,
            cursor: Pos { row: 0, col: 0 },
            anchor: None,
            row_offset: 0,
            col_offset: 0,
            preferred_x: 0,
            dirty: false,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    pub fn display_name(&self) -> &str {
        if let Some(p) = &self.path {
            std::path::Path::new(p)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(&self.title)
        } else {
            &self.title
        }
    }

    pub fn language(&self) -> Language {
        Language::from_path(self.path.as_deref().or(Some(&self.title)))
    }

    pub fn full_text(&self) -> String {
        self.lines.join("\n")
    }

    pub fn selection_range(&self) -> Option<(Pos, Pos)> {
        let a = self.anchor?;
        if a == self.cursor {
            None
        } else if a < self.cursor {
            Some((a, self.cursor))
        } else {
            Some((self.cursor, a))
        }
    }

    pub fn selected_text(&self) -> String {
        let Some((start, end)) = self.selection_range() else {
            return String::new();
        };
        if start.row == end.row {
            let gs = graphemes(&self.lines[start.row]);
            let s = start.col.min(gs.len());
            let e = end.col.min(gs.len());
            return gs[s..e].concat();
        }
        let mut out = String::new();
        let first = graphemes(&self.lines[start.row]);
        out.push_str(&first[start.col.min(first.len())..].concat());
        for r in (start.row + 1)..end.row {
            out.push('\n');
            out.push_str(&self.lines[r]);
        }
        out.push('\n');
        let last = graphemes(&self.lines[end.row]);
        out.push_str(&last[..end.col.min(last.len())].concat());
        out
    }

    fn push_undo(&mut self) {
        self.undo_stack.push(UndoEntry {
            lines: self.lines.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
        });
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    pub fn undo(&mut self) -> bool {
        let Some(entry) = self.undo_stack.pop() else {
            return false;
        };
        self.redo_stack.push(UndoEntry {
            lines: self.lines.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
        });
        self.lines = entry.lines;
        self.cursor = entry.cursor;
        self.anchor = entry.anchor;
        self.dirty = true;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(entry) = self.redo_stack.pop() else {
            return false;
        };
        self.undo_stack.push(UndoEntry {
            lines: self.lines.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
        });
        self.lines = entry.lines;
        self.cursor = entry.cursor;
        self.anchor = entry.anchor;
        self.dirty = true;
        true
    }

    fn line_len(&self, row: usize) -> usize {
        graphemes(&self.lines[row]).len()
    }

    fn delete_selection_internal(&mut self) -> bool {
        let Some((start, end)) = self.selection_range() else {
            return false;
        };
        self.push_undo();
        self.remove_range(start, end);
        self.cursor = start;
        self.anchor = None;
        self.dirty = true;
        true
    }

    fn remove_range(&mut self, start: Pos, end: Pos) {
        if start.row == end.row {
            let gs = graphemes(&self.lines[start.row]);
            let s = start.col.min(gs.len());
            let e = end.col.min(gs.len());
            let mut next = String::new();
            for g in &gs[..s] {
                next.push_str(g);
            }
            for g in &gs[e..] {
                next.push_str(g);
            }
            self.lines[start.row] = next;
        } else {
            let prefix = graphemes(&self.lines[start.row]);
            let suffix = graphemes(&self.lines[end.row]);
            let mut merged = String::new();
            for g in &prefix[..start.col.min(prefix.len())] {
                merged.push_str(g);
            }
            for g in &suffix[end.col.min(suffix.len())..] {
                merged.push_str(g);
            }
            self.lines.drain(start.row..=end.row);
            self.lines.insert(start.row, merged);
        }
    }

    fn insert_text_at_cursor(&mut self, text: &str) {
        self.push_undo();
        if let Some((start, end)) = self.selection_range() {
            self.remove_range(start, end);
            self.cursor = start;
            self.anchor = None;
        }

        let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
        let chunks: Vec<&str> = normalized.split('\n').collect();
        let row = self.cursor.row;
        let gs = graphemes(&self.lines[row]);
        let col = self.cursor.col.min(gs.len());
        let before: String = gs[..col].concat();
        let after: String = gs[col..].concat();

        if chunks.len() == 1 {
            let inserted_gs = graphemes(chunks[0]).len();
            self.lines[row] = format!("{before}{}{after}", chunks[0]);
            self.cursor = Pos {
                row,
                col: col + inserted_gs,
            };
        } else {
            self.lines[row] = format!("{before}{}", chunks[0]);
            for (idx, mid) in chunks[1..chunks.len() - 1].iter().enumerate() {
                self.lines.insert(row + 1 + idx, (*mid).to_string());
            }
            let last_chunk = chunks[chunks.len() - 1];
            let last_col = graphemes(last_chunk).len();
            let last_row = row + chunks.len() - 1;
            self.lines.insert(last_row, format!("{last_chunk}{after}"));
            self.cursor = Pos {
                row: last_row,
                col: last_col,
            };
        }
        self.anchor = None;
        self.dirty = true;
    }

    fn insert_newline(&mut self) {
        self.push_undo();
        if let Some((start, end)) = self.selection_range() {
            self.remove_range(start, end);
            self.cursor = start;
            self.anchor = None;
        }
        let row = self.cursor.row;
        let gs = graphemes(&self.lines[row]);
        let col = self.cursor.col.min(gs.len());
        let left: String = gs[..col].concat();
        let right: String = gs[col..].concat();
        // Auto-indent matching leading whitespace up to cursor
        let indent: String = left
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect();
        let indent_cols = graphemes(&indent).len();
        self.lines[row] = left;
        self.lines.insert(row + 1, format!("{indent}{right}"));
        self.cursor = Pos {
            row: row + 1,
            col: indent_cols,
        };
        self.dirty = true;
    }

    fn backspace(&mut self) {
        if self.delete_selection_internal() {
            return;
        }
        if self.cursor.col > 0 {
            self.push_undo();
            let row = self.cursor.row;
            let gs = graphemes(&self.lines[row]);
            let col = self.cursor.col.min(gs.len());
            let mut next = String::new();
            for g in &gs[..col - 1] {
                next.push_str(g);
            }
            for g in &gs[col..] {
                next.push_str(g);
            }
            self.lines[row] = next;
            self.cursor.col = col - 1;
            self.dirty = true;
        } else if self.cursor.row > 0 {
            self.push_undo();
            let row = self.cursor.row;
            let prev_len = self.line_len(row - 1);
            let cur_line = self.lines.remove(row);
            self.lines[row - 1].push_str(&cur_line);
            self.cursor = Pos {
                row: row - 1,
                col: prev_len,
            };
            self.dirty = true;
        }
    }

    fn delete_forward(&mut self) {
        if self.delete_selection_internal() {
            return;
        }
        let row = self.cursor.row;
        let len = self.line_len(row);
        let col = self.cursor.col.min(len);
        if col < len {
            self.push_undo();
            let gs = graphemes(&self.lines[row]);
            let mut next = String::new();
            for g in &gs[..col] {
                next.push_str(g);
            }
            for g in &gs[col + 1..] {
                next.push_str(g);
            }
            self.lines[row] = next;
            self.dirty = true;
        } else if row + 1 < self.lines.len() {
            self.push_undo();
            let next_line = self.lines.remove(row + 1);
            self.lines[row].push_str(&next_line);
            self.dirty = true;
        }
    }

    fn delete_word_backward(&mut self) {
        if self.delete_selection_internal() {
            return;
        }
        let end = self.cursor;
        self.move_word_left(false);
        let start = self.cursor;
        if start < end {
            self.push_undo();
            self.remove_range(start, end);
            self.cursor = start;
            self.dirty = true;
        }
    }

    fn delete_word_forward(&mut self) {
        if self.delete_selection_internal() {
            return;
        }
        let start = self.cursor;
        self.move_word_right(false);
        let end = self.cursor;
        if start < end {
            self.push_undo();
            self.remove_range(start, end);
            self.cursor = start;
            self.dirty = true;
        }
    }

    fn delete_to_line_start(&mut self) {
        if self.delete_selection_internal() {
            return;
        }
        if self.cursor.col == 0 {
            return;
        }
        let end = self.cursor;
        let start = Pos {
            row: self.cursor.row,
            col: 0,
        };
        self.push_undo();
        self.remove_range(start, end);
        self.cursor = start;
        self.dirty = true;
    }

    fn update_selection_anchor(&mut self, extend: bool, prev: Pos) {
        if extend {
            if self.anchor.is_none() {
                self.anchor = Some(prev);
            }
        } else {
            self.anchor = None;
        }
    }

    fn move_left(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        if !extend {
            if let Some((start, _)) = self.selection_range() {
                self.cursor = start;
                self.anchor = None;
                self.sync_preferred_x(eaw_wide);
                return;
            }
        }
        if self.cursor.col > 0 {
            self.cursor.col -= 1;
        } else if self.cursor.row > 0 {
            self.cursor.row -= 1;
            self.cursor.col = self.line_len(self.cursor.row);
        }
        self.update_selection_anchor(extend, prev);
        self.sync_preferred_x(eaw_wide);
    }

    fn move_right(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        if !extend {
            if let Some((_, end)) = self.selection_range() {
                self.cursor = end;
                self.anchor = None;
                self.sync_preferred_x(eaw_wide);
                return;
            }
        }
        let len = self.line_len(self.cursor.row);
        if self.cursor.col < len {
            self.cursor.col += 1;
        } else if self.cursor.row + 1 < self.lines.len() {
            self.cursor.row += 1;
            self.cursor.col = 0;
        }
        self.update_selection_anchor(extend, prev);
        self.sync_preferred_x(eaw_wide);
    }

    fn move_up(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        if self.cursor.row > 0 {
            self.cursor.row -= 1;
            self.cursor.col = display_x_to_col(&self.lines[self.cursor.row], self.preferred_x, eaw_wide);
        } else {
            self.cursor.col = 0;
        }
        self.update_selection_anchor(extend, prev);
    }

    fn move_down(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        if self.cursor.row + 1 < self.lines.len() {
            self.cursor.row += 1;
            self.cursor.col = display_x_to_col(&self.lines[self.cursor.row], self.preferred_x, eaw_wide);
        } else {
            self.cursor.col = self.line_len(self.cursor.row);
        }
        self.update_selection_anchor(extend, prev);
    }

    fn move_home(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        self.cursor.col = 0;
        self.update_selection_anchor(extend, prev);
        self.sync_preferred_x(eaw_wide);
    }

    fn move_end(&mut self, extend: bool, eaw_wide: bool) {
        let prev = self.cursor;
        self.cursor.col = self.line_len(self.cursor.row);
        self.update_selection_anchor(extend, prev);
        self.sync_preferred_x(eaw_wide);
    }

    fn move_word_left(&mut self, extend: bool) {
        let prev = self.cursor;
        if self.cursor.col == 0 {
            if self.cursor.row > 0 {
                self.cursor.row -= 1;
                self.cursor.col = self.line_len(self.cursor.row);
            }
            self.update_selection_anchor(extend, prev);
            return;
        }
        let gs = graphemes(&self.lines[self.cursor.row]);
        let mut c = self.cursor.col.min(gs.len());
        while c > 0 && is_ws_grapheme(gs[c - 1]) {
            c -= 1;
        }
        if c > 0 {
            let word = is_word_grapheme(gs[c - 1]);
            while c > 0 && !is_ws_grapheme(gs[c - 1]) && is_word_grapheme(gs[c - 1]) == word {
                c -= 1;
            }
        }
        self.cursor.col = c;
        self.update_selection_anchor(extend, prev);
    }

    fn move_word_right(&mut self, extend: bool) {
        let prev = self.cursor;
        let gs = graphemes(&self.lines[self.cursor.row]);
        let len = gs.len();
        if self.cursor.col >= len {
            if self.cursor.row + 1 < self.lines.len() {
                self.cursor.row += 1;
                self.cursor.col = 0;
            }
            self.update_selection_anchor(extend, prev);
            return;
        }
        let mut c = self.cursor.col;
        while c < len && is_ws_grapheme(gs[c]) {
            c += 1;
        }
        if c < len {
            let word = is_word_grapheme(gs[c]);
            while c < len && !is_ws_grapheme(gs[c]) && is_word_grapheme(gs[c]) == word {
                c += 1;
            }
        }
        self.cursor.col = c;
        self.update_selection_anchor(extend, prev);
    }

    fn sync_preferred_x(&mut self, eaw_wide: bool) {
        self.preferred_x = col_to_display_x(&self.lines[self.cursor.row], self.cursor.col, eaw_wide);
    }

    fn select_all(&mut self) {
        let last_row = self.lines.len() - 1;
        let last_col = self.line_len(last_row);
        self.anchor = Some(Pos { row: 0, col: 0 });
        self.cursor = Pos {
            row: last_row,
            col: last_col,
        };
    }

    fn find_matches(&self, query: &str) -> Vec<(Pos, Pos)> {
        if query.is_empty() {
            return Vec::new();
        }
        let q_lower = query.to_lowercase();
        let q_graphemes = graphemes(&q_lower).len();
        if q_graphemes == 0 {
            return Vec::new();
        }
        let mut matches = Vec::new();
        for (row, line) in self.lines.iter().enumerate() {
            let line_gs: Vec<String> = graphemes(line).into_iter().map(|g| g.to_lowercase()).collect();
            if line_gs.len() < q_graphemes {
                continue;
            }
            let mut c = 0;
            while c + q_graphemes <= line_gs.len() {
                if line_gs[c..c + q_graphemes].concat() == q_lower {
                    matches.push((Pos { row, col: c }, Pos { row, col: c + q_graphemes }));
                    c += q_graphemes;
                } else {
                    c += 1;
                }
            }
        }
        matches
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Normal,
    Find { query: String, match_index: usize },
}

#[derive(Debug, Clone)]
struct TabHitSpan {
    start_col: usize,
    end_col: usize, // exclusive
    action: TabClickAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TabClickAction {
    Switch(usize),
    NewTab,
}

pub struct Editor {
    pub buffers: Vec<Buffer>,
    pub active_idx: usize,
    pub next_buf_id: usize,
    pub cols: usize,
    pub rows: usize,
    pub eaw_wide: bool,
    pub status_msg: String,
    pub mode: Mode,
    decoder: InputDecoder,
    dragging: bool,
    tab_spans: Vec<TabHitSpan>,
    gutter_width: usize,
    needs_scroll_to_cursor: bool,
}

impl Editor {
    pub fn new(cols: usize, rows: usize) -> Self {
        let welcome = concat!(
            "// Welcome to inzm (Rust + Tauri v2 + xterm.js)\n",
            "// ⌘N/⌘T New Tab | ⌘O Open | ⌘S Save | ⌘W Close Tab | ⌘F Find\n",
            "// ⌘Z / ⇧⌘Z Undo/Redo | ⇧+Arrow or Mouse Drag: Range Select\n",
            "\n",
            "fn main() {\n",
            "    let greeting = \"こんにちは、テキストエディタ！🎉\";\n",
            "    println!(\"{}\", greeting);\n",
            "}\n",
        );
        let mut first = Buffer::new(1, "welcome.rs", None, welcome);
        first.cursor = Pos { row: 5, col: 4 };
        first.preferred_x = col_to_display_x(&first.lines[5], 4, false);
        Self {
            buffers: vec![first],
            active_idx: 0,
            next_buf_id: 2,
            cols: cols.max(20),
            rows: rows.max(6),
            eaw_wide: false,
            status_msg: "Ready — Ctrl+T: toggle EAW | Drop any file to open".to_string(),
            mode: Mode::Normal,
            decoder: InputDecoder::new(),
            dragging: false,
            tab_spans: Vec::new(),
            gutter_width: 6,
            needs_scroll_to_cursor: true,
        }
    }

    pub fn active(&self) -> &Buffer {
        &self.buffers[self.active_idx]
    }

    pub fn active_mut(&mut self) -> &mut Buffer {
        &mut self.buffers[self.active_idx]
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.cols = cols.max(20);
        self.rows = rows.max(6);
        self.needs_scroll_to_cursor = true;
    }

    pub fn init_sequence(&self) -> String {
        // Alternate screen, SGR mouse drag + wheel (?1002h + ?1006h), bracketed paste (?2004h)
        "\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[?2004h".to_string()
    }

    pub fn feed_bytes(&mut self, bytes: &[u8]) {
        let events = self.decoder.feed(bytes);
        for ev in events {
            self.handle_event(ev);
        }
    }

    pub fn new_tab(&mut self) {
        let id = self.next_buf_id;
        self.next_buf_id += 1;
        let buf = Buffer::new(id, format!("untitled-{id}"), None, "");
        self.buffers.push(buf);
        self.active_idx = self.buffers.len() - 1;
        self.mode = Mode::Normal;
        self.status_msg = format!("New tab #{}", id);
        self.needs_scroll_to_cursor = true;
    }

    pub fn open_or_focus_file(&mut self, path: String, content: String) {
        if let Some(idx) = self.buffers.iter().position(|b| b.path.as_deref() == Some(path.as_str())) {
            self.active_idx = idx;
            self.status_msg = format!("Focused: {}", path);
            self.needs_scroll_to_cursor = true;
            return;
        }
        // Replace untouched initial untitled empty buffer if only 1 buffer & clean & no path & empty
        if self.buffers.len() == 1
            && self.buffers[0].path.is_none()
            && !self.buffers[0].dirty
            && self.buffers[0].lines == [""]
        {
            let id = self.buffers[0].id;
            let name = file_basename(&path);
            self.buffers[0] = Buffer::new(id, name, Some(path.clone()), &content);
        } else {
            let id = self.next_buf_id;
            self.next_buf_id += 1;
            let name = file_basename(&path);
            self.buffers.push(Buffer::new(id, name, Some(path.clone()), &content));
            self.active_idx = self.buffers.len() - 1;
        }
        self.mode = Mode::Normal;
        self.status_msg = format!("Opened {}", file_basename(&path));
        self.needs_scroll_to_cursor = true;
    }

    pub fn mark_saved(&mut self, path: String) {
        let name = file_basename(&path);
        let buf = self.active_mut();
        buf.path = Some(path.clone());
        buf.title = name.clone();
        buf.dirty = false;
        self.status_msg = format!("Saved {name}");
    }

    pub fn switch_tab(&mut self, idx: usize) {
        if idx < self.buffers.len() {
            self.active_idx = idx;
            self.mode = Mode::Normal;
            self.status_msg = format!("Switched to {}", self.active().display_name());
        }
    }

    pub fn cycle_tab(&mut self, delta: isize) {
        if self.buffers.is_empty() {
            return;
        }
        let len = self.buffers.len() as isize;
        let next = (self.active_idx as isize + delta).rem_euclid(len) as usize;
        self.switch_tab(next);
    }

    pub fn close_active_tab(&mut self) -> bool {
        if self.buffers.len() == 1 {
            let id = self.next_buf_id;
            self.next_buf_id += 1;
            self.buffers[0] = Buffer::new(id, format!("untitled-{id}"), None, "");
            self.status_msg = "Cleared last buffer".to_string();
            return true;
        }
        self.buffers.remove(self.active_idx);
        if self.active_idx >= self.buffers.len() {
            self.active_idx = self.buffers.len() - 1;
        }
        self.mode = Mode::Normal;
        self.status_msg = format!("Closed tab — {}", self.active().display_name());
        true
    }

    pub fn any_dirty(&self) -> bool {
        self.buffers.iter().any(|b| b.dirty)
    }

    pub fn start_find(&mut self) {
        self.mode = Mode::Find {
            query: String::new(),
            match_index: 0,
        };
        self.status_msg = "Find mode: type query, Enter=next, Esc=done".to_string();
    }

    pub fn select_all(&mut self) {
        self.active_mut().select_all();
        self.needs_scroll_to_cursor = true;
    }

    pub fn undo(&mut self) {
        if self.active_mut().undo() {
            self.status_msg = "Undo".to_string();
        } else {
            self.status_msg = "Nothing to undo".to_string();
        }
        self.needs_scroll_to_cursor = true;
    }

    pub fn redo(&mut self) {
        if self.active_mut().redo() {
            self.status_msg = "Redo".to_string();
        } else {
            self.status_msg = "Nothing to redo".to_string();
        }
        self.needs_scroll_to_cursor = true;
    }

    pub fn cut_selection(&mut self) -> String {
        let selected = self.active().selected_text();
        if !selected.is_empty() {
            self.active_mut().delete_selection_internal();
            self.status_msg = format!("Cut {} chars", selected.chars().count());
            self.needs_scroll_to_cursor = true;
        }
        selected
    }

    pub fn toggle_eaw(&mut self) {
        self.eaw_wide = !self.eaw_wide;
        self.status_msg = if self.eaw_wide {
            "East Asian Width: WIDE (2 cols)".to_string()
        } else {
            "East Asian Width: NARROW (1 col)".to_string()
        };
    }

    pub fn window_title(&self) -> String {
        let buf = self.active();
        let dirty = if buf.dirty { "● " } else { "" };
        format!("{}{} — inzm (Rust + Tauri)", dirty, buf.display_name())
    }

    fn text_rows(&self) -> usize {
        self.rows.saturating_sub(3).max(1)
    }

    fn handle_event(&mut self, ev: InputEvent) {
        // Mouse events work identically in both Normal and Find mode
        if let InputEvent::Mouse(m) = ev {
            self.handle_mouse(m);
            return;
        }

        if matches!(self.mode, Mode::Find { .. }) {
            self.handle_find_event(ev);
            return;
        }

        let eaw = self.eaw_wide;
        match ev {
            InputEvent::Text(s) | InputEvent::Paste(s) => {
                self.active_mut().insert_text_at_cursor(&s);
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Enter => {
                self.active_mut().insert_newline();
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Backspace => {
                self.active_mut().backspace();
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Delete => {
                self.active_mut().delete_forward();
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::AltBackspace => {
                self.active_mut().delete_word_backward();
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::AltDelete => {
                self.active_mut().delete_word_forward();
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Tab => {
                self.active_mut().insert_text_at_cursor("    ");
                self.active_mut().sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::BackTab => {
                self.cycle_tab(-1);
            }
            InputEvent::Escape => {
                if self.active().anchor.is_some() {
                    self.active_mut().anchor = None;
                }
            }
            InputEvent::Left(mods) => {
                if mods.alt {
                    self.active_mut().move_word_left(mods.shift);
                    self.active_mut().sync_preferred_x(eaw);
                } else {
                    self.active_mut().move_left(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Right(mods) => {
                if mods.alt {
                    self.active_mut().move_word_right(mods.shift);
                    self.active_mut().sync_preferred_x(eaw);
                } else {
                    self.active_mut().move_right(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Up(mods) => {
                if mods.alt {
                    // Cmd+Up mapped to alt/meta in some paths: doc top
                    let prev = self.active().cursor;
                    let buf = self.active_mut();
                    buf.cursor = Pos { row: 0, col: 0 };
                    buf.update_selection_anchor(mods.shift, prev);
                    buf.sync_preferred_x(eaw);
                } else {
                    self.active_mut().move_up(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Down(mods) => {
                if mods.alt {
                    let prev = self.active().cursor;
                    let buf = self.active_mut();
                    let last = buf.lines.len() - 1;
                    let len = buf.line_len(last);
                    buf.cursor = Pos { row: last, col: len };
                    buf.update_selection_anchor(mods.shift, prev);
                    buf.sync_preferred_x(eaw);
                } else {
                    self.active_mut().move_down(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Home(mods) => {
                self.active_mut().move_home(mods.shift, eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::End(mods) => {
                self.active_mut().move_end(mods.shift, eaw);
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::PageUp(mods) => {
                let step = self.text_rows().saturating_sub(1).max(1);
                for _ in 0..step {
                    self.active_mut().move_up(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::PageDown(mods) => {
                let step = self.text_rows().saturating_sub(1).max(1);
                for _ in 0..step {
                    self.active_mut().move_down(mods.shift, eaw);
                }
                self.needs_scroll_to_cursor = true;
            }
            InputEvent::Ctrl(ch) => match ch {
                'a' => self.select_all(),
                'f' => self.start_find(),
                'z' => self.undo(),
                'y' => self.redo(),
                'u' => {
                    self.active_mut().delete_to_line_start();
                    self.active_mut().sync_preferred_x(eaw);
                    self.needs_scroll_to_cursor = true;
                }
                't' => self.toggle_eaw(),
                'n' => self.cycle_tab(1),
                'p' => self.cycle_tab(-1),
                _ => {}
            },
            InputEvent::Mouse(_) => {}
        }
    }

    fn handle_find_event(&mut self, ev: InputEvent) {
        let Mode::Find {
            mut query,
            mut match_index,
        } = std::mem::replace(&mut self.mode, Mode::Normal)
        else {
            return;
        };

        let mut stay_in_find = true;
        let mut jump_to_match = false;
        match ev {
            InputEvent::Escape => {
                stay_in_find = false;
                self.status_msg = "Search closed".to_string();
            }
            InputEvent::Text(s) | InputEvent::Paste(s) => {
                query.push_str(&s);
                match_index = 0;
                jump_to_match = true;
            }
            InputEvent::Backspace => {
                let mut gs: Vec<String> = graphemes(&query).into_iter().map(str::to_string).collect();
                gs.pop();
                query = gs.concat();
                match_index = 0;
                jump_to_match = true;
            }
            InputEvent::Enter | InputEvent::Down(_) | InputEvent::Ctrl('n') => {
                let count = self.active().find_matches(&query).len();
                if count > 0 {
                    match_index = (match_index + 1) % count;
                    jump_to_match = true;
                }
            }
            InputEvent::Up(_) | InputEvent::BackTab | InputEvent::Ctrl('p') => {
                let count = self.active().find_matches(&query).len();
                if count > 0 {
                    match_index = if match_index == 0 {
                        count - 1
                    } else {
                        match_index - 1
                    };
                    jump_to_match = true;
                }
            }
            _ => {}
        }

        if stay_in_find {
            let matches = self.active().find_matches(&query);
            if matches.is_empty() {
                self.mode = Mode::Find {
                    query,
                    match_index: 0,
                };
            } else {
                let idx = match_index.min(matches.len() - 1);
                if jump_to_match {
                    let (start, end) = matches[idx];
                    let eaw = self.eaw_wide;
                    let buf = self.active_mut();
                    buf.anchor = Some(start);
                    buf.cursor = end;
                    buf.sync_preferred_x(eaw);
                    self.needs_scroll_to_cursor = true;
                }
                self.mode = Mode::Find {
                    query,
                    match_index: idx,
                };
            }
        }
    }

    fn handle_mouse(&mut self, m: crate::input::MouseEvent) {
        match m.kind {
            MouseKind::WheelUp => {
                let buf = self.active_mut();
                buf.row_offset = buf.row_offset.saturating_sub(3);
                // Viewport-only scroll: intentionally do NOT snap back to cursor!
                self.needs_scroll_to_cursor = false;
            }
            MouseKind::WheelDown => {
                let buf = self.active_mut();
                let max_off = buf.lines.len().saturating_sub(1);
                buf.row_offset = (buf.row_offset + 3).min(max_off);
                self.needs_scroll_to_cursor = false;
            }
            MouseKind::Down => {
                if m.row == 0 {
                    if let Some(span) = self
                        .tab_spans
                        .iter()
                        .find(|s| m.col >= s.start_col && m.col < s.end_col)
                        .cloned()
                    {
                        match span.action {
                            TabClickAction::Switch(idx) => self.switch_tab(idx),
                            TabClickAction::NewTab => self.new_tab(),
                        }
                    }
                    return;
                }
                if m.button != 0 {
                    return;
                }
                let text_rows = self.text_rows();
                if m.row >= 1 && m.row < 1 + text_rows {
                    let pos = self.screen_to_buffer_pos(m.col, m.row);
                    let eaw = self.eaw_wide;
                    let buf = self.active_mut();
                    buf.cursor = pos;
                    buf.anchor = None;
                    buf.sync_preferred_x(eaw);
                    self.dragging = true;
                    self.needs_scroll_to_cursor = false;
                }
            }
            MouseKind::Drag => {
                if !self.dragging {
                    return;
                }
                let text_rows = self.text_rows();
                let clamped_row = m.row.clamp(1, text_rows);
                let pos = self.screen_to_buffer_pos(m.col, clamped_row);
                let eaw = self.eaw_wide;
                let buf = self.active_mut();
                if buf.anchor.is_none() {
                    buf.anchor = Some(buf.cursor);
                }
                buf.cursor = pos;
                buf.sync_preferred_x(eaw);
                self.needs_scroll_to_cursor = false;
            }
            MouseKind::Up => {
                self.dragging = false;
            }
        }
    }

    fn screen_to_buffer_pos(&self, screen_col: usize, screen_row: usize) -> Pos {
        let buf = self.active();
        let rel_row = screen_row.saturating_sub(1);
        let row = (buf.row_offset + rel_row).min(buf.lines.len() - 1);
        let rel_x = screen_col.saturating_sub(self.gutter_width) + buf.col_offset;
        let col = display_x_to_col(&buf.lines[row], rel_x, self.eaw_wide);
        Pos { row, col }
    }

    fn ensure_cursor_visible(&mut self) {
        let text_rows = self.text_rows();
        let eaw = self.eaw_wide;
        let max_line = self.active().lines.len();
        let gutter = compute_gutter_width(max_line);
        let text_cols = self.cols.saturating_sub(gutter).max(1);

        let buf = self.active_mut();
        if buf.cursor.row < buf.row_offset {
            buf.row_offset = buf.cursor.row;
        } else if buf.cursor.row >= buf.row_offset + text_rows {
            buf.row_offset = buf.cursor.row + 1 - text_rows;
        }

        let cx = col_to_display_x(&buf.lines[buf.cursor.row], buf.cursor.col, eaw);
        if cx < buf.col_offset {
            buf.col_offset = cx;
        } else if cx >= buf.col_offset + text_cols {
            buf.col_offset = cx + 1 - text_cols;
        }
    }

    pub fn render(&mut self) -> String {
        if self.needs_scroll_to_cursor {
            self.ensure_cursor_visible();
            self.needs_scroll_to_cursor = false;
        }

        let total_lines = self.active().lines.len();
        self.gutter_width = compute_gutter_width(total_lines);
        let gutter_width = self.gutter_width;
        let text_rows = self.text_rows();
        let text_cols = self.cols.saturating_sub(gutter_width).max(1);

        let mut out = String::with_capacity(self.cols * self.rows * 2);
        // Hide cursor while redrawing & reset attributes
        out.push_str("\x1b[?25l\x1b[0m\x1b[H");

        // 1. Row 0: Tab bar
        self.render_tab_bar(&mut out);

        // Precompute search matches and selection
        let find_info = match &self.mode {
            Mode::Find { query, match_index } => {
                let ms = self.active().find_matches(query);
                Some((ms, *match_index))
            }
            Mode::Normal => None,
        };
        let buf = &self.buffers[self.active_idx];
        let lang = buf.language();
        let sel = buf.selection_range();

        // 2. Text rows (screen rows 1..=text_rows)
        for view_r in 0..text_rows {
            let file_r = buf.row_offset + view_r;
            let _ = write!(out, "\x1b[{};1H\x1b[0m", view_r + 2);
            if file_r < buf.lines.len() {
                let is_cur_line = file_r == buf.cursor.row;
                let num_color = if is_cur_line {
                    "\x1b[38;2;205;214;244m"
                } else {
                    "\x1b[38;2;108;112;134m"
                };
                let digits = gutter_width.saturating_sub(3);
                let _ = write!(
                    out,
                    "{num_color}{:>digits$} │ \x1b[0m\x1b[K",
                    file_r + 1,
                    digits = digits
                );

                render_text_line(
                    &mut out,
                    &buf.lines[file_r],
                    file_r,
                    view_r + 2,
                    gutter_width,
                    lang,
                    buf.col_offset,
                    text_cols,
                    self.eaw_wide,
                    sel,
                    find_info.as_ref().map(|(m, i)| (m.as_slice(), *i)),
                );
            } else {
                let tilde_pad = gutter_width.saturating_sub(2);
                let _ = write!(
                    out,
                    "\x1b[38;2;88;91;112m{:>tilde_pad$}~ \x1b[K\x1b[0m",
                    "",
                    tilde_pad = tilde_pad
                );
            }
        }

        // 3. Status bar
        self.render_status_bar(&mut out, find_info.as_ref().map(|(m, i)| (m.len(), *i)));

        // 4. Help bar
        self.render_help_bar(&mut out);

        // 5. Place hardware cursor only when visible inside viewport
        let buf = &self.buffers[self.active_idx];
        if buf.cursor.row >= buf.row_offset && buf.cursor.row < buf.row_offset + text_rows {
            let screen_row = buf.cursor.row - buf.row_offset + 2; // 1-based; row 1 is tab bar
            let cx = col_to_display_x(&buf.lines[buf.cursor.row], buf.cursor.col, self.eaw_wide);
            if cx >= buf.col_offset && cx < buf.col_offset + text_cols {
                let screen_col = gutter_width + (cx - buf.col_offset) + 1;
                let _ = write!(out, "\x1b[{screen_row};{screen_col}H\x1b[?25h");
            }
        }

        out
    }

    fn render_tab_bar(&mut self, out: &mut String) {
        out.push_str("\x1b[1;1H\x1b[48;2;24;24;37m");
        self.tab_spans.clear();
        let mut used = 0usize;

        for (idx, buf) in self.buffers.iter().enumerate() {
            let dirty_mark = if buf.dirty { "* " } else { "" };
            let label = format!(" {dirty_mark}{} ", buf.display_name());
            let w = str_display_width(&label, false);
            if used + w + 4 > self.cols {
                break;
            }
            if idx == self.active_idx {
                out.push_str("\x1b[48;2;49;50;68m\x1b[1;38;2;205;214;244m");
            } else {
                out.push_str("\x1b[48;2;24;24;37m\x1b[0;38;2;147;153;178m");
            }
            out.push_str(&label);
            out.push_str("\x1b[48;2;24;24;37m\x1b[38;2;69;71;90m│");
            self.tab_spans.push(TabHitSpan {
                start_col: used,
                end_col: used + w,
                action: TabClickAction::Switch(idx),
            });
            used += w + 1;
        }

        if used + 3 <= self.cols {
            out.push_str("\x1b[48;2;24;24;37m\x1b[38;2;166;227;161m + ");
            self.tab_spans.push(TabHitSpan {
                start_col: used,
                end_col: used + 3,
                action: TabClickAction::NewTab,
            });
        }
        out.push_str("\x1b[48;2;24;24;37m\x1b[K\x1b[0m");
    }

    fn render_status_bar(&self, out: &mut String, find_stats: Option<(usize, usize)>) {
        let row = self.rows.saturating_sub(1);
        let buf = self.active();
        let dirty = if buf.dirty { " [+]" } else { "" };
        let eaw = if self.eaw_wide { "EAW:W" } else { "EAW:N" };
        let sel_info = if let Some((s, e)) = buf.selection_range() {
            let lines = e.row - s.row + 1;
            let chars = buf.selected_text().chars().count();
            format!(" | Sel {chars}ch/{lines}L")
        } else {
            String::new()
        };

        let left = match &self.mode {
            Mode::Find { query, .. } => {
                let (total, cur) = find_stats.unwrap_or((0, 0));
                if total == 0 {
                    format!(" FIND: {query} (0 matches)")
                } else {
                    format!(" FIND: {query} ({}/{total})", cur + 1)
                }
            }
            Mode::Normal => {
                format!(
                    " {}{} [{}] — {}",
                    buf.display_name(),
                    dirty,
                    buf.language().label(),
                    self.status_msg
                )
            }
        };

        let right = format!(
            "Ln {}, Col {}{} | {} ",
            buf.cursor.row + 1,
            buf.cursor.col + 1,
            sel_info,
            eaw
        );

        let left_w = str_display_width(&left, false);
        let right_w = str_display_width(&right, false);
        let _ = write!(
            out,
            "\x1b[{row};1H\x1b[48;2;49;50;68m\x1b[38;2;205;214;244m"
        );
        if left_w + right_w <= self.cols {
            out.push_str(&left);
            for _ in 0..(self.cols - left_w - right_w) {
                out.push(' ');
            }
            out.push_str(&right);
        } else if self.cols > right_w + 4 {
            let max_left = self.cols - right_w - 1;
            let truncated = truncate_to_width(&left, max_left, false);
            let trunc_w = str_display_width(&truncated, false);
            out.push_str(&truncated);
            out.push('…');
            for _ in 0..(self.cols - trunc_w - 1 - right_w) {
                out.push(' ');
            }
            out.push_str(&right);
        } else {
            let truncated = truncate_to_width(&left, self.cols, false);
            out.push_str(&truncated);
            out.push_str("\x1b[K");
        }
        out.push_str("\x1b[0m");
    }

    fn render_help_bar(&self, out: &mut String) {
        let row = self.rows;
        let help = match &self.mode {
            Mode::Find { .. } => {
                " Type to search | Enter/↓ Next | ↑ Prev | Esc Close"
            }
            Mode::Normal => {
                " ⌘S Save | ⌘O Open | ⌘T NewTab | ⌘W Close | ⌘F Find | ⌘Z/⇧⌘Z Undo/Redo | ^T EAW | ^N/^P Tabs"
            }
        };
        let truncated = truncate_to_width(help, self.cols, false);
        let _ = write!(
            out,
            "\x1b[{row};1H\x1b[48;2;24;24;37m\x1b[38;2;147;153;178m{truncated}\x1b[K\x1b[0m"
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn render_text_line(
    out: &mut String,
    line: &str,
    row_idx: usize,
    screen_row: usize,
    gutter_width: usize,
    lang: Language,
    col_offset: usize,
    max_cols: usize,
    eaw_wide: bool,
    selection: Option<(Pos, Pos)>,
    find: Option<(&[(Pos, Pos)], usize)>,
) {
    let token_kinds = tokenize_line(lang, line);
    let mut x = 0usize;
    let end_x = col_offset + max_cols;
    let mut g_idx = 0usize;

    for (byte_idx, g) in line.grapheme_indices(true) {
        let w = grapheme_width(g, eaw_wide);
        if x + w <= col_offset {
            x += w;
            g_idx += 1;
            continue;
        }
        if x >= end_x {
            break;
        }

        let pos = Pos {
            row: row_idx,
            col: g_idx,
        };
        let is_selected = selection.is_some_and(|(s, e)| pos >= s && pos < e);
        let mut match_kind = 0u8; // 0 none, 1 match, 2 active match
        if let Some((matches, active)) = find {
            for (mi, (ms, me)) in matches.iter().enumerate() {
                if pos >= *ms && pos < *me {
                    match_kind = if mi == active { 2 } else { 1 };
                    break;
                }
            }
        }

        let kind = token_kinds
            .get(byte_idx)
            .copied()
            .unwrap_or(TokenKind::Normal);

        // Partially clipped wide character at left edge
        if x < col_offset && x + w > col_offset {
            let pad = (x + w).min(end_x) - col_offset;
            for _ in 0..pad {
                out.push(' ');
            }
            x += w;
            g_idx += 1;
            continue;
        }

        // Clip wide character that doesn't fit at right edge
        if x + w > end_x {
            break;
        }

        if match_kind == 2 {
            out.push_str("\x1b[48;2;249;226;175m\x1b[38;2;30;30;46m");
        } else if match_kind == 1 {
            out.push_str("\x1b[48;2;88;91;112m\x1b[38;2;249;226;175m");
        } else if is_selected {
            out.push_str("\x1b[48;2;69;71;90m");
            out.push_str(kind.fg_ansi());
        } else {
            out.push_str("\x1b[0m");
            out.push_str(kind.fg_ansi());
        }

        if g == "\t" {
            for _ in 0..TAB_WIDTH {
                out.push(' ');
            }
        } else {
            out.push_str(g);
        }

        x += w;
        g_idx += 1;

        // Re-anchor terminal cursor after non-ASCII graphemes so EAW / ZWJ width
        // matches Rust's column grid regardless of terminal Unicode table version.
        if !g.is_ascii() && x < end_x {
            let next_screen_col = gutter_width + (x - col_offset) + 1;
            let _ = write!(out, "\x1b[{screen_row};{next_screen_col}H");
        }
    }

    // Highlight trailing newline space when selection spans past line end
    if let Some((s, e)) = selection {
        if row_idx >= s.row && row_idx < e.row && x >= col_offset && x < end_x {
            out.push_str("\x1b[48;2;69;71;90m ");
            x += 1;
        }
    }

    out.push_str("\x1b[0m");
    if x < end_x {
        out.push_str("\x1b[K");
    }
}

fn compute_gutter_width(total_lines: usize) -> usize {
    let digits = total_lines.max(1).to_string().len().max(3);
    digits + 3 // "{num} │ "
}

fn split_lines_preserving_empty(text: &str) -> Vec<String> {
    let norm = text.replace("\r\n", "\n").replace('\r', "\n");
    if norm.is_empty() {
        return vec![String::new()];
    }
    norm.split('\n').map(str::to_string).collect()
}

fn file_basename(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(path)
        .to_string()
}

fn graphemes(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

pub fn grapheme_width(g: &str, eaw_wide: bool) -> usize {
    if g == "\t" {
        return TAB_WIDTH;
    }
    let w = if eaw_wide {
        g.width_cjk()
    } else {
        g.width()
    };
    w.max(1)
}

fn col_to_display_x(line: &str, col: usize, eaw_wide: bool) -> usize {
    line.graphemes(true)
        .take(col)
        .map(|g| grapheme_width(g, eaw_wide))
        .sum()
}

fn display_x_to_col(line: &str, target_x: usize, eaw_wide: bool) -> usize {
    let mut x = 0usize;
    let mut col = 0usize;
    for g in line.graphemes(true) {
        let w = grapheme_width(g, eaw_wide);
        if x + w / 2 >= target_x {
            break;
        }
        x += w;
        col += 1;
    }
    col
}

fn str_display_width(s: &str, eaw_wide: bool) -> usize {
    s.graphemes(true).map(|g| grapheme_width(g, eaw_wide)).sum()
}

fn truncate_to_width(s: &str, max_w: usize, eaw_wide: bool) -> String {
    let mut out = String::new();
    let mut w = 0usize;
    for g in s.graphemes(true) {
        let gw = grapheme_width(g, eaw_wide);
        if w + gw > max_w {
            break;
        }
        out.push_str(g);
        w += gw;
    }
    out
}

fn is_ws_grapheme(g: &str) -> bool {
    g.chars().all(char::is_whitespace)
}

fn is_word_grapheme(g: &str) -> bool {
    g.chars().any(|c| c.is_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_buffer_tab_creation_switching_and_closing() {
        let mut ed = Editor::new(80, 24);
        assert_eq!(ed.buffers.len(), 1);
        assert_eq!(ed.active_idx, 0);

        ed.new_tab();
        assert_eq!(ed.buffers.len(), 2);
        assert_eq!(ed.active_idx, 1);

        ed.feed_bytes(b"hello");
        assert_eq!(ed.active().lines[0], "hello");
        assert!(ed.active().dirty);

        ed.cycle_tab(1);
        assert_eq!(ed.active_idx, 0);

        // Render tab bar and verify click on second tab switches back
        let _ = ed.render();
        let tab2_span = ed
            .tab_spans
            .iter()
            .find(|s| s.action == TabClickAction::Switch(1))
            .expect("second tab span")
            .clone();
        // SGR mouse left down on row 1 (1-based) col tab2_span.start_col + 1
        let seq = format!("\x1b[<0;{};1M", tab2_span.start_col + 1);
        ed.feed_bytes(seq.as_bytes());
        assert_eq!(ed.active_idx, 1);

        assert!(ed.close_active_tab());
        assert_eq!(ed.buffers.len(), 1);
        assert_eq!(ed.active_idx, 0);
    }

    #[test]
    fn grapheme_selection_replace_and_undo_redo() {
        let mut ed = Editor::new(80, 24);
        ed.new_tab();
        ed.feed_bytes("あいう".as_bytes());
        assert_eq!(ed.active().cursor, Pos { row: 0, col: 3 });

        // Shift+Left twice selects "いう"
        ed.feed_bytes(b"\x1b[1;2D\x1b[1;2D");
        assert_eq!(ed.active().selected_text(), "いう");

        // Typing replaces selection
        ed.feed_bytes("えお".as_bytes());
        assert_eq!(ed.active().lines[0], "あえお");
        assert!(ed.active().selection_range().is_none());

        // Undo restores "あいう", Undo again clears "あいう"
        ed.undo();
        assert_eq!(ed.active().lines[0], "あいう");
        ed.redo();
        assert_eq!(ed.active().lines[0], "あえお");
    }

    #[test]
    fn wheel_scroll_keeps_viewport_without_snapping_back() {
        let mut ed = Editor::new(80, 10); // text_rows = 7
        ed.new_tab();
        let body: String = (0..40).map(|i| format!("line {i}\n")).collect();
        ed.open_or_focus_file("test.rs".into(), body);
        assert_eq!(ed.active().cursor.row, 0);
        assert_eq!(ed.active().row_offset, 0);

        // Scroll down 2 wheel ticks (+6 rows)
        ed.feed_bytes(b"\x1b[<65;10;5M\x1b[<65;10;5M");
        let frame = ed.render();
        assert_eq!(ed.active().row_offset, 6);
        assert_eq!(ed.active().cursor.row, 0);
        // Hardware cursor must stay hidden when cursor scrolled offscreen
        assert!(!frame.ends_with("\x1b[?25h"));
    }

    #[test]
    fn incremental_search_selects_and_cycles_matches() {
        let mut ed = Editor::new(80, 24);
        ed.open_or_focus_file("a.rs".into(), "alpha beta alpha\nsecond ALPHA line".into());
        ed.start_find();
        ed.feed_bytes(b"alpha");
        assert_eq!(ed.active().selected_text(), "alpha");
        assert_eq!(ed.active().cursor, Pos { row: 0, col: 5 });

        // Next match -> col 11..16 on row 0
        ed.feed_bytes(b"\r");
        assert_eq!(ed.active().cursor, Pos { row: 0, col: 16 });

        // Next match -> row 1 "ALPHA"
        ed.feed_bytes(b"\r");
        assert_eq!(ed.active().selected_text(), "ALPHA");
        assert_eq!(ed.active().cursor.row, 1);

        // Escape exits Find mode
        ed.feed_bytes(b"\x1b");
        assert_eq!(ed.mode, Mode::Normal);
    }

    #[test]
    fn welcome_buffer_highlights_rust_and_keeps_status_right_and_eaw_sync() {
        let mut ed = Editor::new(50, 12);
        assert_eq!(ed.active().language(), Language::Rust);

        let frame = ed.render();
        // Status bar shows [Rust] and preserves cursor/EAW readout even on 50 cols
        assert!(frame.contains("welcome.rs [Rust]"));
        assert!(frame.contains("Ln 6, Col 5 | EAW:N"));

        // EAW toggle widens ambiguous symbols and emits explicit cursor re-anchor
        ed.new_tab();
        ed.feed_bytes("★a".as_bytes());
        ed.toggle_eaw();
        let eaw_frame = ed.render();
        // Gutter is 6 cols ("  1 │ "): ★ sits at cols 7..9 so 'a' anchors at col 9
        assert!(eaw_frame.contains("★\x1b[2;9H\x1b[0ma"));
    }
}
