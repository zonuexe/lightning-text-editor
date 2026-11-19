pub mod editor;
pub mod highlight;
pub mod input;

use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{AppHandle, DragDropEvent, Emitter, Manager, State, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};

use crate::editor::Editor;

pub struct EditorState {
    editor: Mutex<Editor>,
    allow_close: AtomicBool,
}

#[derive(Debug, Clone, Serialize)]
pub struct RenderPayload {
    pub frame: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct InitPayload {
    pub init_seq: String,
    pub frame: String,
    pub title: String,
}

fn render_payload(ed: &mut Editor) -> RenderPayload {
    let frame = ed.render();
    let title = ed.window_title();
    RenderPayload { frame, title }
}

fn emit_sync(app: &AppHandle, state: &EditorState) {
    let payload = {
        let mut ed = state.editor.lock().expect("editor mutex poisoned");
        render_payload(&mut ed)
    };
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    let _ = app.emit("editor-sync", payload);
}

#[tauri::command]
fn init_editor(
    app: AppHandle,
    state: State<'_, EditorState>,
    cols: usize,
    rows: usize,
) -> InitPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.resize(cols, rows);
    let init_seq = ed.init_sequence();
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    InitPayload {
        init_seq,
        frame: payload.frame,
        title: payload.title,
    }
}

#[tauri::command]
fn on_data(app: AppHandle, state: State<'_, EditorState>, data: String) -> RenderPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.feed_bytes(data.as_bytes());
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    payload
}

#[tauri::command]
fn on_resize(
    app: AppHandle,
    state: State<'_, EditorState>,
    cols: usize,
    rows: usize,
) -> RenderPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.resize(cols, rows);
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    payload
}

#[tauri::command]
fn get_selected_text(state: State<'_, EditorState>) -> String {
    let ed = state.editor.lock().expect("editor mutex poisoned");
    ed.active().selected_text()
}

#[tauri::command]
fn cut_selection(app: AppHandle, state: State<'_, EditorState>) -> (String, RenderPayload) {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    let text = ed.cut_selection();
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    (text, payload)
}

#[tauri::command]
fn select_all(app: AppHandle, state: State<'_, EditorState>) -> RenderPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.select_all();
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    payload
}

#[tauri::command]
fn new_tab(app: AppHandle, state: State<'_, EditorState>) -> RenderPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.new_tab();
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    payload
}

#[tauri::command]
fn toggle_eaw(app: AppHandle, state: State<'_, EditorState>) -> RenderPayload {
    let mut ed = state.editor.lock().expect("editor mutex poisoned");
    ed.toggle_eaw();
    let payload = render_payload(&mut ed);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_title(&payload.title);
    }
    payload
}

fn open_path_into_editor(app: &AppHandle, state: &EditorState, path_str: String) {
    match fs::read_to_string(&path_str) {
        Ok(content) => {
            let mut ed = state.editor.lock().expect("editor mutex poisoned");
            ed.open_or_focus_file(path_str, content);
        }
        Err(err) => {
            let mut ed = state.editor.lock().expect("editor mutex poisoned");
            ed.status_msg = format!("Open failed: {err}");
        }
    }
    emit_sync(app, state);
}

fn handle_open_dialog(app: AppHandle) {
    app.dialog().file().pick_file(move |picked| {
        if let Some(file_path) = picked {
            if let Ok(pb) = file_path.into_path() {
                let state = app.state::<EditorState>();
                open_path_into_editor(&app, &state, pb.to_string_lossy().into_owned());
            }
        }
    });
}

fn write_buffer_to_path(app: &AppHandle, state: &EditorState, path_str: String, content: &str) {
    match fs::write(&path_str, content) {
        Ok(()) => {
            let mut ed = state.editor.lock().expect("editor mutex poisoned");
            ed.mark_saved(path_str);
        }
        Err(err) => {
            let mut ed = state.editor.lock().expect("editor mutex poisoned");
            ed.status_msg = format!("Save failed: {err}");
        }
    }
    emit_sync(app, state);
}

