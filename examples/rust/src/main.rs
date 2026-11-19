use crossterm::{
    cursor,
    event::{self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyModifiers},
    execute,
    style::{Attribute, ResetColor, SetAttribute},
    terminal::{
        disable_raw_mode, enable_raw_mode, Clear, ClearType, EnterAlternateScreen,
        LeaveAlternateScreen, SetTitle,
    },
};
use std::env;
use std::fs;
use std::io::{stdin, stdout, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

#[cfg(unix)]
static TERM_REQUESTED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn handle_term_signal(_sig: i32) {
    TERM_REQUESTED.store(true, Ordering::Relaxed);
}

#[cfg(unix)]
fn install_term_handlers() {
    const SIGHUP: i32 = 1;
    const SIGTERM: i32 = 15;
    const SIG_IGN: usize = 1;
    unsafe extern "C" {
        fn signal(sig: i32, handler: usize) -> usize;
    }
    unsafe {
        let prev_hup = signal(SIGHUP, handle_term_signal as *const () as usize);
        if prev_hup == SIG_IGN {
            signal(SIGHUP, SIG_IGN);
        }
        let _ = signal(SIGTERM, handle_term_signal as *const () as usize);
    }
}

#[cfg(not(unix))]
fn install_term_handlers() {}

fn is_term_requested() -> bool {
    #[cfg(unix)]
    {
        TERM_REQUESTED.load(Ordering::Relaxed)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

fn is_control_char(ch: char) -> bool {
    let code = ch as u32;
    code < 0x20 || code == 0x7F || (0x80..0xA0).contains(&code)
}

// --- 安全なターミナル復元用 RAII ガード ---
struct CleanUp;

impl Drop for CleanUp {
    fn drop(&mut self) {
        let _ = execute!(
            stdout(),
            SetTitle(""),
            DisableBracketedPaste,
            ResetColor,
            LeaveAlternateScreen,
            cursor::Show
        );
        let _ = disable_raw_mode();
    }
}

// --- エディタ状態 ---
struct Editor {
    filename: String,
    lines: Vec<String>,
    cursor_x: usize, // 書記素クラスタ (grapheme) インデックス
    cursor_y: usize, // 行インデックス
    row_offset: usize,
    is_modified: bool,
    status_message: String,
    running: bool,
    is_eaw: bool,
}

impl Editor {
    fn new(filename: Option<String>, is_eaw: bool) -> Self {
        let fname = filename.unwrap_or_else(|| "untitled.txt".to_string());
        let mut lines = vec![String::new()];

        if let Ok(content) = fs::read_to_string(&fname) {
            let normalized = content.trim_end_matches(['\r', '\n']);
            lines = normalized
                .lines()
                .map(|l| l.trim_end_matches('\r').to_string())
                .collect();
            if lines.is_empty() {
                lines.push(String::new());
            }
        }

        Editor {
            filename: fname,
            lines,
            cursor_x: 0,
            cursor_y: 0,
            row_offset: 0,
            is_modified: false,
            status_message: String::new(),
            running: true,
            is_eaw,
        }
    }

    fn grapheme_width(&self, g: &str) -> usize {
        if g == "\t" {
            return 4;
        }
        if g.chars().any(is_control_char) {
            return g
                .chars()
                .map(|ch| {
                    let code = ch as u32;
                    if ch == '\t' {
                        4
                    } else if code < 0x20 || code == 0x7F {
                        2
                    } else if (0x80..0xA0).contains(&code) {
                        1
                    } else {
                        let mut buf = [0u8; 4];
                        let s = ch.encode_utf8(&mut buf);
                        if self.is_eaw {
                            UnicodeWidthStr::width_cjk(s)
                        } else {
                            UnicodeWidthStr::width(s)
                        }
                    }
                })
                .sum();
        }
        if self.is_eaw {
            UnicodeWidthStr::width_cjk(g)
        } else {
            UnicodeWidthStr::width(g)
        }
    }

    fn sanitize_and_measure(&self, text: &str, max_cols: Option<usize>) -> (String, usize) {
        const TAB_WIDTH: usize = 4;
        let mut out = String::new();
        let mut col = 0;
        'outer: for g in text.graphemes(true) {
            if g == "\t" {
                let w = TAB_WIDTH - (col % TAB_WIDTH);
                if let Some(limit) = max_cols {
                    if col + w > limit {
                        break;
                    }
                }
                out.push_str(&" ".repeat(w));
                col += w;
            } else if g.chars().any(is_control_char) {
                for ch in g.chars() {
                    let code = ch as u32;
                    let (disp, w) = if ch == '\t' {
                        let tw = TAB_WIDTH - (col % TAB_WIDTH);
                        (" ".repeat(tw), tw)
                    } else if code < 0x20 {
                        (format!("^{}", char::from_u32(code + 64).unwrap_or('?')), 2)
                    } else if code == 0x7F {
                        ("^?".to_string(), 2)
                    } else if (0x80..0xA0).contains(&code) {
                        ("?".to_string(), 1)
                    } else {
                        let mut buf = [0u8; 4];
                        let s = ch.encode_utf8(&mut buf);
                        (s.to_string(), self.grapheme_width(s))
                    };
                    if let Some(limit) = max_cols {
                        if col + w > limit {
                            break 'outer;
                        }
                    }
                    out.push_str(&disp);
                    col += w;
                }
            } else {
                let w = self.grapheme_width(g);
                if let Some(limit) = max_cols {
                    if col + w > limit {
                        break;
                    }
                }
                out.push_str(g);
                col += w;
            }
        }
        (out, col)
    }

    // 書記素クラスタ単位での行内文字スライス
    fn graphemes_at(&self, y: usize) -> Vec<&str> {
        if y < self.lines.len() {
            self.lines[y].graphemes(true).collect()
        } else {
            Vec::new()
        }
    }

    // MinEd名物: カーソル下の Unicode 情報文字列を生成
    fn current_char_info(&self) -> String {
        let graphemes = self.graphemes_at(self.cursor_y);
        if graphemes.is_empty() {
            return "<Empty Line>".to_string();
        }
        if self.cursor_x >= graphemes.len() {
            return "<EOL>".to_string();
        }

        let target_grapheme = graphemes[self.cursor_x];
        let width = self.grapheme_width(target_grapheme);

        // 書記素を構成する Unicode コードポイント列 (U+XXXX)
        let codepoints: Vec<String> = target_grapheme
            .chars()
            .map(|c| format!("U+{:04X}", c as u32))
            .collect();
        let codepoints_str = codepoints.join(" ");

        let width_desc = if target_grapheme == "\t" {
            format!("Tab ({} cells)", width)
        } else if width == 2 {
            "Wide (2 cells)".to_string()
        } else if width == 1 {
            "Narrow (1 cell)".to_string()
        } else if width == 0 {
            "Zero width (0 cell)".to_string()
        } else {
            format!("{} cells", width)
        };

        format!("'{}' [{}] ({})", target_grapheme, codepoints_str, width_desc)
    }

    // 表示上の幅で切り詰め
    fn truncate_str(&self, text: &str, max_w: usize) -> String {
        self.sanitize_and_measure(text, Some(max_w)).0
    }

    fn str_width(&self, text: &str) -> usize {
        self.sanitize_and_measure(text, None).1
    }

    fn scroll(&mut self, screen_rows: usize) {
        if self.cursor_y < self.row_offset {
            self.row_offset = self.cursor_y;
        }
        if self.cursor_y >= self.row_offset + screen_rows {
            self.row_offset = self.cursor_y - screen_rows + 1;
        }
    }

    // --- 画面描画 ---
    fn render(&mut self) -> Result<(), std::io::Error> {
        let mod_mark = if self.is_modified { "*" } else { "" };
        let _ = execute!(stdout(), SetTitle(format!("mined - {}{}", self.filename, mod_mark)));

        let (cols_u16, rows_u16) = crossterm::terminal::size().unwrap_or((80, 24));
        let cols = cols_u16 as usize;
        let rows = rows_u16 as usize;
        let screen_rows = rows.saturating_sub(1).max(1);

        self.scroll(screen_rows);

        let mut out = String::new();
        out.push_str("\x1b[?2026h\x1b[?25l"); // 同期描画開始 & カーソル隠す

        // 1. 本文テキストエリア
        const LINE_NUM_WIDTH: usize = 4;
        let text_cols = cols.saturating_sub(LINE_NUM_WIDTH + 1).max(1);
        for i in 0..screen_rows {
            let file_row = self.row_offset + i;
            out.push_str(&format!("\x1b[{};1H", i + 1));

            if file_row < self.lines.len() {
                let line_num = format!("{:3} ", file_row + 1);
                out.push_str("\x1b[90m");
                out.push_str(&line_num);
                out.push_str("\x1b[0m");
                out.push_str(&self.truncate_str(&self.lines[file_row], text_cols));
                out.push_str("\x1b[K");
            } else {
                out.push_str("\x1b[90m  ~ \x1b[0m\x1b[K");
            }
        }

        // 2. ステータスバー (最下行: MinEd スタイルで Unicode 情報を常時表示)
        out.push_str(&format!("\x1b[{};1H\x1b[7m", rows));
        let mod_mark = if self.is_modified { " [*]" } else { "" };
        let char_info = self.current_char_info();
        let pos_info = format!("Ln {}, Col {}", self.cursor_y + 1, self.cursor_x + 1);
        let eaw_label = if self.is_eaw { "EAW" } else { "Non-EAW" };

        let left_status = format!(
            " [mined] {}{} ({}) | {} | Char: {}",
            self.filename, mod_mark, eaw_label, pos_info, char_info
        );
        let right_status = if !self.status_message.is_empty() {
            format!("{} | F2: EAW | Ctrl+S: Save | Ctrl+Q: Quit ", self.status_message)
        } else {
            "F2: EAW | Ctrl+U: Hex | Ctrl+S: Save | Ctrl+Q: Quit ".to_string()
        };

        let max_w = cols.saturating_sub(1);
        let left_w = self.str_width(&left_status);
        let right_w = self.str_width(&right_status);
        let pad = max_w.saturating_sub(left_w + right_w);

        let full_bar = format!("{}{}{}", left_status, " ".repeat(pad), right_status);
        out.push_str(&self.truncate_str(&full_bar, max_w));
        out.push_str("\x1b[0m\x1b[K");

        // 3. カーソル位置の設定 (EAW設定に完全追従！)
        let screen_y = (self.cursor_y - self.row_offset) + 1;
        let graphemes = self.graphemes_at(self.cursor_y);
        let prefix: String = graphemes.iter().take(self.cursor_x).copied().collect();
        let visual_x = self.str_width(&prefix);
        let screen_x = (visual_x + LINE_NUM_WIDTH + 1).min(cols);

        out.push_str(&format!("\x1b[{};{}H\x1b[?25h\x1b[?2026l", screen_y, screen_x));

        let mut stdout = stdout();
        stdout.write_all(out.as_bytes())?;
        stdout.flush()?;
        Ok(())
    }

    // --- ファイル保存 ---
    fn save_file(&mut self) {
        let content = self.lines.join("\n") + "\n";
        match fs::write(&self.filename, content) {
            Ok(_) => {
                self.is_modified = false;
                self.status_message = "✅ Saved".to_string();
            }
            Err(e) => {
                self.status_message = format!("❌ Error: {}", e);
            }
        }
    }

    // --- MinEd名物: Unicode Hex 入力ダイアログ (Ctrl+U) ---
    fn prompt_unicode_hex(&mut self) -> Result<(), std::io::Error> {
        let (_cols_u16, rows_u16) = crossterm::terminal::size().unwrap_or((80, 24));
        let rows = rows_u16 as usize;

        let mut hex_buf = String::new();

        while !is_term_requested() {
            // 最下行にプロンプトを描画
            let prompt = format!(" Unicode Hex Input: U+{} ", hex_buf);
            let mut out = format!("\x1b[{};1H\x1b[7m{}\x1b[0m\x1b[K", rows, prompt);
            out.push_str(&format!("\x1b[{};{}H\x1b[?25h", rows, prompt.len() + 1));
            let mut stdout = stdout();
            stdout.write_all(out.as_bytes())?;
            stdout.flush()?;

            if !event::poll(Duration::from_millis(100))? {
                continue;
            }
            if let Event::Key(key) = event::read()? {
                match key.code {
                    KeyCode::Enter => {
                        if !hex_buf.is_empty() {
                            if let Ok(code) = u32::from_str_radix(&hex_buf, 16) {
                                if let Some(ch) = char::from_u32(code) {
                                    self.insert_str(&ch.to_string());
                                    self.status_message = format!("Inserted U+{:04X} '{}'", code, ch);
                                    return Ok(());
                                }
                            }
                            self.status_message = "Invalid Unicode codepoint".to_string();
                        }
                        return Ok(());
                    }
                    KeyCode::Esc => {
                        self.status_message = "Cancelled".to_string();
                        return Ok(());
                    }
                    KeyCode::Backspace => {
                        hex_buf.pop();
                    }
                    KeyCode::Char(c) if c.is_ascii_hexdigit() && hex_buf.len() < 6 => {
                        hex_buf.push(c.to_ascii_uppercase());
                    }
                    _ => {}
                }
            }
        }
        Ok(())
    }

    // --- 編集ロジック (書記素クラスタ完全対応) ---
    fn insert_str(&mut self, s: &str) {
        let graphemes = self.graphemes_at(self.cursor_y);
        let mut new_line = String::new();
        for (i, g) in graphemes.iter().enumerate() {
            if i == self.cursor_x {
                new_line.push_str(s);
            }
            new_line.push_str(g);
        }
        if self.cursor_x >= graphemes.len() {
            new_line.push_str(s);
        }

        self.lines[self.cursor_y] = new_line;
        self.cursor_x += s.graphemes(true).count();
        self.is_modified = true;
    }

    fn insert_newline(&mut self) {
        let graphemes = self.graphemes_at(self.cursor_y);
        let before: String = graphemes.iter().take(self.cursor_x).copied().collect();
        let after: String = graphemes.iter().skip(self.cursor_x).copied().collect();

        self.lines[self.cursor_y] = before;
        self.lines.insert(self.cursor_y + 1, after);
        self.cursor_y += 1;
        self.cursor_x = 0;
        self.is_modified = true;
    }

    fn delete_backward_grapheme(&mut self) {
        let graphemes = self.graphemes_at(self.cursor_y);
        if self.cursor_x > 0 {
            // 書記素クラスタ単位で直前の1文字を削除 (結合文字や絵文字が壊れない！)
            let mut new_line = String::new();
            for (i, g) in graphemes.iter().enumerate() {
                if i != self.cursor_x - 1 {
                    new_line.push_str(g);
                }
            }
            self.lines[self.cursor_y] = new_line;
            self.cursor_x -= 1;
            self.is_modified = true;
        } else if self.cursor_y > 0 {
            // 行頭での削除: 上の行と合体
            let prev_graphemes = self.graphemes_at(self.cursor_y - 1);
            let prev_len = prev_graphemes.len();
            let current_line = self.lines[self.cursor_y].clone();

            self.lines[self.cursor_y - 1].push_str(&current_line);
            self.lines.remove(self.cursor_y);
            self.cursor_y -= 1;
            self.cursor_x = prev_len;
            self.is_modified = true;
        }
    }

    // --- メインループ ---
    fn run(&mut self, auto_probe_eaw: bool) -> Result<(), std::io::Error> {
        install_term_handlers();
        enable_raw_mode()?;
        let _cleanup = CleanUp;

        execute!(
            stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            Clear(ClearType::All)
        )?;
        if auto_probe_eaw {
            self.is_eaw = probe_eaw();
        }
        self.render()?;

        while self.running && !is_term_requested() {
            if !event::poll(Duration::from_millis(100))? {
                continue;
            }
            match event::read()? {
                Event::Resize(_, _) => {
                    self.render()?;
                }
                Event::Paste(text) => {
                    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
                    let parts: Vec<&str> = normalized.split('\n').collect();
                    if parts.len() == 1 {
                        self.insert_str(parts[0]);
                    } else {
                        for (idx, part) in parts.iter().enumerate() {
                            if idx > 0 {
                                self.insert_newline();
                            }
                            if !part.is_empty() {
                                self.insert_str(part);
                            }
                        }
                    }
                    self.render()?;
                }
                Event::Key(key) => {
                    if !self.status_message.is_empty() {
                        self.status_message.clear();
                    }

                    match (key.modifiers, key.code) {
                        // Ctrl+Q / Ctrl+C : 終了
                        (KeyModifiers::CONTROL, KeyCode::Char('q'))
                        | (KeyModifiers::CONTROL, KeyCode::Char('c')) => {
                            self.running = false;
                        }
                        // Ctrl+S : 保存
                        (KeyModifiers::CONTROL, KeyCode::Char('s')) => {
                            self.save_file();
                        }
                        // Ctrl+U : MinEd名物 Unicode Hex 入力
                        (KeyModifiers::CONTROL, KeyCode::Char('u')) => {
                            self.prompt_unicode_hex()?;
                        }
                        // F2 または Ctrl+T : EAWモード (Wide 2 / Narrow 1) のリアルタイムトグル
                        (_, KeyCode::F(2))
                        | (KeyModifiers::CONTROL, KeyCode::Char('t')) => {
                            self.is_eaw = !self.is_eaw;
                            self.status_message = format!(
                                "EAW mode: {}",
                                if self.is_eaw { "Wide (2 cells)" } else { "Narrow (1 cell)" }
                            );
                        }
                        // 矢印キー移動
                        (_, KeyCode::Up) => {
                            if self.cursor_y > 0 {
                                self.cursor_y -= 1;
                                self.cursor_x = self.cursor_x.min(self.graphemes_at(self.cursor_y).len());
                            }
                        }
                        (_, KeyCode::Down) => {
                            if self.cursor_y < self.lines.len() - 1 {
                                self.cursor_y += 1;
                                self.cursor_x = self.cursor_x.min(self.graphemes_at(self.cursor_y).len());
                            }
                        }
                        (_, KeyCode::Left) => {
                            if self.cursor_x > 0 {
                                self.cursor_x -= 1;
                            } else if self.cursor_y > 0 {
                                self.cursor_y -= 1;
                                self.cursor_x = self.graphemes_at(self.cursor_y).len();
                            }
                        }
                        (_, KeyCode::Right) => {
                            let len = self.graphemes_at(self.cursor_y).len();
                            if self.cursor_x < len {
                                self.cursor_x += 1;
                            } else if self.cursor_y < self.lines.len() - 1 {
                                self.cursor_y += 1;
                                self.cursor_x = 0;
                            }
                        }
                        // Home / End
                        (_, KeyCode::Home) => {
                            self.cursor_x = 0;
                        }
                        (_, KeyCode::End) => {
                            self.cursor_x = self.graphemes_at(self.cursor_y).len();
                        }
                        // PageUp / PageDown
                        (_, KeyCode::PageUp) => {
                            let (_, rows) = crossterm::terminal::size().unwrap_or((80, 24));
                            let screen_rows = (rows as usize).saturating_sub(1);
                            self.cursor_y = self.cursor_y.saturating_sub(screen_rows);
                            self.cursor_x = self.cursor_x.min(self.graphemes_at(self.cursor_y).len());
                        }
                        (_, KeyCode::PageDown) => {
                            let (_, rows) = crossterm::terminal::size().unwrap_or((80, 24));
                            let screen_rows = (rows as usize).saturating_sub(1);
                            self.cursor_y = (self.cursor_y + screen_rows).min(self.lines.len() - 1);
                            self.cursor_x = self.cursor_x.min(self.graphemes_at(self.cursor_y).len());
                        }
                        // Enter (改行)
                        (_, KeyCode::Enter) => {
                            self.insert_newline();
                        }
                        // Backspace (書記素削除)
                        (_, KeyCode::Backspace) => {
                            self.delete_backward_grapheme();
                        }
                        // Tab
                        (_, KeyCode::Tab) => {
                            self.insert_str("\t");
                        }
                        // 通常の文字入力
                        (_, KeyCode::Char(c)) => {
                            self.insert_str(&c.to_string());
                        }
                        _ => {}
                    }

                    if self.running {
                        self.render()?;
                    }
                }
                _ => {}
            }
        }

        Ok(())
    }
}

fn probe_eaw() -> bool {
    let mut stdout = stdout();
    // 日本語環境で最も確実な曖昧文字 '※' (U+203B) を不可視でプローブ
    let _ = execute!(
        stdout,
        cursor::SavePosition,
        cursor::MoveTo(0, 0),
        Clear(ClearType::CurrentLine),
        SetAttribute(Attribute::Hidden),
        crossterm::style::Print("※"),
        SetAttribute(Attribute::Reset)
    );
    let _ = stdout.flush();

    std::thread::sleep(std::time::Duration::from_millis(15));

    let is_eaw = match cursor::position() {
        Ok((col, _row)) => col >= 2,
        Err(_) => true,
    };

    let _ = execute!(
        stdout,
        cursor::MoveTo(0, 0),
        Clear(ClearType::CurrentLine),
        cursor::RestorePosition
    );
    let _ = stdout.flush();
    is_eaw
}

fn main() -> Result<(), std::io::Error> {
    if !stdin().is_terminal() {
        eprintln!("エラー: inzm は対話型ターミナル (TTY) で実行してください。");
        std::process::exit(1);
    }

    let args: Vec<String> = env::args().collect();
    let mut filename = None;
    let mut forced_eaw = None;

    for arg in args.into_iter().skip(1) {
        if arg == "--eaw" {
            forced_eaw = Some(true);
        } else if arg == "--no-eaw" {
            forced_eaw = Some(false);
        } else if filename.is_none() {
            filename = Some(arg);
        }
    }

    let (is_eaw, auto_probe) = match forced_eaw {
        Some(forced) => (forced, false),
        None => (true, true),
    };

    let mut editor = Editor::new(filename, is_eaw);
    editor.run(auto_probe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_grapheme_cluster_handling() {
        let mut ed = Editor::new(None, true);
        // 結合文字 (か + 結合濁点)
        let dakuten_ka = "か\u{3099}";
        ed.insert_str(dakuten_ka);
        assert_eq!(ed.lines[0], dakuten_ka);
        assert_eq!(ed.cursor_x, 1); // 1書記素としてカウントされる！

        // Backspaceで濁点だけ残らず、1書記素まるごと削除される！
        ed.delete_backward_grapheme();
        assert_eq!(ed.lines[0], "");
        assert_eq!(ed.cursor_x, 0);

        // 家族絵文字 (ZWJ結合シーケンス)
        let family_emoji = "👨‍👩‍👧‍👦";
        ed.insert_str(family_emoji);
        assert_eq!(ed.lines[0], family_emoji);
        assert_eq!(ed.cursor_x, 1); // 1書記素！

        ed.delete_backward_grapheme();
        assert_eq!(ed.lines[0], "");
    }

    #[test]
    fn test_char_info() {
        let mut ed = Editor::new(None, true);
        ed.insert_str("あ");
        ed.cursor_x = 0; // 'あ' の上に戻る
        let info = ed.current_char_info();
        assert!(info.contains("U+3042"), "Expected U+3042 in info, got: {}", info);
        assert!(info.contains("Wide (2 cells)"), "Expected Wide width in info, got: {}", info);

        // ※ の幅テスト (EAW=true では 2 cells になる！)
        ed.lines[0] = "※".to_string();
        ed.cursor_x = 0;
        let star_info = ed.current_char_info();
        assert!(star_info.contains("U+203B"), "Expected U+203B in info, got: {}", star_info);
        assert!(star_info.contains("Wide (2 cells)"), "In EAW environment, ※ must be Wide (2 cells)!");

        // Tab の幅テスト ("Zero width" にならないこと)
        ed.lines[0] = "\t".to_string();
        ed.cursor_x = 0;
        let tab_info = ed.current_char_info();
        assert!(tab_info.contains("U+0009"), "Expected U+0009 in info, got: {}", tab_info);
        assert!(!tab_info.contains("Zero width"), "Tab must not be labeled Zero width: {}", tab_info);
        assert!(tab_info.contains("Tab (4 cells)"), "Expected Tab (4 cells), got: {}", tab_info);
    }

    #[test]
    fn test_sanitize_crlf_grapheme() {
        let ed = Editor::new(None, true);
        let (out, w) = ed.sanitize_and_measure("a\r\nb", None);
        assert_eq!(out, "a^M^Jb");
        assert_eq!(w, 6);

        let (trunc, tw) = ed.sanitize_and_measure("a\r\nb", Some(3));
        assert_eq!(trunc, "a^M");
        assert_eq!(tw, 3);
    }
}
