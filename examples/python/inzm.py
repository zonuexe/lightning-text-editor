#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "editorconfig",
# ]
# ///
"""
inzm.py - Zonu's Own Editor (JOE) homage in Python
Respecting the heritage of FSD Amoeba, where JOE was among the notable ported editors.
Supports PEP 723 inline script metadata for isolated execution via `uv run` or `pipx run`.
"""

from __future__ import annotations

import atexit
import codecs
import os
import re
import sys
import tty
import termios
import select
import signal
import time
import shutil
import unicodedata
from collections import deque

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

def sanitize_and_measure(text: str, max_cols: int | None = None, tab_width: int = 4) -> tuple[str, int]:
    out = []
    col = 0
    for c in text:
        code = ord(c)
        if c == "\t":
            w = tab_width - (col % tab_width)
            disp = " " * w
        elif code < 0x20:
            w = 2
            disp = "^" + chr(code + 64)
        elif code == 0x7F:
            w = 2
            disp = "^?"
        elif 0x80 <= code < 0xA0:
            w = 1
            disp = "?"
        else:
            w = get_char_width(c)
            disp = c
        if max_cols is not None and col + w > max_cols:
            break
        out.append(disp)
        col += w
    return "".join(out), col

def get_str_width(text: str) -> int:
    _, w = sanitize_and_measure(text)
    return w

def truncate_to_width(text: str, max_w: int) -> str:
    s, _ = sanitize_and_measure(text, max_cols=max_w)
    return s

raw_buf = bytearray()
pending_chars: deque[str] = deque()
utf8_decoder = codecs.getincrementaldecoder("utf-8")("replace")
eof_reached = False
needs_resize = False
term_requested = False
wake_r: int | None = None
wake_w: int | None = None

def _drain_wakeup_pipe() -> None:
    if wake_r is None:
        return
    while True:
        try:
            if not os.read(wake_r, 1024):
                break
        except (BlockingIOError, InterruptedError, OSError):
            break

def read_char_timeout(timeout: float | None = None) -> str | None:
    """1文字読み取る。EOF時はNone、タイムアウトまたはシグナル起床時は""を返す。"""
    global eof_reached
    if pending_chars:
        return pending_chars.popleft()
    if eof_reached:
        return None

    deadline = None if timeout is None else (time.monotonic() + timeout)
    watch_fds = [fd] if wake_r is None else [fd, wake_r]

    while not pending_chars:
        if raw_buf:
            decoded = utf8_decoder.decode(bytes(raw_buf), final=False)
            raw_buf.clear()
            if decoded:
                pending_chars.extend(decoded)
                break

        if term_requested:
            return None

        wait_time = None if deadline is None else max(0.0, deadline - time.monotonic())
        if deadline is not None and wait_time <= 0.0:
            return ""

        try:
            r, _, _ = select.select(watch_fds, [], [], wait_time)
        except InterruptedError:
            if term_requested:
                return None
            if needs_resize and timeout is None:
                return ""
            continue

        if not r:
            return ""

        if wake_r is not None and wake_r in r:
            _drain_wakeup_pipe()
            if term_requested:
                return None
            if needs_resize and timeout is None and fd not in r:
                return ""

        if fd in r:
            try:
                chunk = os.read(fd, 1024)
            except (BlockingIOError, InterruptedError):
                continue
            if not chunk:
                eof_reached = True
                tail = utf8_decoder.decode(b"", final=True)
                if tail:
                    pending_chars.extend(tail)
                break
            raw_buf.extend(chunk)
            decoded = utf8_decoder.decode(bytes(raw_buf), final=False)
            raw_buf.clear()
            if decoded:
                pending_chars.extend(decoded)

    if pending_chars:
        return pending_chars.popleft()
    return None if eof_reached else ""

