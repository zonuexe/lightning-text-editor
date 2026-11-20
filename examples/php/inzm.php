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
if (!function_exists('stream_isatty') || !stream_isatty(STDIN)) {
    fwrite(STDERR, "エラー: inzm.php は対話型ターミナル (TTY) で実行してください。\n");
    exit(1);
}

$origStty = trim((string)shell_exec('stty -g'));
system("stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0");
echo "\x1b[?1049h\x1b[?2004h\x1b[2J\x1b[H"; // 代替画面バッファ & Bracketed Paste 有効化
fflush(STDOUT);

function setTitle(string $title) {
    echo "\x1b]0;{$title}\x07";
}

$cleanedUp = false;
function cleanup() {
    global $origStty, $cleanedUp;
    if ($cleanedUp) return;
    $cleanedUp = true;
    setTitle("");
    echo "\x1b[?2004l\x1b[?1049l\x1b[?25h\x1b[0m";
    fflush(STDOUT);
    if ($origStty !== '') {
        system('stty ' . escapeshellarg($origStty));
    } else {
        system("stty sane");
    }
}
register_shutdown_function('cleanup');

$needsResize = false;
if (function_exists('pcntl_signal')) {
    pcntl_async_signals(true);
    pcntl_signal(SIGINT, function() { exit(0); });
    pcntl_signal(SIGTERM, function() { exit(0); });
    pcntl_signal(SIGHUP, function() { exit(0); });
    if (defined('SIGWINCH')) {
        pcntl_signal(SIGWINCH, function() use (&$needsResize) {
            $needsResize = true;
        });
    }
}

function getWindowSize(): array {
    $size = trim((string)@shell_exec('stty size < /dev/tty 2>/dev/null'));
    if (preg_match('/^(\d+)\s+(\d+)$/', $size, $m)) {
        return [(int)$m[2], (int)$m[1]];
    }
    $cols = (int)exec('tput cols 2>/dev/null') ?: 80;
    $rows = (int)exec('tput lines 2>/dev/null') ?: 24;
    return [$cols, $rows];
}

$pendingBytes = '';

function readRawByte(?int $timeoutUsec = null): ?string {
    global $pendingBytes, $needsResize;
    if ($pendingBytes !== '') {
        $b = $pendingBytes[0];
        $pendingBytes = substr($pendingBytes, 1);
        return $b;
    }
    while (true) {
        $read = [STDIN];
        $write = $except = null;
        $sec = $timeoutUsec === null ? null : intdiv($timeoutUsec, 1000000);
        $usec = $timeoutUsec === null ? 0 : ($timeoutUsec % 1000000);
        $ready = @stream_select($read, $write, $except, $sec, $usec);
        if ($ready === false) {
            if ($needsResize) {
                return '';
            }
            continue;
        }
        if ($ready === 0) {
            return null;
        }
        $c = fgetc(STDIN);
        return $c === false ? null : $c;
    }
}

// DSRプローブ: カーソル退避＋不可視出力＋先行入力を保持してEAWを動的検知
function probeEaw(): bool {
    global $pendingBytes;
    echo "\x1b7\x1b[1;1H\x1b[2K\x1b[8mα\x1b[6n\x1b[0m";
    fflush(STDOUT);

    $resp = '';
    $deadline = microtime(true) + 0.1;
    while (true) {
        $rem = (int)(($deadline - microtime(true)) * 1000000);
        if ($rem <= 0) break;
        $c = readRawByte($rem);
        if ($c === null) break;
        if ($c === '') continue;
        $resp .= $c;
        if (preg_match('/\x1b\[(\d+);(\d+)R/', $resp, $matches, PREG_OFFSET_CAPTURE)) {
            $offset = $matches[0][1];
            $len = strlen($matches[0][0]);
            $pendingBytes = substr($resp, 0, $offset) . substr($resp, $offset + $len) . $pendingBytes;
            echo "\x1b[1;1H\x1b[2K\x1b8";
            fflush(STDOUT);
            return ((int)$matches[2][0] === 3);
        }
    }
    if ($resp !== '') {
        $pendingBytes = $resp . $pendingBytes;
    }
    echo "\x1b[1;1H\x1b[2K\x1b8";
    fflush(STDOUT);
    return true;
}

$isEaw = probeEaw();

function getCharWidth(string $ch): int {
    global $isEaw;
    $code = mb_ord($ch, 'UTF-8');
    if ($code < 0x20 || $code === 0x7F || ($code >= 0x80 && $code < 0xA0)) {
        return ($code === 0x7F || $code < 0x20) ? 2 : 1; // ^X / ^? 表示幅
    }
    if ($isEaw) {
        return mb_strwidth($ch, 'UTF-8');
    }
    if (($code >= 0x3000 && $code <= 0x9FFF) || ($code >= 0xFF01 && $code <= 0xFF60)) {
        return 2;
    }
    return 1;
}

