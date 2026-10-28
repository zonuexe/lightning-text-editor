#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inzm.py - Zonu's Own Editor (JOE) homage in Python
Respecting the heritage of FSD Amoeba, where JOE was among the notable ported editors.
"""

import os
import sys
import tty
import termios
import select
import time
import shutil
import unicodedata

# --- 0. 文字幅計算 & DSRプローブ (EAW自動検知) ---
is_eaw = True

def get_char_width(char: str) -> int:
    code = ord(char)
    # 1. 確定全角 (Wide / Fullwidth)
    if (0x1100 <= code <= 0x115F or
        0x2E80 <= code <= 0xA4CF or
        0xAC00 <= code <= 0xD7A3 or
        0xF900 <= code <= 0xFAFF or
        0xFE10 <= code <= 0xFE19 or
        0xFE30 <= code <= 0xFE6F or
        0xFF01 <= code <= 0xFF60 or
        0xFFE0 <= code <= 0xFFE6):
        return 2

    # 2. 東アジア曖昧幅 (Ambiguous Width: ギリシャ、キリル、記号など)
    if (0x0370 <= code <= 0x03FF or
        0x0400 <= code <= 0x04FF or
        0x2010 <= code <= 0x205E or
        0x2100 <= code <= 0x214F or
        0x2190 <= code <= 0x21FF or
        0x2200 <= code <= 0x22FF or
        0x25A0 <= code <= 0x25FF or
        0x2600 <= code <= 0x26FF):
        return 2 if is_eaw else 1

    return 1

def get_str_width(text: str) -> int:
    return sum(get_char_width(c) for c in text)

def truncate_to_width(text: str, max_w: int) -> str:
    cur_w = 0
    res = []
    for c in text:
        w = get_char_width(c)
        if cur_w + w > max_w:
            break
        res.append(c)
        cur_w += w
    return "".join(res)

def probe_eaw() -> bool:
    """DSRプローブ: 端末が曖昧文字を幅2で描画しているか動的測定"""
    sys.stdout.write("\x1b[1;1H\x1b[2Kα\x1b[6n")
    sys.stdout.flush()

    resp = ""
    start_t = time.time()
    while time.time() - start_t < 0.1:
        r, _, _ = select.select([sys.stdin], [], [], 0.01)
        if r:
            ch = sys.stdin.read(1)
            resp += ch
            if ch == "R":
                break

    sys.stdout.write("\x1b[1;1H\x1b[2K")
    sys.stdout.flush()

    if ";3R" in resp:
        return True
    elif ";2R" in resp:
        return False
    return True

# --- 1. 状態管理 ---
filename = sys.argv[1] if len(sys.argv) > 1 else "untitled.py"
lines = [""]
cursor_x = 0  # 文字インデックス
cursor_y = 0  # 行インデックス
row_offset = 0
is_modified = false if False else False
status_message = ""
show_help_window = False
ctrl_k_prefix = False

# 起動直後のバナーメッセージ（画面下端左端に反転表示、何らかの操作で消滅）
banner_message = "** Zonu's Own Editor v4.1 ** <utf-8> ** Copyright (C) 2026 **"

if os.path.exists(filename):
    with open(filename, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    normalized = content.rstrip("\r\n")
    lines = normalized.replace("\r", "").split("\n")
    if not lines:
        lines = [""]

# --- 2. ターミナル生モード & 後始末 ---
fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)

def set_title(title: str):
    sys.stdout.write(f"\x1b]0;{title}\x07")
    sys.stdout.flush()

def cleanup():
    set_title("")
    sys.stdout.write("\x1b[?1049l\x1b[?25h")
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

tty.setraw(fd)
sys.stdout.write("\x1b[?1049h\x1b[2J\x1b[H") # 代替画面バッファへ
sys.stdout.flush()

is_eaw = probe_eaw()

def get_window_size():
    cols, rows = shutil.get_terminal_size(fallback=(80, 24))
    return cols, rows

# --- 3. 画面描画 (JOE スタイル: 最上行ステータスライン & ヘルプウィンドウ) ---
def render():
    global row_offset, banner_message
    cols, rows = get_window_size()

    mod_flag = "*" if is_modified else ""
    set_title(f"ZOE - {os.path.basename(filename)}{mod_flag}")

    # JOE の画面構成:
    # Row 1: ステータスライン (反転表示: *file.py  Row 1  Col 1  14:30  Ctrl+K H for help)
    # [Option] Row 2..5: ヘルプウィンドウ (Ctrl+K H でトグル)
    # Row 2 (or 6) .. Rows - 1: テキストエリア
    # Row Rows: 画面最下行（起動時バナー、またはメッセージエリア）
    
    help_rows = 4 if show_help_window else 0
    text_start_row = 2 + help_rows
    screen_rows = max(1, rows - text_start_row) # 最下行をメッセージ用に1行空ける

    if cursor_y < row_offset:
        row_offset = cursor_y
    if cursor_y >= row_offset + screen_rows:
        row_offset = cursor_y - screen_rows + 1

    out = []
    out.append("\x1b[?25l") # カーソル非表示

    # 1. 最上行 (Row 1): JOE伝統の反転ステータスライン
    out.append("\x1b[1;1H\x1b[7m")
    mod_mark = "*" if is_modified else " "
    base_name = os.path.basename(filename)
    cur_time = time.strftime("%H:%M")
    eaw_str = "EAW" if is_eaw else "Non-EAW"

    prefix_str = " \x1b[1;33m^K_\x1b[0m\x1b[7m" if ctrl_k_prefix else ""
    left_part = f" {mod_mark}{base_name}  ({eaw_str}){prefix_str}"
    mid_part = f"Row {cursor_y + 1}   Col {cursor_x + 1}   {cur_time} "
    right_part = status_message if status_message else "Ctrl+K H for help "

    max_w = cols - 1
    total_w = get_str_width(left_part) + get_str_width(mid_part) + get_str_width(right_part)
    pad = max(1, max_w - total_w)
    status_bar = left_part + " " * pad + mid_part + right_part
    out.append(truncate_to_width(status_bar, max_w) + "\x1b[0m\x1b[K")

    # 2. ヘルプウィンドウ (Ctrl+K H でニョキッと出るJOE名物)
    if show_help_window:
        help_text = [
            "\\K D Save      \\K X Save&Exit  \\K Q Abort      \\K H Help off ",
            "^B Left        ^F Right        ^P Up           ^N Down       ",
            "^A Line start  ^E Line end     ^U Prev Page    ^V Next Page  ",
            "^Y Kill line   ^C Abort/Exit   BackSpace Delete char          ",
        ]
        for idx, hline in enumerate(help_text):
            out.append(f"\x1b[{2 + idx};1H\x1b[36m{hline}\x1b[0m\x1b[K")

    # 3. 本文テキストエリア
    for i in range(screen_rows):
        file_row = row_offset + i
        row_pos = text_start_row + i
        out.append(f"\x1b[{row_pos};1H")

        if file_row < len(lines):
            line_num = f"{file_row + 1:3d} "
            out.append(f"\x1b[90m{line_num}\x1b[0m{lines[file_row]}\x1b[K")
        else:
            out.append("\x1b[90m  ~ \x1b[0m\x1b[K")

    # 4. 最下行 (Row rows): 起動時バナー（反転表示）または通常メッセージ
    out.append(f"\x1b[{rows};1H")
    if banner_message:
        # ご指定のバナーメッセージ（画面下端左端に背景色反転で表示）
        out.append(f"\x1b[7m{banner_message}\x1b[0m\x1b[K")
    else:
        out.append("\x1b[K")

    # 5. カーソル位置の設定
    screen_y = text_start_row + (cursor_y - row_offset)
    current_line = lines[cursor_y] if cursor_y < len(lines) else ""
    chars_before = current_line[:cursor_x]
    visual_x = get_str_width(chars_before)
    screen_x = visual_x + 5 # 行番号 (4) + 1

    out.append(f"\x1b[{screen_y};{screen_x}H\x1b[?25h")
    sys.stdout.write("".join(out))
    sys.stdout.flush()

# --- 4. キー入力の読み取り ---
def read_key():
    ch = sys.stdin.read(1)
    if ch == "\x1b":
        # エスケープシーケンス
        r, _, _ = select.select([sys.stdin], [], [], 0.05)
        if not r:
            return "\x1b"
        ch2 = sys.stdin.read(1)
        if ch2 == "[":
            seq = "\x1b["
            while True:
                r, _, _ = select.select([sys.stdin], [], [], 0.05)
                if not r:
                    break
                c = sys.stdin.read(1)
                seq += c
                if len(seq) >= 3 and c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ~":
                    break
            return seq
        return "\x1b" + ch2
    return ch

# --- 5. 保存と終了 ---
def save_file():
    global is_modified, status_message
    try:
        content = "\n".join(lines) + "\n"
        with open(filename, "w", encoding="utf-8") as f:
            f.write(content)
        is_modified = False
        status_message = f"File {filename} saved"
    except Exception as e:
        status_message = f"Error: {e}"

# --- 6. メインループ ---
try:
    render()

    while True:
        key = read_key()
        if not key:
            continue

        # 何らかのキー操作が行われたら、起動バナーメッセージを消滅させる
        if banner_message:
            banner_message = ""

        if status_message and not ctrl_k_prefix:
            status_message = ""

        current_line = lines[cursor_y] if cursor_y < len(lines) else ""

        # ==================== Ctrl+K プレフィックスモード ====================
        if ctrl_k_prefix:
            ctrl_k_prefix = False
            k_lower = key.lower()

            # Ctrl+K D / Ctrl+K S: 保存
            if k_lower in ("d", "s", "\x04", "\x13"):
                save_file()
                render()
                continue
            # Ctrl+K X: 保存して終了
            elif k_lower in ("x", "\x18"):
                save_file()
                break
            # Ctrl+K Q: 破棄して終了
            elif k_lower in ("q", "\x11"):
                break
            # Ctrl+K H: ヘルプウィンドウのトグル
            elif k_lower in ("h", "\x08"):
                show_help_window = not show_help_window
                render()
                continue
            else:
                status_message = f"Unknown key ^K {key}"
                render()
                continue

        # ==================== 通常モード ====================

        # Ctrl+K (\x0b): プレフィックス開始
        if key == "\x0b":
            ctrl_k_prefix = True
            render()
            continue

        # Ctrl+C (\x03): 終了 (未保存時は警告)
        if key == "\x03":
            if is_modified:
                status_message = "File modified. Use ^K Q to quit"
                render()
                continue
            break

        # Ctrl+Y (\x19): 行キル（現在行削除）
        if key == "\x19":
            if len(lines) > 1:
                lines.pop(cursor_y)
                if cursor_y >= len(lines):
                    cursor_y = len(lines) - 1
            else:
                lines[0] = ""
            cursor_x = min(cursor_x, len(lines[cursor_y]))
            is_modified = True
            status_message = "Line killed"
            render()
            continue

        # --- ナビゲーション ---
        # 矢印キー & Emacs/JOE移動キー (^P, ^N, ^F, ^B)
        if key in ("\x1b[A", "\x10"):  # Up / ^P
            if cursor_y > 0:
                cursor_y -= 1
                cursor_x = min(cursor_x, len(lines[cursor_y]))
        elif key in ("\x1b[B", "\x0e"):  # Down / ^N
            if cursor_y < len(lines) - 1:
                cursor_y += 1
                cursor_x = min(cursor_x, len(lines[cursor_y]))
        elif key in ("\x1b[C", "\x06"):  # Right / ^F
            if cursor_x < len(current_line):
                cursor_x += 1
            elif cursor_y < len(lines) - 1:
                cursor_y += 1
                cursor_x = 0
        elif key in ("\x1b[D", "\x02"):  # Left / ^B
            if cursor_x > 0:
                cursor_x -= 1
            elif cursor_y > 0:
                cursor_y -= 1
                cursor_x = len(lines[cursor_y])
        # ^A / Home: 行頭
        elif key in ("\x01", "\x1b[H", "\x1b[1~"):
            cursor_x = 0
        # ^E / End: 行末
        elif key in ("\x05", "\x1b[F", "\x1b[4~"):
            cursor_x = len(current_line)
        # ^U / PageUp: 前画面
        elif key in ("\x15", "\x1b[5~", "\x1b[V"):
            _, rows = get_window_size()
            s_rows = max(1, rows - (6 if show_help_window else 2))
            cursor_y = max(0, cursor_y - s_rows)
            cursor_x = min(cursor_x, len(lines[cursor_y]))
        # ^V / PageDown: 次画面
        elif key in ("\x16", "\x1b[6~", "\x1b[U"):
            _, rows = get_window_size()
            s_rows = max(1, rows - (6 if show_help_window else 2))
            cursor_y = min(len(lines) - 1, cursor_y + s_rows)
            cursor_x = min(cursor_x, len(lines[cursor_y]))

        # --- 編集 ---
        # Enter (改行)
        elif key in ("\r", "\n"):
            before = current_line[:cursor_x]
            after = current_line[cursor_x:]
            lines[cursor_y] = before
            lines.insert(cursor_y + 1, after)
            cursor_y += 1
            cursor_x = 0
            is_modified = True

        # Backspace (削除)
        elif key in ("\x7f", "\x08"):
            if cursor_x > 0:
                lines[cursor_y] = current_line[:cursor_x - 1] + current_line[cursor_x:]
                cursor_x -= 1
                is_modified = True
            elif cursor_y > 0:
                prev_len = len(lines[cursor_y - 1])
                lines[cursor_y - 1] += current_line
                lines.pop(cursor_y)
                cursor_y -= 1
                cursor_x = prev_len
                is_modified = True

        # 通常の文字入力 (全角・半角・UTF-8)
        elif not key.startswith("\x1b") and key >= " ":
            lines[cursor_y] = current_line[:cursor_x] + key + current_line[cursor_x:]
            cursor_x += len(key)
            is_modified = True

        render()

finally:
    cleanup()
