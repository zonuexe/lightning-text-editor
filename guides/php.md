# PHP版 クイックリファレンス

PHPはWeb用と思われがちですが、CLI環境でも軽快に動作します。Unix系環境であれば `stty` コマンドを呼ぶことで、Composer不要・単一PHPスクリプトでターミナルエディタが完成します。

---

## ⚡️ クイックスタート

```bash
mkdir my-php-editor && cd my-php-editor
touch editor.php
php editor.php
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```php
<?php
// editor.php

if (!stream_isatty(STDIN) || !stream_isatty(STDOUT)) {
    fwrite(STDERR, "Not a TTY\n");
    exit(1);
}
// stream_select() と fgetc() 併用時のバッファ先読みによる取りこぼしを防止
stream_set_read_buffer(STDIN, 0);

// 元の端末設定を保存してから生モード有効化
// （端末シグナル・Ctrl+V/O/Y の拡張処理・フロー制御・CR->NL変換を無効化）
$origStty = trim((string)shell_exec('stty -g'));
system("stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0");

function cleanup() {
    global $origStty;
    echo "\x1b[2J\x1b[H\x1b[?25h";
    fflush(STDOUT);
    if ($origStty !== '') {
        system('stty ' . escapeshellarg($origStty));
    } else {
        system("stty sane");
    }
}

register_shutdown_function('cleanup');

echo "\x1b[2J\x1b[H\x1b[?25h";
echo "PHPエディタ起動！ Ctrl+Q で終了\r\n";

function readByteTimeout(int $usec = 50000): ?string {
    $read = [STDIN];
    $write = $except = null;
    if (@stream_select($read, $write, $except, 0, $usec) > 0) {
        $ch = fgetc(STDIN);
        return $ch === false ? null : $ch;
    }
    return null;
}

while (true) {
    $c = fgetc(STDIN);
    if ($c === false) {
        break;
    }

    // Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if ($c === "\x11" || $c === "\x03") {
        break;
    }

    // 特殊キー判定（50ms以内に後続が来なければ単独の Esc キー）
    if ($c === "\x1b") {
        $c2 = readByteTimeout(50000);
        if ($c2 === '[') {
            $seq = '';
            while (($ch = readByteTimeout(50000)) !== null) {
                $seq .= $ch;
                $ord = ord($ch);
                if ($ord >= 0x40 && $ord <= 0x7E) { // CSI 終端バイト
                    break;
                }
            }
            switch ($seq) {
                case 'A': /* 上矢印 */ break;
                case 'B': /* 下矢印 */ break;
                case 'C': /* 右矢印 */ break;
                case 'D': /* 左矢印 */ break;
            }
        }
        continue;
    }

    if ($c === "\r" || $c === "\n") {
        // Enter
    } elseif ($c === "\x7f" || $c === "\x08") {
        // Backspace
    } else {
        // 通常の文字入力
    }
}
```

---

## 💾 ファイル保存と読み込み

PHPの標準関数で数行で完結します。

```php
// 読み込み（空ファイルでも [""] になるよう explode を使う。file() は空ファイルで [] を返す）
$filename = "sample.txt";
$text = is_file($filename) ? (string)file_get_contents($filename) : "";
if (str_ends_with($text, "\n")) {
    $text = substr($text, 0, -1); // 末尾の改行を1つだけ外す（末尾の空行は残す）
}
$lines = explode("\n", $text);

// 保存（末尾改行を付けて書き戻す。読み書きを繰り返しても内容が変わらない）
if (file_put_contents($filename, implode("\n", $lines) . "\n") === false) {
    // 保存失敗: 未保存フラグを下ろさず、ステータスバーにエラーを出す
}
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`stream_select` と `fgetc(STDIN)` のバッファリング不整合を防ぐ**:
   - `stream_set_read_buffer(STDIN, 0)` を呼ばずに `fgetc(STDIN)` を実行すると、PHP のストリーム層が 1 チャンクを先読みして `stream_select()` が後続バイトなしと誤認する場合があります。
2. **全角文字幅の計算 (`mb_strwidth()`)**:
   - PHP の `mb_strwidth()` は East Asian Ambiguous 文字（`※`, `α` 等）を**幅 1** として扱います（`mb_strwidth("※") === 1`）。そのため端末が EAW（曖昧幅 = 2）設定の場合にカーソルズレが起きます。EAW 端末では曖昧幅の範囲を自前で幅 2 として数えてください（起動時の DSR プローブ対策は `docs/unicode-and-width.md` および [examples/php/](../examples/php/) を参照）。
3. **シグナル（`SIGINT` / `SIGTERM`）時の端末復元**:
   - `register_shutdown_function` だけでは `SIGTERM` 等で強制終了した際に呼ばれないことがあります。`pcntl_async_signals(true)` + `pcntl_signal()` を併用し、ANSI 復帰と `fflush(STDOUT)` を行ってから `stty` で元設定に戻してください。
