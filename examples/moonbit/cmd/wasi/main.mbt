///|
fn parse_positive_int(s : String, fallback : Int32) -> Int32 {
  let mut acc = 0
  let mut has_digit = false
  for ch in s {
    let cp = ch.to_int()
    if cp >= 48 && cp <= 57 {
      has_digit = true
      acc = acc * 10 + (cp - 48)
    } else {
      break
    }
  }
  if has_digit && acc > 0 {
    acc
  } else {
    fallback
  }
}

///|
fn main {
  let args = get_args()
  let filename = if args.length() >= 2 { args[1] } else { "sample.txt" }
  let cols = match get_env("COLUMNS") {
    Some(v) => parse_positive_int(v, 80)
    None => 80
  }
  let rows = match get_env("LINES") {
    Some(v) => parse_positive_int(v, 24)
    None => 24
  }
  let initial_content = match read_file_text(filename) {
    Some(text) => text
    None => ""
  }
  let editor = @inzm.Editor::new(
    cols~,
    rows~,
    filename~,
    content=initial_content,
  )
  if initial_content == "" {
    editor.set_status("New file: \{filename} (Ctrl+S: Save, Ctrl+Q: Quit)")
  } else {
    editor.set_status("Opened \{filename} (Ctrl+S: Save, Ctrl+Q: Quit)")
  }
  write_stdout(@inzm.Editor::enter_alt_screen() + editor.render())
  let buf : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  while !editor.should_quit() {
    let n = fd_read_chunk(0, buf)
    if n <= 0 {
      break
    }
    let slice = Bytes::makei(n, fn(i) { buf[i] })
    let out = editor.feed_bytes(slice)
    if editor.take_save_request() {
      if write_file_text(editor.filename(), editor.content()) {
        editor.mark_saved()
      } else {
        editor.set_status("Save failed (check `wasmtime --dir=.` permissions!)")
      }
      if !editor.should_quit() {
        write_stdout(editor.render())
        continue
      }
    }
    write_stdout(out)
  }
  write_stdout(@inzm.Editor::leave_alt_screen())
}
