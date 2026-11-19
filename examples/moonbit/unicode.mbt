///|
/// Split a string into an array of Unicode scalar values (`Char`).
pub fn chars_of(s : String) -> Array[Char] {
  let out : Array[Char] = []
  for ch in s {
    out.push(ch)
  }
  out
}

///|
/// Join an array slice of `Char` back into a `String`.
pub fn chars_to_string(chars : ArrayView[Char]) -> String {
  String::from_array(chars)
}

///|
/// Return true if the code point is a zero-width / combining character.
fn is_zero_width(cp : Int32) -> Bool {
  (cp >= 0x0300 && cp <= 0x036F) || // Combining Diacritical Marks
  (cp >= 0x1AB0 && cp <= 0x1AFF) || // Combining Diacritical Marks Extended
  (cp >= 0x1DC0 && cp <= 0x1DFF) || // Combining Diacritical Marks Supplement
  (cp >= 0x200B && cp <= 0x200F) || // ZWSP, ZWNJ, ZWJ, LRM, RLM
  (cp >= 0x202A && cp <= 0x202E) || // Bidi embedding/override
  (cp >= 0x20D0 && cp <= 0x20FF) || // Combining Diacritical Marks for Symbols
  (cp >= 0xFE00 && cp <= 0xFE0F) || // Variation Selectors
  (cp >= 0xFE20 && cp <= 0xFE2F) || // Combining Half Marks
  (cp >= 0x3099 && cp <= 0x309A) || // Combining Kana Voiced Sound Marks
  (cp >= 0xE0100 && cp <= 0xE01EF) // Variation Selectors Supplement
}

///|
/// Return true if the code point is an East Asian Ambiguous character commonly
/// rendered at 2 cells in CJK / EAW=2 terminal configurations.
fn is_ambiguous_width(cp : Int32) -> Bool {
  (cp >= 0x0391 && cp <= 0x03C9) || // Greek letters
  (cp >= 0x0410 && cp <= 0x044F) || // Cyrillic letters
  cp == 0x00A7 || // §
  cp == 0x00B0 || // °
  cp == 0x00B1 || // ±
  cp == 0x00D7 || // ×
  cp == 0x00F7 || // ÷
  (cp >= 0x2190 && cp <= 0x2199) || // Arrows
  (cp >= 0x2460 && cp <= 0x249B) || // Enclosed alphanumerics
  (cp >= 0x2500 && cp <= 0x257F) || // Box drawing
  (cp >= 0x25A0 && cp <= 0x25FF) || // Geometric shapes
  (cp >= 0x2605 && cp <= 0x2606) || // ★ ☆
  cp == 0x203B // ※
}

///|
/// Return true if the code point is East Asian Wide / Fullwidth / Emoji (2 cells).
fn is_wide_char(cp : Int32) -> Bool {
  (cp >= 0x1100 && cp <= 0x115F) || // Hangul Jamo init
  cp == 0x2329 ||
  cp == 0x232A ||
  (cp >= 0x2E80 && cp <= 0x303E) || // CJK Radicals, Kangxi, Symbols, Punctuation
  (cp >= 0x3040 && cp <= 0x33FF) || // Hiragana, Katakana, Bopomofo, CJK Compat
  (cp >= 0x3400 && cp <= 0x4DBF) || // CJK Unified Ideographs Ext A
  (cp >= 0x4E00 && cp <= 0x9FFF) || // CJK Unified Ideographs
  (cp >= 0xA000 && cp <= 0xA4CF) || // Yi
  (cp >= 0xAC00 && cp <= 0xD7AF) || // Hangul Syllables
  (cp >= 0xF900 && cp <= 0xFAFF) || // CJK Compatibility Ideographs
  (cp >= 0xFE10 && cp <= 0xFE19) || // Vertical forms
  (cp >= 0xFE30 && cp <= 0xFE6F) || // CJK Compatibility Forms
  (cp >= 0xFF01 && cp <= 0xFF60) || // Fullwidth ASCII variants
  (cp >= 0xFFE0 && cp <= 0xFFE6) || // Fullwidth symbol variants
  (cp >= 0x1F300 && cp <= 0x1FAFF) || // Emoji & Pictographs
  (cp >= 0x20000 && cp <= 0x3FFFF) // CJK Ext B..G
}

///|
/// Compute terminal cell width (0, 1, or 2) for a Unicode `Char`.
pub fn char_width(ch : Char, is_eaw : Bool) -> Int32 {
  let cp = ch.to_int()
  if cp < 0x20 || (cp >= 0x7F && cp < 0xA0) {
    0
  } else if is_zero_width(cp) {
    0
  } else if is_wide_char(cp) {
    2
  } else if is_eaw && is_ambiguous_width(cp) {
    2
  } else {
    1
  }
}

///|
/// Compute total terminal cell width of a `String`.
pub fn string_width(s : String, is_eaw : Bool) -> Int32 {
  let mut w = 0
  for ch in s {
    w += char_width(ch, is_eaw)
  }
  w
}

///|
/// Format a Unicode scalar value as `U+XXXX` (minimum 4 uppercase hex digits).
pub fn format_codepoint(ch : Char) -> String {
  let cp = ch.to_int()
  let hex_digits = "0123456789ABCDEF"
  let rev : Array[Char] = []
  let mut v = cp
  if v == 0 {
    rev.push('0')
  } else {
    while v > 0 {
      let nibble = v & 0xF
      match hex_digits.get_char(nibble) {
        Some(d) => rev.push(d)
        None => ()
      }
      v = v >> 4
    }
  }
  while rev.length() < 4 {
    rev.push('0')
  }
  let buf = StringBuilder()
  buf.write_string("U+")
  let mut i = rev.length() - 1
  while i >= 0 {
    buf.write_char(rev[i])
    i -= 1
  }
  buf.to_string()
}
