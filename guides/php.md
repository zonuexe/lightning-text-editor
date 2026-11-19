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

// 元の端末設定を保存してから生モード有効化（フロー制御・CR->NL変換・端末シグナルを無効化）
$origStty = trim((string)shell_exec('stty -g'));
system("stty -icanon -echo -ixon -icrnl intr undef quit undef susp undef");

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

PHPの標準関数で1行で完結します。

```php
// 読み込み
$filename = "sample.txt";
$lines = file_exists($filename) ? file($filename, FILE_IGNORE_NEW_LINES) : [""];

// 保存
file_put_contents($filename, implode("\n", $lines));
```