// 制御文字を無害化し、タブを指定カラムで展開しながら描画文字列・表示幅を算出
function sanitizeAndMeasure(string $str, int $maxCols = PHP_INT_MAX, int $tabWidth = 4): array {
    $out = '';
    $col = 0;
    $str = mb_scrub($str, 'UTF-8');
    $chars = preg_split('//u', $str, -1, PREG_SPLIT_NO_EMPTY);
    if ($chars === false) {
        return ['', 0];
    }
    foreach ($chars as $ch) {
        $code = mb_ord($ch, 'UTF-8');
        if ($ch === "\t") {
            $w = $tabWidth - ($col % $tabWidth);
            $disp = str_repeat(' ', $w);
        } elseif ($code < 0x20) {
            $w = 2;
            $disp = '^' . chr($code + 64);
        } elseif ($code === 0x7F) {
            $w = 2;
            $disp = '^?';
        } elseif ($code >= 0x80 && $code < 0xA0) {
            $w = 1;
            $disp = '?';
        } else {
            $w = getCharWidth($ch);
            $disp = $ch;
        }
        if ($col + $w > $maxCols) {
            break;
        }
        $out .= $disp;
        $col += $w;
    }
    return [$out, $col];
}

// 文字幅判定（EAWなら mb_strwidth、非EAWなら補正）
function getStrWidth(string $str): int {
    [, $w] = sanitizeAndMeasure($str);
    return $w;
}

