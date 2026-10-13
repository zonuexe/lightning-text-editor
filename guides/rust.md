# Rust版 クイックリファレンス

Rustではデファクトスタンダードのクレート `crossterm` を利用するのが最も快適で安全です。クロスプラットフォーム対応で、矢印キーやCtrlキーのハンドリングも型安全に行えます。

---

## ⚡️ クイックスタート

```bash
cargo new my-editor && cd my-editor
cargo add crossterm
cargo run
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```rust
// src/main.rs
use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, Clear, ClearType},
};
use std::io::{stdout, Result};

struct CleanUp;
impl Drop for CleanUp {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(stdout(), Clear(ClearType::All), cursor::MoveTo(0, 0), cursor::Show);
    }
}

fn main() -> Result<()> {
    enable_raw_mode()?;
    let _cleanup = CleanUp; // スコープを抜けると自動でDropされ復元される

    execute!(stdout(), Clear(ClearType::All), cursor::MoveTo(0, 0))?;
    println!("Rustエディタ起動！ Ctrl+Q で終了\r");

    loop {
        if let Event::Key(key_event) = event::read()? {
            // Ctrl+Q で終了
            if key_event.modifiers.contains(KeyModifiers::CONTROL) && key_event.code == KeyCode::Char('q') {
                break;
            }

            match key_event.code {
                KeyCode::Up => { /* 上矢印 */ }
                KeyCode::Down => { /* 下矢印 */ }
                KeyCode::Left => { /* 左矢印 */ }
                KeyCode::Right => { /* 右矢印 */ }
                KeyCode::Enter => { /* 改行 */ }
                KeyCode::Backspace => { /* 削除 */ }
                KeyCode::Char(c) => {
                    // 文字入力
                }
                _ => {}
            }
        }
    }

    Ok(())
}
```

---

## 💾 ファイル保存と読み込み

```rust
use std::fs;

// 読み込み
let content = fs::read_to_string("sample.txt").unwrap_or_default();
let lines: Vec<String> = if content.is_empty() {
    vec![String::new()]
} else {
    content.lines().map(|s| s.to_string()).collect()
};

// 保存
fs::write("sample.txt", lines.join("\n"))?;
```
