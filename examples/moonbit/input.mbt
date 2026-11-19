///|
/// Decoded terminal input events.
#derive(Eq, Debug)
pub enum KeyEvent {
  Char(Char)
  Enter
  Backspace
  Delete
  Tab
  Up
  Down
  Right
  Left
  Home
  End
  PageUp
  PageDown
  WordLeft
  WordRight
  DocStart
  DocEnd
  DeleteWordBack
  DeleteWordForward
  DeleteToLineStart
  ShiftUp
  ShiftDown
  ShiftRight
  ShiftLeft
  ShiftHome
  ShiftEnd
  ShiftWordLeft
  ShiftWordRight
  ShiftDocStart
  ShiftDocEnd
  SelectAll
  MouseClick(Int32, Int32)
  MouseDrag(Int32, Int32)
  MouseWheelUp
  MouseWheelDown
  Ctrl(Char)
  Escape
}

///|
/// Stateful streaming decoder for raw UTF-8 bytes and ANSI escape sequences.
pub struct InputDecoder {
  mut utf8_pending : Array[Byte]
  mut esc_pending : String
  mut in_paste : Bool
}

///|
pub fn InputDecoder::new() -> InputDecoder {
  { utf8_pending: [], esc_pending: "", in_paste: false, }
}

///|
fn expected_utf8_len(first : Byte) -> Int32 {
  let b = first.to_int()
  if (b & 0x80) == 0 {
    1
  } else if (b & 0xE0) == 0xC0 {
    2
  } else if (b & 0xF0) == 0xE0 {
    3
  } else if (b & 0xF8) == 0xF0 {
    4
  } else {
    1
  }
}

///|
/// Feed raw bytes (e.g. from WASI `fd_read`) and decode into a `String`
/// while preserving incomplete trailing UTF-8 sequences for the next read.
pub fn InputDecoder::decode_bytes(
  self : InputDecoder,
  chunk : BytesView,
) -> String {
  for b in chunk {
    self.utf8_pending.push(b)
  }
  let pending = self.utf8_pending
  let total = pending.length()
  if total == 0 {
    return ""
  }
  // Find if the tail contains an incomplete UTF-8 multi-byte character.
  let mut complete_end = total
  let scan_start = if total > 4 { total - 4 } else { 0 }
  let mut i = scan_start
  while i < total {
    let b = pending[i].to_int()
    if (b & 0xC0) != 0x80 {
      let need = expected_utf8_len(pending[i])
      if i + need > total {
        complete_end = i
        break
      }
      i += need
    } else {
      i += 1
    }
  }
  if complete_end == 0 {
    return ""
  }
  let ready = Bytes::makei(complete_end, fn(idx) { pending[idx] })
  let rest : Array[Byte] = []
  for j = complete_end; j < total; j = j + 1 {
    rest.push(pending[j])
  }
  self.utf8_pending = rest
  @utf8.decode_lossy(ready)
}

///|
fn is_csi_final(ch : Char) -> Bool {
  let cp = ch.to_int()
  cp >= 0x40 && cp <= 0x7E
}

///|
fn parse_uint_prefix(s : String) -> Int32? {
  if s == "" {
    return None
  }
  let mut acc = 0
  for ch in s {
    let cp = ch.to_int()
    if cp >= 48 && cp <= 57 {
      acc = acc * 10 + (cp - 48)
    } else {
      return None
    }
  }
  Some(acc)
}

///|
fn parse_sgr_mouse(body : String, is_press : Bool) -> KeyEvent? {
  if !is_press || !body.has_prefix("<") {
    return None
  }
  let rest = body[1:].to_owned()
  let parts : Array[String] = []
  for part in rest.split(";") {
    parts.push(part.to_owned())
  }
  if parts.length() != 3 {
    return None
  }
  match
    (
      parse_uint_prefix(parts[0]),
      parse_uint_prefix(parts[1]),
      parse_uint_prefix(parts[2]),
    ) {
    (Some(btn), Some(col), Some(row)) =>
      if btn == 0 {
        Some(KeyEvent::MouseClick(col, row))
      } else if btn == 32 {
        Some(KeyEvent::MouseDrag(col, row))
      } else if btn == 64 {
        Some(KeyEvent::MouseWheelUp)
      } else if btn == 65 {
        Some(KeyEvent::MouseWheelDown)
      } else {
        None
      }
    _ => None
  }
}

