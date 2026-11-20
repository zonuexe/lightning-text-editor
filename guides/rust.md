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
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, Clear, ClearType},
};
use std::io::{stdout, Result, Write};

struct CleanUp;
impl Drop for CleanUp {
    fn drop(&mut self) {
        let _ = execute!(stdout(), Clear(ClearType::All), cursor::MoveTo(0, 0), cursor::Show);
        let _ = stdout().flush();
        let _ = disable_raw_mode();
    }
}

fn main() -> Result<()> {
    enable_raw_mode()?;
    let _cleanup = CleanUp; // スコープを抜けると自動でDropされ復元される

    execute!(stdout(), Clear(ClearType::All), cursor::MoveTo(0, 0))?;
    println!("Rustエディタ起動！ Ctrl+Q で終了\r");

    loop {
        if let Event::Key(key_event) = event::read()? {
            // Windows ではキーを離したとき（Release）にもイベントが届くので、押下だけを処理する
            if key_event.kind != KeyEventKind::Press {
                continue;
            }
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
                // Ctrl / Alt 付きの文字（Ctrl+A 等）は本文に挿入しない
                KeyCode::Char(c)
                    if !key_event.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    // 文字入力
                    let _ = c;
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

// 読み込み（ファイルが無いときだけ空バッファ。非 UTF-8 などで読めないときは開くのを中止する。
// unwrap_or_default() で握りつぶすと空バッファで開き、保存した瞬間に中身が消える）
let content = match fs::read_to_string("sample.txt") {
    Ok(s) => s,
    Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
    Err(e) => return Err(e),
};
let lines: Vec<String> = if content.is_empty() {
    vec![String::new()]
} else {
    content.lines().map(|s| s.to_string()).collect()
};

// 保存（末尾改行を落とさないよう注意）
let mut out = lines.join("\n");
if !out.is_empty() {
    out.push('\n');
}
fs::write("sample.txt", out)?;
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **端末サイズ変更 (`Event::Resize`) とペースト (`Event::Paste`)**:
   - `crossterm::event::read()` はキーだけでなく `Event::Resize(cols, rows)` も返すため、`match` で拾って再描画するだけでリサイズ対応が完了します（Bracketed Paste を使う場合は `EnableBracketedPaste` / `DisableBracketedPaste` を併用）。
2. **`content.lines()` と保存時の末尾改行**:
   - `str::lines()` は最後の `\n` を切り捨てるため、保存時に `lines.join("\n")` のまま書き戻すと末尾改行が消えます（空ファイルとの区別や CRLF の正規化も意識するとより堅牢です）。参照実装: [examples/rust/](../examples/rust/) / [examples/tauri-rust/](../examples/tauri-rust/)（Tauri + `xterm.js` 版）。
