#!/usr/bin/env php
<?php
// inzm.php - ミニマル＆モダンなPHP製ターミナルエディタ
mb_internal_encoding('UTF-8');

// --- 1. 状態管理 ---
$filename = $argv[1] ?? 'untitled.php';
$lines = [''];
$cursorX = 0; // mb_strlen インデックス
$cursorY = 0; // 行インデックス
$rowOffset = 0;
$isModified = false;
$statusMessage = '';

if (file_exists($filename)) {
    $content = file_get_contents($filename);
    $normalized = preg_replace('/\r?\n$/', '', $content);
    $lines = explode("\n", str_replace("\r", "", $normalized));
    if (empty($lines)) $lines = [''];
}

// --- 2. ターミナル制御と安全な後始末 ---
system("stty -icanon -echo");
echo "\x1b[?1049h\x1b[2J\x1b[H"; // 代替画面バッファに入る

function cleanup() {
    echo "\x1b[?1049l\x1b[?25h"; // 通常画面に戻してカーソル復帰
    system("stty sane");
}
register_shutdown_function('cleanup');
pcntl_signal(SIGINT, function() { exit(0); });
pcntl_async_signals(true);

function getWindowSize(): array {
    $cols = (int)exec('tput cols') ?: 80;
    $rows = (int)exec('tput lines') ?: 24;
    return [$cols, $rows];
}

// --- 3. 画面描画 ---
function render() {
    global $lines, $cursorX, $cursorY, $rowOffset, $filename, $isModified, $statusMessage;
    [$cols, $rows] = getWindowSize();
    $screenRows = $rows - 1;

    // スクロール調整
    if ($cursorY < $rowOffset) $rowOffset = $cursorY;
    if ($cursorY >= $rowOffset + $screenRows) $rowOffset = $cursorY - $screenRows + 1;

    $out = "\x1b[?25l"; // カーソル非表示

    // 1. 各行の描画
    for ($i = 0; $i < $screenRows; $i++) {
        $fileRow = $rowOffset + $i;
        $out .= sprintf("\x1b[%d;1H", $i + 1);

        if ($fileRow < count($lines)) {
            $lineNum = sprintf("%3d ", $fileRow + 1);
            $out .= "\x1b[90m" . $lineNum . "\x1b[0m" . $lines[$fileRow] . "\x1b[K";
        } else {
            $out .= "\x1b[90m  ~ \x1b[0m\x1b[K";
        }
    }

    // 2. ステータスバー（最下行）
    $out .= sprintf("\x1b[%d;1H", $rows);
    $mod = $isModified ? " [*未保存]" : "";
    $pos = sprintf("Ln %d/%d, Col %d", $cursorY + 1, count($lines), $cursorX + 1);
    $msg = $statusMessage ? " | " . $statusMessage : "";
    $left = " [inzm.php] {$filename}{$mod} | {$pos}{$msg}";
    $right = "Ctrl+R: 実行 | Ctrl+S: 保存 | Ctrl+Q: 終了 ";

    // mb_strwidth で全角文字もピタリと幅計算！
    $maxW = $cols - 1;
    $pad = max(0, $maxW - mb_strwidth($left) - mb_strwidth($right));
    $bar = mb_strimwidth($left . str_repeat(' ', $pad) . $right, 0, $maxW);
    $out .= "\x1b[7m" . $bar . "\x1b[0m\x1b[K";

    // 3. カーソル位置の設定
    $screenY = $cursorY - $rowOffset + 1;
    $currentLine = $lines[$cursorY] ?? '';
    $charsBefore = mb_substr($currentLine, 0, $cursorX);
    $visualX = mb_strwidth($charsBefore);
    $screenX = $visualX + 5; // 行番号幅 (4) + 1

    $out .= sprintf("\x1b[%d;%dH\x1b[?25h", $screenY, $screenX);
    echo $out;
}

// --- 4. キー入力の読み取り ---
function readKey(): string {
    $c = fgetc(STDIN);
    if ($c === false) return '';
    if ($c === "\x1b") {
        stream_set_blocking(STDIN, false);
        $seq = $c;
        while (($next = fgetc(STDIN)) !== false) {
            $seq .= $next;
            if (strlen($seq) >= 3 && preg_match('/[A-Za-z~]/', $next)) break;
        }
        stream_set_blocking(STDIN, true);
        return $seq;
    }
    // UTF-8 マルチバイト文字の読み取り
    $ord = ord($c);
    $bytes = 1;
    if ($ord >= 0xF0) $bytes = 4;
    elseif ($ord >= 0xE0) $bytes = 3;
    elseif ($ord >= 0xC0) $bytes = 2;
    for ($i = 1; $i < $bytes; $i++) {
        $c .= fgetc(STDIN);
    }
    return $c;
}