def probe_eaw() -> bool:
    """DSRプローブ: カーソル退避＋不可視出力＋先行入力を保持してEAWを動的測定"""
    sys.stdout.write("\x1b7\x1b[1;1H\x1b[2K\x1b[8mα\x1b[6n\x1b[0m")
    sys.stdout.flush()

    resp = ""
    deadline = time.monotonic() + 0.1
    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            break
        ch = read_char_timeout(rem)
        if ch is None or ch == "":
            break
        resp += ch
        m = re.search(r"\x1b\[(\d+);(\d+)R", resp)
        if m:
            rest = resp[:m.start()] + resp[m.end():]
            for c in rest:
                pending_chars.append(c)
            sys.stdout.write("\x1b[1;1H\x1b[2K\x1b8")
            sys.stdout.flush()
            return int(m.group(2)) == 3

    for c in resp:
        pending_chars.append(c)
    sys.stdout.write("\x1b[1;1H\x1b[2K\x1b8")
    sys.stdout.flush()
    return True

# --- 1. 状態管理 & EditorConfig ---
filename = sys.argv[1] if len(sys.argv) > 1 else "untitled.py"
lines = [""]
cursor_x = 0  # 文字インデックス
cursor_y = 0  # 行インデックス
row_offset = 0
is_modified = False
status_message = ""
show_help_window = False
ctrl_k_prefix = False

# EditorConfig の自動解決
ec_config = {}
try:
    from editorconfig import get_properties
    abs_fn = os.path.abspath(filename)
    ec_config = get_properties(abs_fn) or {}
except Exception:
    ec_config = {}

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
if "--test" in sys.argv or "-c" in sys.argv:
    print("inzm.py syntax & imports OK")
    sys.exit(0)
if not sys.stdin.isatty():
    sys.stderr.write("エラー: inzm.py は対話型ターミナル (TTY) で実行してください。\n")
    sys.exit(1)

fd = sys.stdin.fileno()
old_settings = termios.tcgetattr(fd)

def set_title(title: str):
    sys.stdout.write(f"\x1b]0;{title}\x07")
    sys.stdout.flush()

cleaned_up = False

def cleanup():
    global cleaned_up, wake_r, wake_w
    if cleaned_up:
        return
    cleaned_up = True
    try:
        signal.set_wakeup_fd(-1)
    except Exception:
        pass
    for pfd in (wake_r, wake_w):
        if pfd is not None:
            try:
                os.close(pfd)
            except OSError:
                pass
    wake_r = None
    wake_w = None
    try:
        set_title("")
        sys.stdout.write("\x1b[?2004l\x1b[?1049l\x1b[?25h\x1b[0m")
        sys.stdout.flush()
    except OSError:
        try:
            devnull = open(os.devnull, "w")
            sys.stdout = devnull
        except Exception:
            pass
    except Exception:
        pass
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    except termios.error:
        pass

def _on_term_sig(_signum, _frame):
    global term_requested
    term_requested = True

def _on_winch(_signum, _frame):
    global needs_resize
    needs_resize = True

wake_r, wake_w = os.pipe()
os.set_blocking(wake_r, False)
os.set_blocking(wake_w, False)
signal.set_wakeup_fd(wake_w, warn_on_full_buffer=False)

signal.signal(signal.SIGTERM, _on_term_sig)
signal.signal(signal.SIGHUP, _on_term_sig)
if hasattr(signal, "SIGWINCH"):
    signal.signal(signal.SIGWINCH, _on_winch)