///|
fn parse_csi(seq : String) -> KeyEvent? {
  // `seq` begins with "\x1b[" and ends with a CSI final byte.
  let chars = chars_of(seq)
  if chars.length() < 3 {
    return None
  }
  let final_ch = chars[chars.length() - 1]
  let body = chars_to_string(chars[2:chars.length() - 1])
  match final_ch {
    'A' =>
      if body == "1;9" {
        Some(KeyEvent::DocStart)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftUp)
      } else if body == "1;6" || body == "1;10" {
        Some(KeyEvent::ShiftDocStart)
      } else {
        Some(KeyEvent::Up)
      }
    'B' =>
      if body == "1;9" {
        Some(KeyEvent::DocEnd)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftDown)
      } else if body == "1;6" || body == "1;10" {
        Some(KeyEvent::ShiftDocEnd)
      } else {
        Some(KeyEvent::Down)
      }
    'C' =>
      if body == "1;3" || body == "1;9" {
        Some(KeyEvent::WordRight)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftRight)
      } else if body == "1;4" || body == "1;10" {
        Some(KeyEvent::ShiftWordRight)
      } else {
        Some(KeyEvent::Right)
      }
    'D' =>
      if body == "1;3" || body == "1;9" {
        Some(KeyEvent::WordLeft)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftLeft)
      } else if body == "1;4" || body == "1;10" {
        Some(KeyEvent::ShiftWordLeft)
      } else {
        Some(KeyEvent::Left)
      }
    'H' =>
      if body == "1;5" || body == "1;9" {
        Some(KeyEvent::DocStart)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftHome)
      } else if body == "1;6" || body == "1;10" {
        Some(KeyEvent::ShiftDocStart)
      } else {
        Some(KeyEvent::Home)
      }
    'F' =>
      if body == "1;5" || body == "1;9" {
        Some(KeyEvent::DocEnd)
      } else if body == "1;2" {
        Some(KeyEvent::ShiftEnd)
      } else if body == "1;6" || body == "1;10" {
        Some(KeyEvent::ShiftDocEnd)
      } else {
        Some(KeyEvent::End)
      }
    'u' =>
      if body == "127;9" {
        Some(KeyEvent::DeleteToLineStart)
      } else if body == "97;9" {
        Some(KeyEvent::SelectAll)
      } else {
        None
      }
    'M' => parse_sgr_mouse(body, true)
    'm' => parse_sgr_mouse(body, false)
    '~' => {
      // Strip optional modifier suffix (e.g. "1;5" -> "1")
      let code = match body.find(";") {
        Some(idx) => body[:idx].to_owned()
        None => body
      }
      match code {
        "1" | "7" => Some(KeyEvent::Home)
        "3" => Some(KeyEvent::Delete)
        "4" | "8" => Some(KeyEvent::End)
        "5" => Some(KeyEvent::PageUp)
        "6" => Some(KeyEvent::PageDown)
        // Bracketed paste markers (200 / 201): ignore marker itself, keep content
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Parse a string chunk (e.g. from `xterm.js` `onData` or decoded UTF-8 bytes)
/// into a list of `KeyEvent`s.
pub fn InputDecoder::parse_str(
  self : InputDecoder,
  chunk : String,
) -> Array[KeyEvent] {
  let combined = self.esc_pending + chunk
  self.esc_pending = ""
  let chars = chars_of(combined)
  let events : Array[KeyEvent] = []
  let n = chars.length()
  let mut i = 0
  let end_marker : Array[Char] = ['\u{1B}', '[', '2', '0', '1', '~']
  while i < n {
    let ch = chars[i]
    let cp = ch.to_int()
    if self.in_paste {
      if cp == 0x1B {
        let rem = n - i
        if rem >= 6 &&
          chars[i] == end_marker[0] &&
          chars[i + 1] == end_marker[1] &&
          chars[i + 2] == end_marker[2] &&
          chars[i + 3] == end_marker[3] &&
          chars[i + 4] == end_marker[4] &&
          chars[i + 5] == end_marker[5] {
          self.in_paste = false
          i += 6
        } else if rem < 6 {
          let mut is_prefix = true
          for k = 0; k < rem; k = k + 1 {
            if chars[i + k] != end_marker[k] {
              is_prefix = false
              break
            }
          }
          if is_prefix {
            self.esc_pending = chars_to_string(chars[i:n])
            break
          }
          events.push(KeyEvent::Char(ch))
          i += 1
        } else {
          events.push(KeyEvent::Char(ch))
          i += 1
        }
      } else if cp == 0x0D || cp == 0x0A {
        events.push(KeyEvent::Enter)
        if cp == 0x0D && i + 1 < n && chars[i + 1].to_int() == 0x0A {
          i += 2
        } else {
          i += 1
        }
      } else {
        events.push(KeyEvent::Char(ch))
        i += 1
      }
    } else if cp == 0x1B {
      // Escape sequence handling
      if i + 1 >= n {
        // Standalone ESC -> emit Escape immediately so user doesn't wait
        events.push(KeyEvent::Escape)
        i += 1
      } else {
        let next = chars[i + 1]
        if next == '[' {
          // CSI sequence: \x1b[ ... <final 0x40..0x7E>
          let mut j = i + 2
          let mut found = false
          while j < n {
            if is_csi_final(chars[j]) {
              found = true
              break
            }
            j += 1
          }
          if !found {
            // Incomplete CSI sequence: save remainder for next chunk
            self.esc_pending = chars_to_string(chars[i:n])
            break
          }
          let seq = chars_to_string(chars[i:j + 1])
          if seq == "\u{1B}[200~" {
            self.in_paste = true
          } else {
            match parse_csi(seq) {
              Some(ev) => events.push(ev)
              None => ()
            }
          }
          i = j + 1
        } else if next == 'O' {
          // SS3 sequence: \x1bO<char>
          if i + 2 >= n {
            self.esc_pending = chars_to_string(chars[i:n])
            break
          }
          match chars[i + 2] {
            'H' => events.push(KeyEvent::Home)
            'F' => events.push(KeyEvent::End)
            'A' => events.push(KeyEvent::Up)
            'B' => events.push(KeyEvent::Down)
            'C' => events.push(KeyEvent::Right)
            'D' => events.push(KeyEvent::Left)
            _ => ()
          }
          i += 3
        } else if next.to_int() == 0x7F || next.to_int() == 0x08 {
          // Option/Alt + Backspace (\x1b\x7f or \x1b\x08)
          events.push(KeyEvent::DeleteWordBack)
          i += 2
        } else if next == 'b' || next == 'B' {
          events.push(KeyEvent::WordLeft)
          i += 2
        } else if next == 'f' || next == 'F' {
          events.push(KeyEvent::WordRight)
          i += 2
        } else if next == 'd' || next == 'D' {
          events.push(KeyEvent::DeleteWordForward)
          i += 2
        } else {
          // Unknown 2-char ESC sequence: treat ESC separately
          events.push(KeyEvent::Escape)
          i += 1
        }
      }
    } else if cp == 0x0D || cp == 0x0A {
      events.push(KeyEvent::Enter)
      // Consume CRLF pair as a single Enter
      if cp == 0x0D && i + 1 < n && chars[i + 1].to_int() == 0x0A {
        i += 2
      } else {
        i += 1
      }
    } else if cp == 0x09 {
      events.push(KeyEvent::Tab)
      i += 1
    } else if cp == 0x7F || cp == 0x08 {
      events.push(KeyEvent::Backspace)
      i += 1
    } else if cp >= 1 && cp <= 26 {
      let letter = (cp + 96).unsafe_to_char()
      events.push(KeyEvent::Ctrl(letter))
      i += 1
    } else if cp >= 0x20 {
      events.push(KeyEvent::Char(ch))
      i += 1
    } else {
      i += 1
    }
  }
  events
}
