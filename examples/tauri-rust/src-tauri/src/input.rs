//! ANSI / CSI / SGR Mouse input decoder for xterm.js streams.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Modifiers {
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

impl Modifiers {
    fn from_csi_param(param: u16) -> Self {
        let bits = param.saturating_sub(1);
        Self {
            shift: (bits & 1) != 0,
            alt: (bits & 2) != 0 || (bits & 8) != 0, // Alt (2) or Meta/Cmd mapped to Home/End/Word
            ctrl: (bits & 4) != 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseKind {
    Down,
    Drag,
    Up,
    WheelUp,
    WheelDown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseEvent {
    pub kind: MouseKind,
    pub button: u8,
    pub col: usize, // 0-based
    pub row: usize, // 0-based
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEvent {
    Text(String),
    Paste(String),
    Enter,
    Backspace,
    Delete,
    Tab,
    BackTab,
    Escape,
    Up(Modifiers),
    Down(Modifiers),
    Left(Modifiers),
    Right(Modifiers),
    Home(Modifiers),
    End(Modifiers),
    PageUp(Modifiers),
    PageDown(Modifiers),
    Ctrl(char),
    AltBackspace,
    AltDelete,
    Mouse(MouseEvent),
}

pub struct InputDecoder {
    pending: Vec<u8>,
    in_paste: bool,
    paste_buf: Vec<u8>,
}

impl Default for InputDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl InputDecoder {
    pub fn new() -> Self {
        Self {
            pending: Vec::new(),
            in_paste: false,
            paste_buf: Vec::new(),
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Vec<InputEvent> {
        self.pending.extend_from_slice(bytes);
        let mut events = Vec::new();
        let mut i = 0;

        while i < self.pending.len() {
            if self.in_paste {
                if let Some(pos) = find_subslice(&self.pending[i..], b"\x1b[201~") {
                    self.paste_buf.extend_from_slice(&self.pending[i..i + pos]);
                    let pasted = String::from_utf8_lossy(&self.paste_buf).into_owned();
                    self.paste_buf.clear();
                    self.in_paste = false;
                    if !pasted.is_empty() {
                        events.push(InputEvent::Paste(pasted));
                    }
                    i += pos + 6;
                    continue;
                } else {
                    // Keep trailing 5 bytes in case "\x1b[201~" splits across chunks.
                    let safe = self.pending.len().saturating_sub(5);
                    if safe > i {
                        self.paste_buf.extend_from_slice(&self.pending[i..safe]);
                        i = safe;
                    }
                    break;
                }
            }

            let b = self.pending[i];
            match b {
                b'\x1b' => {
                    if i + 1 >= self.pending.len() {
                        // Standalone ESC at end of current chunk; treat immediately since
                        // xterm.js sends complete CSI sequences in single onData calls.
                        events.push(InputEvent::Escape);
                        i += 1;
                        continue;
                    }
                    let next = self.pending[i + 1];
                    if next == b'[' {
                        if let Some((ev_opt, consumed, entered_paste)) =
                            parse_csi(&self.pending[i..])
                        {
                            i += consumed;
                            if entered_paste {
                                self.in_paste = true;
                            } else if let Some(ev) = ev_opt {
                                events.push(ev);
                            }
                            continue;
                        } else {
                            // Incomplete CSI sequence; wait for more bytes unless suspiciously long.
                            if self.pending.len() - i < 64 {
                                break;
                            }
                            i += 2;
                            continue;
                        }
                    } else if next == b'O' {
                        if i + 2 >= self.pending.len() {
                            break;
                        }
                        match self.pending[i + 2] {
                            b'H' => events.push(InputEvent::Home(Modifiers::default())),
                            b'F' => events.push(InputEvent::End(Modifiers::default())),
                            b'A' => events.push(InputEvent::Up(Modifiers::default())),
                            b'B' => events.push(InputEvent::Down(Modifiers::default())),
                            b'C' => events.push(InputEvent::Right(Modifiers::default())),
                            b'D' => events.push(InputEvent::Left(Modifiers::default())),
                            _ => {}
                        }
                        i += 3;
                        continue;
                    } else if next == 0x7f || next == 0x08 {
                        events.push(InputEvent::AltBackspace);
                        i += 2;
                        continue;
                    } else if next == b'b' {
                        events.push(InputEvent::Left(Modifiers {
                            alt: true,
                            ..Default::default()
                        }));
                        i += 2;
                        continue;
                    } else if next == b'f' {
                        events.push(InputEvent::Right(Modifiers {
                            alt: true,
                            ..Default::default()
                        }));
                        i += 2;
                        continue;
                    } else {
                        events.push(InputEvent::Escape);
                        i += 1;
                        continue;
                    }
                }
                b'\r' | b'\n' => {
                    events.push(InputEvent::Enter);
                    i += 1;
                }
                0x7f | 0x08 => {
                    events.push(InputEvent::Backspace);
                    i += 1;
                }
                b'\t' => {
                    events.push(InputEvent::Tab);
                    i += 1;
                }
                1..=26 => {
                    let ch = (b'a' + (b - 1)) as char;
                    events.push(InputEvent::Ctrl(ch));
                    i += 1;
                }
                0x00 | 0x1c..=0x1f => {
                    i += 1;
                }
                _ => {
                    // Printable ASCII or UTF-8 run
                    let start = i;
                    let mut text = String::new();
                    while i < self.pending.len() {
                        let byte = self.pending[i];
                        if byte < 0x20 || byte == 0x7f {
                            break;
                        }
                        if byte < 0x80 {
                            text.push(byte as char);
                            i += 1;
                        } else {
                            let width = utf8_char_len(byte);
                            if i + width > self.pending.len() {
                                // Wait for trailing UTF-8 bytes
                                if !text.is_empty() {
                                    events.push(InputEvent::Text(text));
                                }
                                self.pending.drain(..i);
                                return events;
                            }
                            if let Ok(s) = std::str::from_utf8(&self.pending[i..i + width]) {
                                text.push_str(s);
                                i += width;
                            } else {
                                // Invalid UTF-8 byte; skip
                                i += 1;
                            }
                        }
                    }
                    if !text.is_empty() {
                        events.push(InputEvent::Text(text));
                    } else if i == start {
                        i += 1;
                    }
                }
            }
        }

        if i > 0 {
            self.pending.drain(..i);
        }
        events
    }
}

fn utf8_char_len(first: u8) -> usize {
    if first & 0b1110_0000 == 0b1100_0000 {
        2
    } else if first & 0b1111_0000 == 0b1110_0000 {
        3
    } else if first & 0b1111_1000 == 0b1111_0000 {
        4
    } else {
        1
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Returns `(Option<InputEvent>, bytes_consumed, entered_bracketed_paste)`.
fn parse_csi(buf: &[u8]) -> Option<(Option<InputEvent>, usize, bool)> {
    // buf starts with "\x1b["
    if buf.len() < 3 {
        return None;
    }

    // SGR mouse: "\x1b[<b;x;yM" or "\x1b[<b;x;ym"
    if buf[2] == b'<' {
        let mut end = 3;
        while end < buf.len() && buf[end] != b'M' && buf[end] != b'm' {
            end += 1;
        }
        if end >= buf.len() {
            return None;
        }
        let body = std::str::from_utf8(&buf[3..end]).ok()?;
        let mut parts = body.split(';');
        let raw_btn = parts.next()?.parse::<u16>().ok()?;
        let col_1 = parts.next()?.parse::<usize>().ok()?;
        let row_1 = parts.next()?.parse::<usize>().ok()?;
        let is_release = buf[end] == b'm';

        let col = col_1.saturating_sub(1);
        let row = row_1.saturating_sub(1);
        let kind = if (raw_btn & 64) != 0 {
            if (raw_btn & 1) == 0 {
                MouseKind::WheelUp
            } else {
                MouseKind::WheelDown
            }
        } else if is_release {
            MouseKind::Up
        } else if (raw_btn & 32) != 0 {
            MouseKind::Drag
        } else {
            MouseKind::Down
        };
        let button = (raw_btn & 0b11) as u8;
        return Some((
            Some(InputEvent::Mouse(MouseEvent {
                kind,
                button,
                col,
                row,
            })),
            end + 1,
            false,
        ));
    }

    // Standard CSI: parameter bytes 0x30..=0x3F, final byte 0x40..=0x7E
    let mut end = 2;
    while end < buf.len() && !(0x40..=0x7e).contains(&buf[end]) {
        end += 1;
    }
    if end >= buf.len() {
        return None;
    }

    let final_byte = buf[end];
    let params_str = std::str::from_utf8(&buf[2..end]).unwrap_or("");
    let params: Vec<u16> = if params_str.is_empty() {
        Vec::new()
    } else {
        params_str
            .split(';')
            .map(|p| p.parse::<u16>().unwrap_or(0))
            .collect()
    };
    let consumed = end + 1;

    if final_byte == b'~' {
        let code = params.first().copied().unwrap_or(0);
        let mods = params
            .get(1)
            .copied()
            .map(Modifiers::from_csi_param)
            .unwrap_or_default();
        return match code {
            1 | 7 => Some((Some(InputEvent::Home(mods)), consumed, false)),
            4 | 8 => Some((Some(InputEvent::End(mods)), consumed, false)),
            3 => {
                if mods.alt {
                    Some((Some(InputEvent::AltDelete), consumed, false))
                } else {
                    Some((Some(InputEvent::Delete), consumed, false))
                }
            }
            5 => Some((Some(InputEvent::PageUp(mods)), consumed, false)),
            6 => Some((Some(InputEvent::PageDown(mods)), consumed, false)),
            200 => Some((None, consumed, true)),
            201 => Some((None, consumed, false)),
            _ => Some((None, consumed, false)),
        };
    }

    let mods = params
        .get(1)
        .copied()
        .map(Modifiers::from_csi_param)
        .unwrap_or_default();

    let ev = match final_byte {
        b'A' => Some(InputEvent::Up(mods)),
        b'B' => Some(InputEvent::Down(mods)),
        b'C' => Some(InputEvent::Right(mods)),
        b'D' => Some(InputEvent::Left(mods)),
        b'H' => Some(InputEvent::Home(mods)),
        b'F' => Some(InputEvent::End(mods)),
        b'Z' => Some(InputEvent::BackTab),
        _ => None,
    };

    Some((ev, consumed, false))
}