// --- 3. 画面描画 (GNU nano 3段レイアウト + 2行ヘルプバー) ---
function render() {
    global $lines, $cursorX, $cursorY, $rowOffset, $filename, $isModified, $statusMessage, $isEaw;
    [$cols, $rows] = getWindowSize();

    $modTitle = $isModified ? "*" : "";
    setTitle("ZONU inzm - " . basename($filename) . $modTitle);

    // nanoのレイアウト:
    // Row 1: タイトルバー
    // Row 2 .. Rows - 3: テキストエリア (screenRows = rows - 4)
    // Row Rows - 2: ステータスライン
    // Row Rows - 1 .. Rows: 2行のショートカットバー
    $screenRows = max(1, $rows - 4);

    if ($cursorY < $rowOffset) $rowOffset = $cursorY;
    if ($cursorY >= $rowOffset + $screenRows) $rowOffset = $cursorY - $screenRows + 1;

    $out = "\x1b[?2026h\x1b[?25l";

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
    [$safeTitle] = sanitizeAndMeasure($titleBar, max(1, $cols - 1));
    $out .= $safeTitle . "\x1b[0m\x1b[K";

    // 2. 本文テキストエリア (Row 2 .. Rows - 3)
    $textCols = max(1, $cols - 5);
    for ($i = 0; $i < $screenRows; $i++) {
        $fileRow = $rowOffset + $i;
        $out .= sprintf("\x1b[%d;1H", $i + 2);

        if ($fileRow < count($lines)) {
            $lineNum = sprintf("%3d ", $fileRow + 1);
            [$safeLine] = sanitizeAndMeasure($lines[$fileRow], $textCols);
            $out .= "\x1b[90m" . $lineNum . "\x1b[0m" . $safeLine . "\x1b[K";
        } else {
            $out .= "\x1b[90m  ~ \x1b[0m\x1b[K";
        }
    }

    // 3. ステータスライン (Row Rows - 2)
    $out .= sprintf("\x1b[%d;1H", $rows - 2);
    if ($statusMessage) {
        [$safeMsg] = sanitizeAndMeasure("[ " . $statusMessage . " ]", max(1, $cols - 1));
        $out .= "\x1b[1;36m" . $safeMsg . "\x1b[0m\x1b[K";
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
        $used = 0;
        foreach ($items as [$key, $desc]) {
            // キーシンボル(^G等)を反転表示、説明文を通常表示
            $entry = "\x1b[7m" . $key . "\x1b[0m " . $desc;
            $entryWidth = getStrWidth($key) + 1 + getStrWidth($desc);
            $padding = max(0, $colWidth - $entryWidth);
            if ($used + $entryWidth + $padding > $cols - 1) break;
            $rowStr .= $entry . str_repeat(' ', $padding);
            $used += $entryWidth + $padding;
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
    $screenX = min($cols, $visualX + 5); // 行番号幅 (4) + 1

    $out .= sprintf("\x1b[%d;%dH\x1b[?25h\x1b[?2026l", $screenY, $screenX);
    echo $out;
    fflush(STDOUT);
}

// --- 4. キー入力の読み取り ---
function readKey(): ?string {
    $c = readRawByte(null);
    if ($c === null) return null; // EOF
    if ($c === '') return '';     // WINCH 等で中断

    if ($c === "\x1b") {
        // 50ms以内に後続が来なければ単独の Esc キー
        $c2 = readRawByte(50000);
        if ($c2 === null || $c2 === '') return "\x1b";

        if ($c2 === '[') {
            $seq = "\x1b[";
            while (($next = readRawByte(50000)) !== null && $next !== '') {
                $seq .= $next;
                $ord = ord($next);
                if ($ord >= 0x40 && $ord <= 0x7E) break; // CSI 終端バイト
            }
            return $seq;
        }
        if ($c2 === 'O') {
            $c3 = readRawByte(50000);
            if ($c3 === null || $c3 === '') return "\x1bO";
            return match ($c3) {
                'A' => "\x1b[A",
                'B' => "\x1b[B",
                'C' => "\x1b[C",
                'D' => "\x1b[D",
                'H' => "\x1b[H",
                'F' => "\x1b[F",
                default => "\x1bO" . $c3,
            };
        }
        return "\x1b" . $c2;
    }

    // UTF-8 マルチバイト文字
    $ord = ord($c);
    $bytes = 1;
    if ($ord >= 0xF0 && $ord <= 0xF4) $bytes = 4;
    elseif ($ord >= 0xE0) $bytes = 3;
    elseif ($ord >= 0xC2) $bytes = 2;
    for ($i = 1; $i < $bytes; $i++) {
        $next = readRawByte(50000);
        if ($next === null || $next === '') break;
        $c .= $next;
    }
    return mb_scrub($c, 'UTF-8');
}

function readBracketedPaste(): string {
    $buf = '';
    $endMarker = "\x1b[201~";
    $deadline = microtime(true) + 0.2;
    while (true) {
        $rem = (int)(($deadline - microtime(true)) * 1000000);
        if ($rem <= 0) break;
        $c = readRawByte($rem);
        if ($c === null) break;
        if ($c === '') continue;
        $deadline = microtime(true) + 0.2;
        $buf .= $c;
        if (str_ends_with($buf, $endMarker)) {
            return mb_scrub(substr($buf, 0, -strlen($endMarker)), 'UTF-8');
        }
    }
    return mb_scrub($buf, 'UTF-8');
}

// nano風プロンプト入力
function promptInput(string $prompt, string $default = ''): ?string {
    global $rows, $needsResize;
    [$cols, $rows] = getWindowSize();
    $input = $default;

    while (true) {
        $maxW = max(1, $cols - 1);
        [$safePrompt] = sanitizeAndMeasure(" {$prompt} ", $maxW);
        $availInput = max(0, $cols - 1 - getStrWidth($safePrompt) - 1);
        [$safeInput] = sanitizeAndMeasure($input, $availInput);
        echo sprintf("\x1b[%d;1H\x1b[7m%s\x1b[0m %s\x1b[K", $rows - 2, $safePrompt, $safeInput);
        fflush(STDOUT);

        $k = readKey();
        if ($k === null) return null;
        if ($k === '') {
            if ($needsResize) {
                $needsResize = false;
                [$cols, $rows] = getWindowSize();
            }
            continue;
        }
        if ($k === "\r" || $k === "\n") return $input;
        if ($k === "\x03" || $k === "\x1b" || $k === "\x07") return null; // Cancel (^C, Esc, ^G)
        if ($k === "\x1b[200~") {
            $pasted = readBracketedPaste();
            $pasted = str_replace(["\r\n", "\r"], "\n", $pasted);
            $firstLine = explode("\n", $pasted, 2)[0];
            $clean = preg_replace('/[\x00-\x1F\x7F]/u', '', $firstLine) ?? '';
            $input .= $clean;
            continue;
        }
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
    fflush(STDOUT);

    while (true) {
        $k = readKey();
        if ($k === null || $k === 'q' || $k === 'Q' || $k === "\r" || $k === "\n" || $k === "\x1b") break;
    }
    $statusMessage = "Executed " . basename($filename);
}

// --- 6. メインループ ---
render();

while (true) {
    $key = readKey();
    if ($key === null) break;
    if ($needsResize) {
        $needsResize = false;
        render();
    }
    if ($key === '') continue;

    // Bracketed Paste (\x1b[200~ ... \x1b[201~)
    if ($key === "\x1b[200~") {
        $pasted = readBracketedPaste();
        $pasted = str_replace("\r\n", "\n", $pasted);
        $pasted = str_replace("\r", "\n", $pasted);
        $pasteLines = explode("\n", $pasted);
        $curLine = $lines[$cursorY] ?? '';
        $before = mb_substr($curLine, 0, $cursorX);
        $after = mb_substr($curLine, $cursorX);
        if (count($pasteLines) === 1) {
            $lines[$cursorY] = $before . $pasteLines[0] . $after;
            $cursorX += mb_strlen($pasteLines[0]);
        } else {
            $lines[$cursorY] = $before . $pasteLines[0];
            $mid = array_slice($pasteLines, 1, -1);
            $last = $pasteLines[count($pasteLines) - 1];
            array_splice($lines, $cursorY + 1, 0, array_merge($mid, [$last . $after]));
            $cursorY += count($pasteLines) - 1;
            $cursorX = mb_strlen($last);
        }
        $isModified = true;
        render();
        continue;
    }

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
