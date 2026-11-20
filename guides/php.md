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

$pending = ''; // 読みすぎたバイトを次のキーのために戻しておく

// 1バイト読む。$usec を指定するとその時間内に届かなければ null
function readByte(?int $usec = null): ?string {
    global $pending;
    if ($pending !== '') {
        $b = $pending[0];
        $pending = substr($pending, 1);
        return $b;
    }
    if ($usec !== null) {
        $read = [STDIN];
        $write = $except = null;
        if (@stream_select($read, $write, $except, 0, $usec) < 1) {
            return null;
        }
    }
    $b = fgetc(STDIN);
    return $b === false ? null : $b;
}

function unreadByte(string $b): void {
    global $pending;
    $pending = $b . $pending;
}

// 「1キー分」を返す: 通常文字は UTF-8 の1文字、特殊キーは ESC シーケンス丸ごと
function readKey(): ?string {
    while (true) {
        $b = readByte();
        if ($b === null) {
            return null; // EOF
        }
        if ($b === "\x1b") {
            return readEscape();
        }
        $o = ord($b);
        if ($o < 0x80) {
            return $b;
        }
        // fgetc は1バイトずつ返すので、UTF-8 の先頭バイトから長さを決めて継続バイトを読み足す
        $extra = match (true) {
            $o >= 0xC2 && $o <= 0xDF => 1,
            $o >= 0xE0 && $o <= 0xEF => 2,
            $o >= 0xF0 && $o <= 0xF4 => 3,
            default => 0,
        };
        if ($extra === 0) {
            continue; // 先頭になれないバイトは捨てる
        }
        $s = $b;
        for ($i = 0; $i < $extra; $i++) {
            $c = readByte(50000);
            if ($c === null) {
                break;
            }
            if (ord($c) < 0x80 || ord($c) > 0xBF) {
                unreadByte($c); // 継続バイトでなければ次のキーとして読み直す
                break;
            }
            $s .= $c;
        }
        if (mb_check_encoding($s, 'UTF-8')) {
            return $s;
        }
        // 壊れた UTF-8 は本文に入れずに捨てる
    }
}

// ESC の後ろを読み、単独 Esc・Alt+文字・CSI / SS3 シーケンスを1キーにまとめる
function readEscape(): string {
    $b2 = readByte(50000);
    if ($b2 === null) {
        return "\x1b"; // 50ms 以内に後続が無ければ単独 Esc
    }
    if ($b2 === "\x1b" || ord($b2) >= 0x80) {
        unreadByte($b2); // Esc+矢印・Alt+日本語など: Esc を単独で返し、残りは次のキーにする
        return "\x1b";
    }
    if ($b2 === 'O') { // SS3（F1〜F4 等）は1バイトで終わる
        return "\x1bO" . (readByte(50000) ?? '');
    }
    if ($b2 !== '[') {
        return "\x1b" . $b2; // Alt+文字
    }
    $seq = "\x1b[";
    while (($c = readByte(50000)) !== null) { // CSI は終端バイト（0x40..0x7E）まで読む
        $seq .= $c;
        if (strlen($seq) === 3 && $c === '[') {
            continue; // Linux コンソールの F1〜F5（\x1b[[A 等）
        }
        if (ord($c) >= 0x40 && ord($c) <= 0x7E) {
            break;
        }
    }
    return $seq;
}

while (($key = readKey()) !== null) {
    // Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if ($key === "\x11" || $key === "\x03") {
        break;
    }

    switch ($key) {
        case "\x1b[A": /* 上矢印 */ break;
        case "\x1b[B": /* 下矢印 */ break;
        case "\x1b[C": /* 右矢印 */ break;
        case "\x1b[D": /* 左矢印 */ break;
        case "\x1b":   /* 単独 Esc */ break;
        case "\r":     /* Enter */ break;
        case "\x7f":
        case "\x08":   /* Backspace */ break;
        default:
            if ($key[0] === "\x1b" || ord($key[0]) < 0x20) {
                break; // 未対応の特殊キー・制御文字は本文に入れない
            }
            // 通常の文字入力（$key は UTF-8 の1文字）
    }
}
```

---

## 💾 ファイル保存と読み込み

PHPの標準関数で数行で完結します。

```php
// 読み込み（ファイルが無いときだけ空バッファ。空ファイルでも [""] になるよう explode を使う。file() は空ファイルで [] を返す）
$filename = "sample.txt";
$text = "";
if (file_exists($filename)) {
    $read = @file_get_contents($filename);
    if ($read === false) {
        // 権限不足などで読めないファイルを空バッファで開くと、保存した瞬間に中身が消える
        fwrite(STDERR, "Cannot read {$filename}\n");
        exit(1);
    }
    $text = $read;
}
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