atexit.register(cleanup)

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
    out.append("\x1b[?2026h\x1b[?25l") # 同期描画開始 & カーソル非表示

    # 1. 最上行 (Row 1): JOE伝統の反転ステータスライン
    out.append("\x1b[1;1H\x1b[7m")
    mod_mark = "*" if is_modified else " "
    base_name = os.path.basename(filename)
    cur_time = time.strftime("%H:%M")
    eaw_str = "EAW" if is_eaw else "Non-EAW"

    # EditorConfig インジケータ
    ec_ind = ec_config.get("indent_style", "space")
    ec_size = ec_config.get("indent_size", "4")
    ec_eol = ec_config.get("end_of_line", "lf")
    ec_label = f" [EC:{ec_size}sp,{ec_eol}]" if ec_ind == "space" else f" [EC:tab,{ec_eol}]"

    max_w = max(1, cols - 1)
    left_plain = f" {mod_mark}{base_name}  ({eaw_str}){ec_label}"
    safe_left, left_w = sanitize_and_measure(left_plain, max_cols=max_w)
    rem_w = max_w - left_w

    prefix_styled = ""
    if ctrl_k_prefix and rem_w > 0:
        safe_prefix, prefix_w = sanitize_and_measure(" ^K_", max_cols=rem_w)
        if safe_prefix:
            if safe_prefix.startswith(" "):
                prefix_styled = " \x1b[1;33m" + safe_prefix[1:] + "\x1b[0m\x1b[7m"
            else:
                prefix_styled = "\x1b[1;33m" + safe_prefix + "\x1b[0m\x1b[7m"
            rem_w -= prefix_w

    mid_part = f"Row {cursor_y + 1}   Col {cursor_x + 1}   {cur_time} "
    right_part = status_message if status_message else "Ctrl+K H for help "
    tail_plain = mid_part + right_part
    safe_tail, tail_w = sanitize_and_measure(tail_plain)
    if tail_w + 1 <= rem_w:
        pad = rem_w - tail_w
        bar_out = safe_left + prefix_styled + (" " * pad) + safe_tail
    else:
        pad = 1 if rem_w > 1 else 0
        avail_tail = max(0, rem_w - pad)
        safe_tail, _ = sanitize_and_measure(tail_plain, max_cols=avail_tail)
        bar_out = safe_left + prefix_styled + (" " * pad) + safe_tail
    out.append(bar_out + "\x1b[0m\x1b[K")

    # 2. ヘルプウィンドウ (Ctrl+K H でニョキッと出るJOE名物)
    if show_help_window:
        help_text = [
            "\\K D Save      \\K X Save&Exit  \\K Q Abort      \\K H Help off ",
            "^B Left        ^F Right        ^P Up           ^N Down       ",
            "^A Line start  ^E Line end     ^U Prev Page    ^V Next Page  ",
            "^Y Kill line   ^C Abort/Exit   BackSpace Delete char          ",
        ]
        for idx, hline in enumerate(help_text):
            safe_hline = truncate_to_width(hline, max_w)
            out.append(f"\x1b[{2 + idx};1H\x1b[36m{safe_hline}\x1b[0m\x1b[K")

    # 3. 本文テキストエリア
    text_cols = max(1, cols - 5)
    for i in range(screen_rows):
        file_row = row_offset + i
        row_pos = text_start_row + i
        out.append(f"\x1b[{row_pos};1H")

        if file_row < len(lines):
            line_num = f"{file_row + 1:3d} "
            safe_line, _ = sanitize_and_measure(lines[file_row], max_cols=text_cols)
            out.append(f"\x1b[90m{line_num}\x1b[0m{safe_line}\x1b[K")
        else:
            out.append("\x1b[90m  ~ \x1b[0m\x1b[K")

    # 4. 最下行 (Row rows): 起動時バナー（反転表示）または通常メッセージ
    out.append(f"\x1b[{rows};1H")
    if banner_message:
        # ご指定のバナーメッセージ（画面下端左端に背景色反転で表示）
        out.append(f"\x1b[7m{truncate_to_width(banner_message, max_w)}\x1b[0m\x1b[K")
    else:
        out.append("\x1b[K")

    # 5. カーソル位置の設定
    screen_y = text_start_row + (cursor_y - row_offset)
    current_line = lines[cursor_y] if cursor_y < len(lines) else ""
    chars_before = current_line[:cursor_x]
    visual_x = get_str_width(chars_before)
    screen_x = min(cols, visual_x + 5) # 行番号 (4) + 1

    out.append(f"\x1b[{screen_y};{screen_x}H\x1b[?25h\x1b[?2026l")
    sys.stdout.write("".join(out))
    sys.stdout.flush()

