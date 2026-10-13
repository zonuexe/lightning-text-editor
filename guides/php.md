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

// 生モード有効化（行バッファリング無効 & エコー無効）
system("stty -icanon -echo");

function cleanup() {
    echo "\x1b[2J\x1b[H\x1b[?25h";
    system("stty sane"); // ターミナルを正常状態へ復元
}

register_shutdown_function('cleanup');

cleanup();
echo "PHPエディタ起動！ Ctrl+Q で終了\r\n";

while (true) {
    $c = fgetc(STDIN);

    // Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if ($c === "\x11" || $c === "\x03") {
        break;
    }

    // 特殊キー判定
    if ($c === "\x1b") {
        $c2 = fgetc(STDIN);
        if ($c2 === '[') {
            $c3 = fgetc(STDIN);
            switch ($c3) {
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