// --- 5. QuickRun (PHP実行) ---
function runPhp() {
    global $filename, $lines, $isModified, $statusMessage;
    file_put_contents($filename, implode("\n", $lines) . "\n");
    $isModified = false;

    echo "\x1b[2J\x1b[H\x1b[1;36m=== QuickRun: php {$filename} ===\x1b[0m\r\n\r\n";
    $output = shell_exec("php " . escapeshellarg($filename) . " 2>&1");
    echo str_replace("\n", "\r\n", $output ?? "(No output)");
    echo "\r\n\r\n\x1b[7m [q] または [Enter] でエディタに戻ります \x1b[0m\r\n";

    while (true) {
        $k = fgetc(STDIN);
        if ($k === 'q' || $k === 'Q' || $k === "\r" || $k === "\n" || $k === "\x1b") break;
    }
    $statusMessage = "QuickRun 完了";
}

// --- 6. メインループ ---
render();

while (true) {
    $key = readKey();
    if ($key === '') continue;

    if ($statusMessage) $statusMessage = '';
    $currentLine = $lines[$cursorY] ?? '';
    $currentLen = mb_strlen($currentLine);

    // Ctrl+Q (\x11) / Ctrl+C (\x03): 終了
    if ($key === "\x11" || $key === "\x03") break;

    // Ctrl+S (\x13): 保存
    if ($key === "\x13") {
        file_put_contents($filename, implode("\n", $lines) . "\n");
        $isModified = false;
        $statusMessage = "✅ 保存完了！";
        render();
        continue;
    }

    // Ctrl+R (\x12): QuickRun
    if ($key === "\x12") {
        runPhp();
        render();
        continue;
    }

    // 矢印キー移動
    if ($key === "\x1b[A") { // ↑
        if ($cursorY > 0) {
            $cursorY--;
            $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
        }
    } elseif ($key === "\x1b[B") { // ↓
        if ($cursorY < count($lines) - 1) {
            $cursorY++;
            $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
        }
    } elseif ($key === "\x1b[C") { // →
        if ($cursorX < $currentLen) {
            $cursorX++;
        } elseif ($cursorY < count($lines) - 1) {
            $cursorY++;
            $cursorX = 0;
        }
    } elseif ($key === "\x1b[D") { // ←
        if ($cursorX > 0) {
            $cursorX--;
        } elseif ($cursorY > 0) {
            $cursorY--;
            $cursorX = mb_strlen($lines[$cursorY]);
        }
    }
    // PageUp / PageDown
    elseif ($key === "\x1b[5~" || $key === "\x1b[V") {
        [, $rows] = getWindowSize();
        $cursorY = max(0, $cursorY - ($rows - 1));
        $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
    } elseif ($key === "\x1b[6~" || $key === "\x1b[U") {
        [, $rows] = getWindowSize();
        $cursorY = min(count($lines) - 1, $cursorY + ($rows - 1));
        $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
    }
    // Home / End
    elseif ($key === "\x1b[H" || $key === "\x1b[1~" || $key === "\x1bOH") {
        $cursorX = 0;
    } elseif ($key === "\x1b[F" || $key === "\x1b[4~" || $key === "\x1bOF") {
        $cursorX = $currentLen;
    }
    // Enter (改行)
    elseif ($key === "\r" || $key === "\n") {
        $before = mb_substr($currentLine, 0, $cursorX);
        $after = mb_substr($currentLine, $cursorX);
        $lines[$cursorY] = $before;
        array_splice($lines, $cursorY + 1, 0, $after);
        $cursorY++;
        $cursorX = 0;
        $isModified = true;
    }
    // Backspace (削除)
    elseif ($key === "\x7f" || $key === "\x08") {
        if ($cursorX > 0) {
            $before = mb_substr($currentLine, 0, $cursorX - 1);
            $after = mb_substr($currentLine, $cursorX);
            $lines[$cursorY] = $before . $after;
            $cursorX--;
            $isModified = true;
        } elseif ($cursorY > 0) {
            $prevLen = mb_strlen($lines[$cursorY - 1]);
            $lines[$cursorY - 1] .= $currentLine;
            array_splice($lines, $cursorY, 1);
            $cursorY--;
            $cursorX = $prevLen;
            $isModified = true;
        }
    }
    // 通常の文字入力 (日本語・全角・半角)
    elseif (!str_starts_with($key, "\x1b") && $key >= ' ') {
        $before = mb_substr($currentLine, 0, $cursorX);
        $after = mb_substr($currentLine, $cursorX);
        $lines[$cursorY] = $before . $key . $after;
        $cursorX += mb_strlen($key);
        $isModified = true;
    }

    render();
}