# --- 4. キー入力の読み取り ---
def read_key() -> str | None:
    ch = read_char_timeout(None)
    if ch is None:
        return None
    if ch == "":
        return ""
    if ch == "\x1b":
        # エスケープシーケンス（50ms以内に来なければ単独Esc）
        ch2 = read_char_timeout(0.05)
        if ch2 is None or ch2 == "":
            return "\x1b"
        if ch2 == "[":
            seq = "\x1b["
            while True:
                c = read_char_timeout(0.05)
                if c is None or c == "":
                    break
                seq += c
                if 0x40 <= ord(c) <= 0x7E:
                    break
            return seq
        if ch2 == "O":
            c3 = read_char_timeout(0.05)
            if c3 is None or c3 == "":
                return "\x1bO"
            ss3_map = {"A": "\x1b[A", "B": "\x1b[B", "C": "\x1b[C", "D": "\x1b[D", "H": "\x1b[H", "F": "\x1b[F"}
            return ss3_map.get(c3, "\x1bO" + c3)
        return "\x1b" + ch2
    return ch

def read_bracketed_paste() -> str:
    buf = []
    end_marker = "\x1b[201~"
    tail = ""
    while not term_requested:
        c = read_char_timeout(0.2)
        if c is None or c == "":
            break
        buf.append(c)
        tail = (tail + c)[-len(end_marker):]
        if tail == end_marker:
            full = "".join(buf)
            return full[:-len(end_marker)]
    return "".join(buf)

# --- 5. 保存と終了 (EditorConfig ルール適用) ---
def save_file():
    global is_modified, status_message, lines
    try:
        lines_to_save = list(lines)

        # 1. trim_trailing_whitespace
        if ec_config.get("trim_trailing_whitespace") == "true":
            lines_to_save = [l.rstrip(" \t") for l in lines_to_save]
            lines = list(lines_to_save)

        # 2. end_of_line
        eol = "\r\n" if ec_config.get("end_of_line") == "crlf" else "\n"
        content = eol.join(lines_to_save)

        # 3. insert_final_newline
        if ec_config.get("insert_final_newline") != "false":
            content += eol

        with open(filename, "w", encoding=ec_config.get("charset", "utf-8")) as f:
            f.write(content)
        is_modified = False
        status_message = f"File {filename} saved [EC applied]"
    except Exception as e:
        status_message = f"Error: {e}"

# --- 6. メインループ ---
try:
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?2004h\x1b[2J\x1b[H") # 代替画面バッファ & Bracketed Paste 有効化
    sys.stdout.flush()

    is_eaw = probe_eaw()
    render()

    while not term_requested:
        key = read_key()
        if term_requested or key is None:
            break
        if needs_resize:
            needs_resize = False
            render()
        if key == "":
            continue

        # Bracketed Paste (\x1b[200~ ... \x1b[201~)
        if key == "\x1b[200~":
            pasted = read_bracketed_paste().replace("\r\n", "\n").replace("\r", "\n")
            paste_lines = pasted.split("\n")
            cur_line = lines[cursor_y] if cursor_y < len(lines) else ""
            before = cur_line[:cursor_x]
            after = cur_line[cursor_x:]
            if len(paste_lines) == 1:
                lines[cursor_y] = before + paste_lines[0] + after
                cursor_x += len(paste_lines[0])
            else:
                lines[cursor_y] = before + paste_lines[0]
                for idx, mid in enumerate(paste_lines[1:-1], start=1):
                    lines.insert(cursor_y + idx, mid)
                last = paste_lines[-1]
                lines.insert(cursor_y + len(paste_lines) - 1, last + after)
                cursor_y += len(paste_lines) - 1
                cursor_x = len(last)
            is_modified = True
            render()
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

        # Tab キー (EditorConfig indent_style / indent_size 準拠)
        elif key == "\t":
            if ec_config.get("indent_style") == "tab":
                indent_str = "\t"
            else:
                try:
                    size = int(ec_config.get("indent_size", "4"))
                except ValueError:
                    size = 4
                indent_str = " " * size
            lines[cursor_y] = current_line[:cursor_x] + indent_str + current_line[cursor_x:]
            cursor_x += len(indent_str)
            is_modified = True

        # 通常の文字入力 (全角・半角・UTF-8)
        elif not key.startswith("\x1b") and key >= " ":
            lines[cursor_y] = current_line[:cursor_x] + key + current_line[cursor_x:]
            cursor_x += len(key)
            is_modified = True

        render()

finally:
    cleanup()
