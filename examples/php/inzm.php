#!/usr/bin/env php
<?php
// inzm.php - GNU nano風 伝統的レイアウト＆操作体系のPHP製ターミナルエディタ
mb_internal_encoding('UTF-8');

// --- 1. 状態管理 ---
$filename = $argv[1] ?? 'untitled.php';
$lines = [''];
$cursorX = 0; // 文字単位インデックス
$cursorY = 0; // 行インデックス
$rowOffset = 0;
$isModified = false;
$statusMessage = '';
$cutBuffer = null; // ^K / ^U 用のカットバッファ
$isEaw = true;     // EAW自動検知フラグ

if (file_exists($filename)) {
    $content = file_get_contents($filename);
    $normalized = preg_replace('/\r?\n$/', '', $content);
    $lines = explode("\n", str_replace("\r", "", $normalized));
    if (empty($lines)) $lines = [''];
}

// --- 2. ターミナル制御 & EAW自動検知 (DSRプローブ) ---
system("stty -icanon -echo");
echo "\x1b[?1049h\x1b[2J\x1b[H"; // 代替画面バッファへ

function cleanup() {
    echo "\x1b[?1049l\x1b[?25h";
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

// DSRプローブ: 曖昧文字 'α' を出力してカーソル移動量を測定し、端末がEAWかどうかを動的検知
function probeEaw(): bool {
    echo "\x1b[1;1H\x1b[2Kα\x1b[6n";
    $resp = '';
    stream_set_blocking(STDIN, false);
    $start = microtime(true);
    while (microtime(true) - $start < 0.1) {
        $c = fgetc(STDIN);
        if ($c !== false) {
            $resp .= $c;
            if ($c === 'R') break;
        }
        usleep(5000);
    }
    stream_set_blocking(STDIN, true);
    echo "\x1b[1;1H\x1b[2K"; // 画面を消して元に戻す

    // レスポンス: \x1b[{row};{col}R
    if (preg_match('/\[\d+;(\d+)R/', $resp, $matches)) {
        $col = (int)$matches[1];
        return ($col === 3); // 2マス進んでいればEAW端末！
    }
    return true; // デフォルトはEAWと仮定
}

$isEaw = probeEaw();

// 文字幅判定（EAWなら mb_strwidth、非EAWなら補正）
function getStrWidth(string $str): int {
    global $isEaw;
    if ($isEaw) {
        return mb_strwidth($str, 'UTF-8');
    }
    // 非EAW環境: 確定全角（ひらがな、カタカナ、漢字、全角英数）のみ2、Ambiguous文字は1
    $w = 0;
    $chars = preg_split('//u', $str, -1, PREG_SPLIT_NO_EMPTY);
    foreach ($chars as $ch) {
        $code = mb_ord($ch, 'UTF-8');
        if (($code >= 0x3000 && $code <= 0x9FFF) || ($code >= 0xFF01 && $code <= 0xFF60)) {
            $w += 2;
        } else {
            $w += 1;
        }
    }
    return $w;
}

// --- 3. 画面描画 (GNU nano 3段レイアウト + 2行ヘルプバー) ---
function render() {
    global $lines, $cursorX, $cursorY, $rowOffset, $filename, $isModified, $statusMessage, $isEaw;
    [$cols, $rows] = getWindowSize();

    // nanoのレイアウト:
    // Row 1: タイトルバー
    // Row 2 .. Rows - 3: テキストエリア (screenRows = rows - 4)
    // Row Rows - 2: ステータスライン
    // Row Rows - 1 .. Rows: 2行のショートカットバー
    $screenRows = max(1, $rows - 4);

    if ($cursorY < $rowOffset) $rowOffset = $cursorY;
    if ($cursorY >= $rowOffset + $screenRows) $rowOffset = $cursorY - $screenRows + 1;

    $out = "\x1b[?25l";

    // 1. タイトルバー (Row 1: 反転表示)
    $out .= "\x1b[1;1H\x1b[7m";
    $leftTitle = " ZONU inzm 1.0";
    $centerTitle = "File: " . basename($filename);
    $rightTitle = ($isModified ? "Modified " : "") . ($isEaw ? "[EAW]" : "[Non-EAW]") . " ";

    $totalW = getStrWidth($leftTitle) + getStrWidth($centerTitle) + getStrWidth($rightTitle);
    $space = max(1, $cols - 1 - $totalW);
    $pad1 = (int)($space / 2);
    $pad2 = $space - $pad1;
    $titleBar = $leftTitle . str_repeat(' ', $pad1) . $centerTitle . str_repeat(' ', $pad2) . $rightTitle;
    $out .= mb_strimwidth($titleBar, 0, $cols - 1) . "\x1b[0m\x1b[K";

    // 2. 本文テキストエリア (Row 2 .. Rows - 3)
    for ($i = 0; $i < $screenRows; $i++) {
        $fileRow = $rowOffset + $i;
        $out .= sprintf("\x1b[%d;1H", $i + 2);

        if ($fileRow < count($lines)) {
            $lineNum = sprintf("%3d ", $fileRow + 1);
            $out .= "\x1b[90m" . $lineNum . "\x1b[0m" . $lines[$fileRow] . "\x1b[K";
        } else {
            $out .= "\x1b[90m  ~ \x1b[0m\x1b[K";
        }
    }

    // 3. ステータスライン (Row Rows - 2)
    $out .= sprintf("\x1b[%d;1H", $rows - 2);
    if ($statusMessage) {
        $out .= "\x1b[1;36m[ " . $statusMessage . " ]\x1b[0m\x1b[K";
    } else {
        $out .= "\x1b[K";
    }

    // 4. 伝統的 nano ショートカットバー (Row Rows - 1 & Rows: 2行)
    $shortcutsRow1 = [
        ['^G', 'Get Help'],
        ['^O', 'WriteOut'],
        ['^W', 'Where Is'],
        ['^K', 'Cut'],
        ['^T', 'Execute'],
        ['^X', 'Exit'],
    ];
    $shortcutsRow2 = [
        ['^R', 'Read File'],
        ['^A', 'Home'],
        ['^E', 'End'],
        ['^U', 'Paste'],
        ['^C', 'Location'],
        ['^V', 'Next Page'],
    ];

    $renderShortcutRow = function(array $items, int $rowNum) use ($cols): string {
        $rowStr = sprintf("\x1b[%d;1H", $rowNum);
        $colWidth = (int)(($cols - 1) / count($items));
        foreach ($items as [$key, $desc]) {
            // キーシンボル(^G等)を反転表示、説明文を通常表示
            $entry = "\x1b[7m" . $key . "\x1b[0m " . $desc;
            $entryWidth = getStrWidth($key) + 1 + getStrWidth($desc);
            $padding = max(0, $colWidth - $entryWidth);
            $rowStr .= $entry . str_repeat(' ', $padding);
        }
        return $rowStr . "\x1b[K";
    };

    $out .= $renderShortcutRow($shortcutsRow1, $rows - 1);
    $out .= $renderShortcutRow($shortcutsRow2, $rows);

    // 5. カーソル位置の設定
    $screenY = $cursorY - $rowOffset + 2;
    $currentLine = $lines[$cursorY] ?? '';
    $charsBefore = mb_substr($currentLine, 0, $cursorX);
    $visualX = getStrWidth($charsBefore);
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
    // UTF-8 マルチバイト文字
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

// nano風プロンプト入力
function promptInput(string $prompt, string $default = ''): ?string {
    global $rows;
    [, $rows] = getWindowSize();
    $input = $default;

    while (true) {
        echo sprintf("\x1b[%d;1H\x1b[7m %s \x1b[0m %s\x1b[K", $rows - 2, $prompt, $input);
        $k = readKey();
        if ($k === "\r" || $k === "\n") return $input;
        if ($k === "\x03" || $k === "\x1b" || $k === "\x07") return null; // Cancel (^C, Esc, ^G)
        if ($k === "\x7f" || $k === "\x08") {
            $input = mb_substr($input, 0, -1);
        } elseif (!str_starts_with($k, "\x1b") && $k >= ' ') {
            $input .= $k;
        }
    }
}

// --- 5. nano アクション群 ---

// ^O: WriteOut (保存)
function nanoWriteOut() {
    global $filename, $lines, $isModified, $statusMessage;
    $target = promptInput("File Name to Write:", $filename);
    if ($target === null || trim($target) === '') {
        $statusMessage = "Cancelled";
        return;
    }
    $filename = trim($target);
    file_put_contents($filename, implode("\n", $lines) . "\n");
    $isModified = false;
    $statusMessage = sprintf("Wrote %d lines to %s", count($lines), $filename);
}

// ^T: Execute / Run (PHP実行)
function nanoExecute() {
    global $filename, $lines, $isModified, $statusMessage;
    file_put_contents($filename, implode("\n", $lines) . "\n");
    $isModified = false;

    echo "\x1b[2J\x1b[H\x1b[1;36m=== Execute: php {$filename} ===\x1b[0m\r\n\r\n";
    $output = shell_exec("php " . escapeshellarg($filename) . " 2>&1");
    echo str_replace("\n", "\r\n", $output ?? "(No output)");
    echo "\r\n\r\n\x1b[7m [q] または [Enter] でエディタに戻ります \x1b[0m\r\n";

    while (true) {
        $k = fgetc(STDIN);
        if ($k === 'q' || $k === 'Q' || $k === "\r" || $k === "\n" || $k === "\x1b") break;
    }
    $statusMessage = "Executed " . basename($filename);
}

// --- 6. メインループ ---
render();

while (true) {
    $key = readKey();
    if ($key === '') continue;

    if ($statusMessage) $statusMessage = '';
    $currentLine = $lines[$cursorY] ?? '';
    $currentLen = mb_strlen($currentLine);

    // ==================== nano ショートカット ====================

    // ^X (\x18): Exit (終了)
    if ($key === "\x18") {
        if ($isModified) {
            $ans = promptInput("Save modified buffer? (Y=Yes, N=No, ^C=Cancel):");
            if ($ans === null) {
                $statusMessage = "Cancelled";
                render();
                continue;
            }
            if (strcasecmp($ans, 'y') === 0) {
                file_put_contents($filename, implode("\n", $lines) . "\n");
            } elseif (strcasecmp($ans, 'n') !== 0) {
                $statusMessage = "Cancelled";
                render();
                continue;
            }
        }
        break;
    }

    // ^O (\x0f): WriteOut (保存)
    if ($key === "\x0f") {
        nanoWriteOut();
        render();
        continue;
    }

    // ^T (\x14): Execute (PHP実行)
    if ($key === "\x14") {
        nanoExecute();
        render();
        continue;
    }

    // ^K (\x0b): Cut Text (行カット)
    if ($key === "\x0b") {
        $cutBuffer = $currentLine;
        if (count($lines) > 1) {
            array_splice($lines, $cursorY, 1);
            if ($cursorY >= count($lines)) $cursorY = count($lines) - 1;
        } else {
            $lines[0] = '';
        }
        $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
        $isModified = true;
        $statusMessage = "Cut 1 line";
        render();
        continue;
    }

    // ^U (\x15): Paste / Uncut Text (貼り付け)
    if ($key === "\x15") {
        if ($cutBuffer !== null) {
            array_splice($lines, $cursorY + 1, 0, $cutBuffer);
            $cursorY++;
            $cursorX = 0;
            $isModified = true;
            $statusMessage = "Pasted 1 line";
        } else {
            $statusMessage = "Cutbuffer is empty";
        }
        render();
        continue;
    }

    // ^C (\x03): Location (現在位置表示)
    if ($key === "\x03") {
        $statusMessage = sprintf("line %d/%d (%d%%), col %d/%d (%d%%)",
            $cursorY + 1, count($lines), (int)(($cursorY + 1) / count($lines) * 100),
            $cursorX + 1, $currentLen + 1, (int)(($cursorX + 1) / max(1, $currentLen + 1) * 100)
        );
        render();
        continue;
    }

    // ^G (\x07): Get Help
    if ($key === "\x07") {
        $statusMessage = "nano keys: ^X:Exit, ^O:Write, ^K:Cut, ^U:Paste, ^T:Run, ^W:WhereIs";
        render();
        continue;
    }

    // ^W (\x17): Where Is (簡易検索)
    if ($key === "\x17") {
        $query = promptInput("Search:");
        if ($query) {
            $found = false;
            for ($i = $cursorY; $i < count($lines); $i++) {
                $pos = mb_strpos($lines[$i], $query, ($i === $cursorY ? $cursorX + 1 : 0));
                if ($pos !== false) {
                    $cursorY = $i;
                    $cursorX = $pos;
                    $found = true;
                    $statusMessage = "Found: '{$query}'";
                    break;
                }
            }
            if (!$found) $statusMessage = "'{$query}' not found";
        }
        render();
        continue;
    }

    // ^A (\x01): Home (行頭へ)
    if ($key === "\x01" || $key === "\x1b[H" || $key === "\x1b[1~") {
        $cursorX = 0;
        render();
        continue;
    }

    // ^E (\x05): End (行末へ)
    if ($key === "\x05" || $key === "\x1b[F" || $key === "\x1b[4~") {
        $cursorX = $currentLen;
        render();
        continue;
    }

    // ^Y (\x19) / PageUp: 前のページ
    if ($key === "\x19" || $key === "\x1b[5~" || $key === "\x1b[V") {
        [, $rows] = getWindowSize();
        $cursorY = max(0, $cursorY - ($rows - 4));
        $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
        render();
        continue;
    }

    // ^V (\x16) / PageDown: 次のページ
    if ($key === "\x16" || $key === "\x1b[6~" || $key === "\x1b[U") {
        [, $rows] = getWindowSize();
        $cursorY = min(count($lines) - 1, $cursorY + ($rows - 4));
        $cursorX = min($cursorX, mb_strlen($lines[$cursorY]));
        render();
        continue;
    }

    // ==================== 移動・編集 ====================

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
