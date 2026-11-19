///|
let state : Ref[@inzm.Editor?] = { val: None, }

///|
fn ensure_editor() -> @inzm.Editor {
  match state.val {
    Some(ed) => ed
    None => {
      let ed = @inzm.Editor::new(
        cols=80,
        rows=24,
        filename="untitled.txt",
        content="",
      )
      state.val = Some(ed)
      ed
    }
  }
}

///|
pub fn init_editor(
  cols : Int32,
  rows : Int32,
  filename : String,
  content : String,
) -> String {
  let ed = @inzm.Editor::new(cols~, rows~, filename~, content~)
  state.val = Some(ed)
  @inzm.Editor::enter_alt_screen() + ed.render()
}

///|
pub fn load_file(filename : String, content : String) -> String {
  let ed = ensure_editor()
  ed.load_file(filename, content)
  ed.render()
}

///|
pub fn on_data(data : String) -> String {
  let ed = ensure_editor()
  ed.feed_str(data)
}

///|
pub fn on_resize(cols : Int32, rows : Int32) -> String {
  let ed = ensure_editor()
  ed.resize(cols, rows)
  ed.render()
}

///|
pub fn get_content() -> String {
  ensure_editor().content()
}

///|
pub fn get_selected_text() -> String {
  ensure_editor().selected_text()
}

///|
pub fn delete_selection() -> String {
  let ed = ensure_editor()
  ignore(ed.delete_selection())
  ed.render()
}

///|
pub fn get_filename() -> String {
  ensure_editor().filename()
}

///|
pub fn should_quit() -> Bool {
  ensure_editor().should_quit()
}

///|
pub fn take_save_request() -> Bool {
  ensure_editor().take_save_request()
}

///|
pub fn mark_saved() -> String {
  let ed = ensure_editor()
  ed.mark_saved()
  ed.render()
}