fn handle_save(app: AppHandle, force_save_as: bool) {
    let (existing_path, content, default_name) = {
        let state = app.state::<EditorState>();
        let ed = state.editor.lock().expect("editor mutex poisoned");
        let buf = ed.active();
        (
            if force_save_as {
                None
            } else {
                buf.path.clone()
            },
            buf.full_text(),
            buf.display_name().to_string(),
        )
    };

    if let Some(path) = existing_path {
        let state = app.state::<EditorState>();
        write_buffer_to_path(&app, &state, path, &content);
    } else {
        app.dialog()
            .file()
            .set_file_name(&default_name)
            .save_file(move |picked| {
                if let Some(file_path) = picked {
                    if let Ok(pb) = file_path.into_path() {
                        let state = app.state::<EditorState>();
                        write_buffer_to_path(
                            &app,
                            &state,
                            pb.to_string_lossy().into_owned(),
                            &content,
                        );
                    }
                }
            });
    }
}

fn handle_close_tab(app: AppHandle) {
    let (dirty, name) = {
        let state = app.state::<EditorState>();
        let ed = state.editor.lock().expect("editor mutex poisoned");
        (ed.active().dirty, ed.active().display_name().to_string())
    };

    if !dirty {
        let state = app.state::<EditorState>();
        {
            let mut ed = state.editor.lock().expect("editor mutex poisoned");
            ed.close_active_tab();
        }
        emit_sync(&app, &state);
        return;
    }

    app.dialog()
        .message(format!(
            "Tab \"{name}\" has unsaved changes. Close without saving?"
        ))
        .title("Unsaved Changes")
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Close Tab".into(),
            "Cancel".into(),
        ))
        .show(move |confirmed| {
            if confirmed {
                let state = app.state::<EditorState>();
                {
                    let mut ed = state.editor.lock().expect("editor mutex poisoned");
                    ed.close_active_tab();
                }
                emit_sync(&app, &state);
            }
        });
}

fn request_quit_or_close(app: AppHandle) {
    let any_dirty = {
        let state = app.state::<EditorState>();
        let ed = state.editor.lock().expect("editor mutex poisoned");
        ed.any_dirty()
    };

    if !any_dirty {
        let state = app.state::<EditorState>();
        state.allow_close.store(true, Ordering::SeqCst);
        if let Some(win) = app.get_webview_window("main") {
            let _ = win.close();
        } else {
            app.exit(0);
        }
        return;
    }

    app.dialog()
        .message("One or more tabs have unsaved changes. Quit anyway?")
        .title("Unsaved Changes")
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Quit Anyway".into(),
            "Cancel".into(),
        ))
        .show(move |confirmed| {
            if confirmed {
                let state = app.state::<EditorState>();
                state.allow_close.store(true, Ordering::SeqCst);
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.close();
                } else {
                    app.exit(0);
                }
            }
        });
}

#[tauri::command]
fn open_file_dialog(app: AppHandle) {
    handle_open_dialog(app);
}

#[tauri::command]
fn save_file(app: AppHandle) {
    handle_save(app, false);
}

#[tauri::command]
fn save_file_as(app: AppHandle) {
    handle_save(app, true);
}

#[tauri::command]
fn close_tab(app: AppHandle) {
    handle_close_tab(app);
}

fn build_menu(app: &AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let app_sub = SubmenuBuilder::new(app, "inzm")
        .about(None)
        .separator()
        .item(
            &MenuItemBuilder::with_id("app-quit", "Quit inzm")
                .accelerator("CmdOrCtrl+Q")
                .build(app)?,
        )
        .build()?;

    let file_sub = SubmenuBuilder::new(app, "File")
        .item(
            &MenuItemBuilder::with_id("file-new-tab", "New Tab")
                .accelerator("CmdOrCtrl+T")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("file-new-win", "New Buffer")
                .accelerator("CmdOrCtrl+N")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("file-open", "Open...")
                .accelerator("CmdOrCtrl+O")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("file-save", "Save")
                .accelerator("CmdOrCtrl+S")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("file-save-as", "Save As...")
                .accelerator("CmdOrCtrl+Shift+S")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("file-close-tab", "Close Tab")
                .accelerator("CmdOrCtrl+W")
                .build(app)?,
        )
        .build()?;

    let edit_sub = SubmenuBuilder::new(app, "Edit")
        .item(
            &MenuItemBuilder::with_id("edit-undo", "Undo")
                .accelerator("CmdOrCtrl+Z")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("edit-redo", "Redo")
                .accelerator("CmdOrCtrl+Shift+Z")
                .build(app)?,
        )
        .separator()
        // Keep Cmd+C/X handled in xterm.js gesture context, while Edit -> Paste uses native Cocoa Paste.
        .item(&MenuItemBuilder::with_id("edit-cut", "Cut (⌘X)").build(app)?)
        .item(&MenuItemBuilder::with_id("edit-copy", "Copy (⌘C)").build(app)?)
        .item(&PredefinedMenuItem::paste(app, Some("Paste"))?)
        .item(
            &MenuItemBuilder::with_id("edit-select-all", "Select All")
                .accelerator("CmdOrCtrl+A")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("edit-find", "Find...")
                .accelerator("CmdOrCtrl+F")
                .build(app)?,
        )
        .build()?;

    let view_sub = SubmenuBuilder::new(app, "View")
        .item(
            &MenuItemBuilder::with_id("view-next-tab", "Next Tab")
                .accelerator("CmdOrCtrl+Shift+]")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("view-prev-tab", "Previous Tab")
                .accelerator("CmdOrCtrl+Shift+[")
                .build(app)?,
        )
        .separator()
        .item(
            &MenuItemBuilder::with_id("view-eaw", "Toggle East Asian Width")
                .build(app)?,
        )
        .build()?;

    MenuBuilder::new(app)
        .items(&[&app_sub, &file_sub, &edit_sub, &view_sub])
        .build()
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(EditorState {
            editor: Mutex::new(Editor::new(100, 34)),
            allow_close: AtomicBool::new(false),
        })
        .setup(|app| {
            let menu = build_menu(app.handle())?;
            app.set_menu(menu)?;
            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            let state = app.state::<EditorState>();
            match id {
                "file-new-tab" | "file-new-win" => {
                    state.editor.lock().expect("editor mutex").new_tab();
                    emit_sync(app, &state);
                }
                "file-open" => handle_open_dialog(app.clone()),
                "file-save" => handle_save(app.clone(), false),
                "file-save-as" => handle_save(app.clone(), true),
                "file-close-tab" => handle_close_tab(app.clone()),
                "app-quit" => request_quit_or_close(app.clone()),
                "edit-undo" => {
                    state.editor.lock().expect("editor mutex").undo();
                    emit_sync(app, &state);
                }
                "edit-redo" => {
                    state.editor.lock().expect("editor mutex").redo();
                    emit_sync(app, &state);
                }
                "edit-select-all" => {
                    state.editor.lock().expect("editor mutex").select_all();
                    emit_sync(app, &state);
                }
                "edit-find" => {
                    state.editor.lock().expect("editor mutex").start_find();
                    emit_sync(app, &state);
                }
                "edit-copy" => {
                    let _ = app.emit("menu-copy", ());
                }
                "edit-cut" => {
                    let _ = app.emit("menu-cut", ());
                }
                "view-next-tab" => {
                    state.editor.lock().expect("editor mutex").cycle_tab(1);
                    emit_sync(app, &state);
                }
                "view-prev-tab" => {
                    state.editor.lock().expect("editor mutex").cycle_tab(-1);
                    emit_sync(app, &state);
                }
                "view-eaw" => {
                    state.editor.lock().expect("editor mutex").toggle_eaw();
                    emit_sync(app, &state);
                }
                _ => {}
            }
        })
        .on_window_event(|window, event| match event {
            WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) => {
                let app = window.app_handle();
                let state = app.state::<EditorState>();
                for path in paths {
                    if path.is_file() {
                        open_path_into_editor(
                            app,
                            &state,
                            path.to_string_lossy().into_owned(),
                        );
                    }
                }
            }
            WindowEvent::CloseRequested { api, .. } => {
                let app = window.app_handle();
                let state = app.state::<EditorState>();
                if state.allow_close.load(Ordering::SeqCst) {
                    return;
                }
                let dirty = state.editor.lock().expect("editor mutex").any_dirty();
                if dirty {
                    api.prevent_close();
                    request_quit_or_close(app.clone());
                }
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            init_editor,
            on_data,
            on_resize,
            get_selected_text,
            cut_selection,
            select_all,
            new_tab,
            toggle_eaw,
            open_file_dialog,
            save_file,
            save_file_as,
            close_tab,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
