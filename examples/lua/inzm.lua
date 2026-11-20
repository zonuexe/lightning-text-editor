#!/usr/bin/env lua
-- inzm.lua - micro homage in full Lua
-- Micro was originally written in Go and extensible via Lua,
-- but here we implement the entire editor in pure, elegant Lua!

local utf8 = utf8 or require("utf8")

-- =============================================================================
-- 0. Terminal Control & DSR EAW Probe
-- =============================================================================
local is_eaw = true

local function char_width(code)
    -- 1. Wide / Fullwidth
    if (code >= 0x1100 and code <= 0x115F) or
       (code >= 0x2E80 and code <= 0xA4CF) or
       (code >= 0xAC00 and code <= 0xD7A3) or
       (code >= 0xF900 and code <= 0xFAFF) or
       (code >= 0xFE10 and code <= 0xFE19) or
       (code >= 0xFE30 and code <= 0xFE6F) or
       (code >= 0xFF01 and code <= 0xFF60) or
       (code >= 0xFFE0 and code <= 0xFFE6) then
        return 2
    end

    -- 2. Ambiguous Width
    if (code >= 0x0370 and code <= 0x03FF) or
       (code >= 0x0400 and code <= 0x04FF) or
       (code >= 0x2010 and code <= 0x205E) or
       (code >= 0x2100 and code <= 0x214F) or
       (code >= 0x2190 and code <= 0x21FF) or
       (code >= 0x2200 and code <= 0x22FF) or
       (code >= 0x25A0 and code <= 0x25FF) or
       (code >= 0x2600 and code <= 0x26FF) then
        return is_eaw and 2 or 1
    end

    return 1
end

local function utf8_codepoints(s)
    local cps = {}
    local n = #s
    local i = 1
    while i <= n do
        local b1 = s:byte(i)
        if b1 < 0x80 then
            table.insert(cps, b1)
            i = i + 1
        elseif b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= n then
            local b2 = s:byte(i + 1)
            if b2 >= 0x80 and b2 <= 0xBF then
                table.insert(cps, ((b1 - 0xC0) * 64) + (b2 - 0x80))
                i = i + 2
            else
                table.insert(cps, 0xFFFD)
                i = i + 1
            end
        elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= n then
            local b2, b3 = s:byte(i + 1, i + 2)
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
               and not (b1 == 0xE0 and b2 < 0xA0)
               and not (b1 == 0xED and b2 >= 0xA0) then
                table.insert(cps, ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80))
                i = i + 3
            else
                table.insert(cps, 0xFFFD)
                i = i + 1
            end
        elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= n then
            local b2, b3, b4 = s:byte(i + 1, i + 3)
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF
               and not (b1 == 0xF0 and b2 < 0x90)
               and not (b1 == 0xF4 and b2 > 0x8F) then
                table.insert(cps, ((b1 - 0xF0) * 262144) + ((b2 - 0x80) * 4096) + ((b3 - 0x80) * 64) + (b4 - 0x80))
                i = i + 4
            else
                table.insert(cps, 0xFFFD)
                i = i + 1
            end
        else
            table.insert(cps, 0xFFFD)
            i = i + 1
        end
    end
    return cps
end

local function scrub_utf8(s)
    local out = {}
    for _, code in ipairs(utf8_codepoints(s)) do
        table.insert(out, utf8.char(code))
    end
    return table.concat(out)
end

local function utf8_char_count(s)
    return #utf8_codepoints(s)
end

local function sanitize_codepoint(code, col, tab_width)
    if code == 9 then
        local cw = tab_width - (col % tab_width)
        return cw, string.rep(" ", cw)
    elseif code < 0x20 then
        return 2, "^" .. string.char(code + 64)
    elseif code == 0x7F then
        return 2, "^?"
    elseif code >= 0x80 and code < 0xA0 then
        return 1, "?"
    else
        return char_width(code), utf8.char(code)
    end
end

local function sanitize_and_measure(s, max_w, tab_width)
    tab_width = tab_width or 4
    local col = 0
    local res = {}
    for _, code in ipairs(utf8_codepoints(s)) do
        local cw, disp = sanitize_codepoint(code, col, tab_width)
        if max_w and col + cw > max_w then break end
        table.insert(res, disp)
        col = col + cw
    end
    return table.concat(res), col
end

local function str_width(s)
    local _, w = sanitize_and_measure(s)
    return w
end

local function truncate_str(s, max_w)
    local out = sanitize_and_measure(s, max_w)
    return out
end

local function set_title(title)
    io.write(string.format("\27]0;%s\7", title))
    io.flush()
end

local orig_stty = nil
local function set_tty_vtime(vtime)
    if vtime and vtime > 0 then
        os.execute(string.format("stty min 0 time %d < /dev/tty 2>/dev/null || stty min 0 time %d 2>/dev/null", vtime, vtime))
    else
        os.execute("stty min 1 time 0 < /dev/tty 2>/dev/null || stty min 1 time 0 2>/dev/null")
    end
end

local function with_tty_vtime(vtime, fn)
    set_tty_vtime(vtime)
    local ok, res = pcall(fn)
    set_tty_vtime(0)
    if not ok then error(res) end
    return res
end

local function set_raw_mode(enable)
    if enable then
        if not orig_stty then
            local h = io.popen("stty -g < /dev/tty 2>/dev/null")
            if h then
                local saved = h:read("*a")
                h:close()
                if saved then
                    saved = saved:gsub("%s+$", "")
                    if saved ~= "" then orig_stty = saved end
                end
            end
        end
        io.stdin:setvbuf("no")
        -- -isig: Ctrl+C/Z/\ を文字として受信, -iexten: ^O/^V/^Y等の拡張文字無効化, -ixon: Ctrl+S/Q フロー制御無効化, -icrnl: CR->NL変換無効化
        os.execute("stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0 < /dev/tty 2>/dev/null || stty -icanon -echo -isig -iexten -ixon -icrnl min 1 time 0 2>/dev/null")
    else
        if orig_stty then
            os.execute("stty '" .. orig_stty:gsub("'", "'\\''") .. "' < /dev/tty 2>/dev/null || stty sane 2>/dev/null")
        else
            os.execute("stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null")
        end
    end
end

local function get_window_size()
    local handle = io.popen("stty size < /dev/tty 2>/dev/null || echo '24 80'")
    if handle then
        local res = handle:read("*a")
        handle:close()
        local rows, cols = res:match("(%d+)%s+(%d+)")
        if rows and cols then
            return tonumber(cols), tonumber(rows)
        end
    end
    return 80, 24
end

local pending_bytes = ""

local function read_raw_byte()
    if #pending_bytes > 0 then
        local b = pending_bytes:sub(1, 1)
        pending_bytes = pending_bytes:sub(2)
        return b
    end
    return io.read(1)
end

local function probe_eaw()
    io.write("\0277\27[1;1H\27[2K\27[8mα\27[6n\27[0m")
    io.flush()

    local resp = ""
    local found_col = nil
    with_tty_vtime(1, function()
        while #resp < 64 do
            local c = io.read(1)
            if not c then break end
            resp = resp .. c
            local s, e, _, col = resp:find("\27%[(%d+);(%d+)R")
            if s then
                local rest = resp:sub(1, s - 1) .. resp:sub(e + 1)
                if #rest > 0 then pending_bytes = pending_bytes .. rest end
                found_col = tonumber(col)
                return
            end
        end
    end)

    io.write("\27[1;1H\27[2K\0278")
    io.flush()
    if found_col ~= nil then
        return found_col == 3
    end
    if #resp > 0 then pending_bytes = pending_bytes .. resp end
    return true
end

-- =============================================================================
-- 1. Micro Editor Core (State & Plugin System)
-- =============================================================================
local Editor = {
    filename = "untitled.txt",
    lines = {""},
    cursor_x = 0, -- UTF-8 character index (0-based)
    cursor_y = 0, -- line index (0-based)
    row_offset = 0,
    is_modified = false,
    status_message = "",
    command_mode = false,
    command_buffer = "",
    cut_buffer = nil,
    running = true,
    quit_confirmed = false,
    mouse_enabled = true, -- micro風 マウスサポート (クリック移動 & ホイールスクロール)
    commands = {}, -- Custom commands registered via micro.addCommand()
    hooks = { onSave = {}, onBufferOpen = {} }
}

-- micro plugin API exported to init.lua
micro = {}

function micro.addCommand(name, fn)
    Editor.commands[name] = fn
end

function micro.on(event, fn)
    if Editor.hooks[event] then
        table.insert(Editor.hooks[event], fn)
    end
end

function micro.info(msg)
    Editor.status_message = tostring(msg)
end

function micro.getBuffer()
    return Editor.lines
end

function Editor:load_file(fname)
    self.filename = fname or "untitled.txt"
    local f = io.open(self.filename, "r")
    if f then
        self.lines = {}
        for line in f:lines() do
            table.insert(self.lines, (line:gsub("\r$", "")))
        end
        f:close()
        if #self.lines == 0 then self.lines = {""} end
    else
        self.lines = {""}
    end

    -- Trigger onBufferOpen hook
    for _, fn in ipairs(self.hooks.onBufferOpen) do
        pcall(fn, self.filename)
    end
end

function Editor:load_init_lua()
    local paths = {"./init.lua", os.getenv("HOME") .. "/.config/micro/init.lua"}
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            f:close()
            local chunk, err = loadfile(p)
            if chunk then
                local ok, run_err = pcall(chunk)
                if ok then
                    self.status_message = "Loaded " .. p
                else
                    self.status_message = "init.lua error: " .. tostring(run_err)
                end
            end
            break
        end
    end
end

function Editor:save_file(target)
    local fn = target or self.filename
    local f, err = io.open(fn, "w")
    if f then
        for _, line in ipairs(self.lines) do
            f:write(line .. "\n")
        end
        f:close()
        self.is_modified = false
        self.status_message = "Saved " .. fn

        for _, hook in ipairs(self.hooks.onSave) do
            pcall(hook, fn)
        end
    else
        self.status_message = "Save error: " .. tostring(err)
    end
end

function Editor:chars_at(y)
    local line = self.lines[y + 1] or ""
    local chars = {}
    for _, code in ipairs(utf8_codepoints(line)) do
        table.insert(chars, utf8.char(code))
    end
    return chars
end

-- =============================================================================
-- 2. Rendering (Micro-style layout: Editor + Statusbar + Command/Message bar)
-- =============================================================================
function Editor:render()
    local cols, rows = get_window_size()
    local screen_rows = math.max(1, rows - 2) -- Row 1..rows-2: Text, rows-1: Status, rows: Command/Info

    -- Vertical scroll
    if self.cursor_y < self.row_offset then
        self.row_offset = self.cursor_y
    end
    if self.cursor_y >= self.row_offset + screen_rows then
        self.row_offset = self.cursor_y - screen_rows + 1
    end

    set_title(string.format("micro - %s%s", self.filename, self.is_modified and "*" or ""))

    local out = {}
    table.insert(out, "\27[?2026h\27[?25l") -- Sync update & Hide cursor

    -- 1. Text Area (Row 1 .. rows - 2)
    local line_num_width = 4
    local text_cols = math.max(1, cols - line_num_width - 1)
    for i = 0, screen_rows - 1 do
        local file_row = self.row_offset + i
        table.insert(out, string.format("\27[%d;1H", i + 1))

        if file_row < #self.lines then
            local line_num = string.format("%3d ", file_row + 1)
            table.insert(out, "\27[90m" .. line_num .. "\27[0m")
            table.insert(out, truncate_str(self.lines[file_row + 1], text_cols))
            table.insert(out, "\27[K")
        else
            table.insert(out, "\27[90m  ~ \27[0m\27[K")
        end
    end

    -- 2. Statusline (Row rows - 1: Inverted style)
    table.insert(out, string.format("\27[%d;1H\27[7m", rows - 1))
    local mod_flag = self.is_modified and " (modified)" or ""
    local total_lines = #self.lines
    local pct = math.floor((self.cursor_y + 1) / total_lines * 100)
    local pos_info = string.format("%d,%d (%d%%)", self.cursor_y + 1, self.cursor_x + 1, pct)
    local eaw_tag = is_eaw and "EAW" or "Non-EAW"

    local left_status = string.format(" micro - %s%s | %s | %s", self.filename, mod_flag, pos_info, eaw_tag)
    local right_status = "Ctrl+E: Command | Ctrl+S: Save | Ctrl+Q: Quit "

    local max_bar_w = cols - 1
    local left_w = str_width(left_status)
    local right_w = str_width(right_status)
    local pad = math.max(0, max_bar_w - left_w - right_w)
    local full_bar = left_status .. string.rep(" ", pad) .. right_status
    table.insert(out, truncate_str(full_bar, max_bar_w))
    table.insert(out, "\27[0m\27[K")

    -- 3. Command/Prompt Line (Row rows)
    table.insert(out, string.format("\27[%d;1H", rows))
    if self.command_mode then
        table.insert(out, "\27[1;36m> \27[0m" .. truncate_str(self.command_buffer, math.max(1, cols - 3)) .. "\27[K")
    elseif self.status_message ~= "" then
        table.insert(out, "\27[36m" .. truncate_str(self.status_message, max_bar_w) .. "\27[0m\27[K")
    else
        table.insert(out, "\27[90m" .. truncate_str("Press Ctrl+E for command prompt, Ctrl+F to find, Ctrl+S to save", max_bar_w) .. "\27[0m\27[K")
    end

    -- 4. Set cursor position
    if self.command_mode then
        local cmd_x = math.min(cols, 3 + str_width(self.command_buffer))
        table.insert(out, string.format("\27[%d;%dH\27[?25h\27[?2026l", rows, cmd_x))
    else
        local screen_y = (self.cursor_y - self.row_offset) + 1
        local chars = self:chars_at(self.cursor_y)
        local prefix = table.concat(chars, "", 1, math.min(self.cursor_x, #chars))
        local visual_x = str_width(prefix)
        local screen_x = math.min(cols, visual_x + line_num_width + 1)
        table.insert(out, string.format("\27[%d;%dH\27[?25h\27[?2026l", screen_y, screen_x))
    end

    io.write(table.concat(out))
    io.flush()
end

-- =============================================================================
-- 3. Command Execution (`Ctrl+E` Prompt)
-- =============================================================================
function Editor:execute_command(input)
    self.command_mode = false
    self.command_buffer = ""
    local cmd = input:match("^%s*(.-)%s*$")
    if cmd == "" then return end

    local parts = {}
    for word in cmd:gmatch("%S+") do
        table.insert(parts, word)
    end
    local op = parts[1]

    -- Built-in micro commands
    if op == "save" or op == "w" then
        self:save_file(parts[2])
    elseif op == "quit" or op == "q" then
        if self.is_modified then
            self.status_message = "Unsaved changes! Use 'quit!' or Ctrl+Q to force"
        else
            self.running = false
        end
    elseif op == "quit!" or op == "q!" then
        self.running = false
    elseif op == "help" then
        self.status_message = "micro commands: save, quit, run <cmd>, set <opt>, eval <code>"
    elseif op == "run" then
        local sh_cmd = cmd:sub(5)
        io.write("\27[2J\27[H\27[1;36m=== Run: " .. sh_cmd .. " ===\27[0m\r\n\r\n")
        io.flush()
        local h = io.popen(sh_cmd .. " 2>&1")
        if h then
            local res = h:read("*a")
            h:close()
            io.write((res:gsub("\n", "\r\n")))
        end
        io.write("\r\n\r\n\27[7m [Press any key to return] \27[0m\r\n")
        io.flush()
        read_raw_byte()
        self.status_message = "Command finished: " .. sh_cmd
    elseif op == "set" then
        local key_opt, val = parts[2], parts[3]
        if key_opt == "mouse" then
            if val == "off" or val == "false" then
                self.mouse_enabled = false
                io.write("\27[?1000l\27[?1006l")
                io.flush()
                self.status_message = "Mouse disabled"
            else
                self.mouse_enabled = true
                io.write("\27[?1000h\27[?1006h")
                io.flush()
                self.status_message = "Mouse enabled"
            end
        else
            self.status_message = "Unknown option: " .. tostring(key_opt)
        end
    elseif op == "eval" then
        local code = cmd:sub(6)
        local chunk, err = load("return " .. code)
        if not chunk then chunk, err = load(code) end
        if chunk then
            local ok, res = pcall(chunk)
            self.status_message = "=> " .. tostring(res)
        else
            self.status_message = "Lua error: " .. tostring(err)
        end
    elseif self.commands[op] then
        -- User plugin command registered via micro.addCommand()
        local ok, err = pcall(self.commands[op], table.unpack(parts, 2))
        if not ok then
            self.status_message = "Command error: " .. tostring(err)
        end
    else
        self.status_message = "Unknown command: " .. op
    end
end

-- =============================================================================
-- 4. Key Handling & Text Editing
-- =============================================================================
function Editor:insert_text(text)
    local clean = scrub_utf8(text)
    local chars = self:chars_at(self.cursor_y)
    local before = table.concat(chars, "", 1, self.cursor_x)
    local after = table.concat(chars, "", self.cursor_x + 1)

    self.lines[self.cursor_y + 1] = before .. clean .. after
    self.cursor_x = self.cursor_x + utf8_char_count(clean)
    self.is_modified = true
end

function Editor:insert_pasted_text(pasted)
    local clean = scrub_utf8(pasted):gsub("\r\n", "\n"):gsub("\r", "\n")
    local paste_lines = {}
    local start = 1
    while true do
        local nl = clean:find("\n", start, true)
        if nl then
            table.insert(paste_lines, clean:sub(start, nl - 1))
            start = nl + 1
        else
            table.insert(paste_lines, clean:sub(start))
            break
        end
    end

    local chars = self:chars_at(self.cursor_y)
    local before = table.concat(chars, "", 1, self.cursor_x)
    local after = table.concat(chars, "", self.cursor_x + 1)
    if #paste_lines == 1 then
        self.lines[self.cursor_y + 1] = before .. paste_lines[1] .. after
        self.cursor_x = self.cursor_x + utf8_char_count(paste_lines[1])
    else
        local old_len = #self.lines
        local base = self.cursor_y + 1
        local shift = #paste_lines - 1
        if base + 1 <= old_len then
            table.move(self.lines, base + 1, old_len, base + 1 + shift)
        end
        self.lines[base] = before .. paste_lines[1]
        for i = 2, #paste_lines - 1 do
            self.lines[base + i - 1] = paste_lines[i]
        end
        local last = paste_lines[#paste_lines]
        self.lines[base + shift] = last .. after
        self.cursor_y = self.cursor_y + shift
        self.cursor_x = utf8_char_count(last)
    end
    self.is_modified = true
end

function Editor:insert_newline()
    local chars = self:chars_at(self.cursor_y)
    local before = table.concat(chars, "", 1, self.cursor_x)
    local after = table.concat(chars, "", self.cursor_x + 1)

    self.lines[self.cursor_y + 1] = before
    table.insert(self.lines, self.cursor_y + 2, after)
    self.cursor_y = self.cursor_y + 1
    self.cursor_x = 0
    self.is_modified = true
end

function Editor:delete_backward()
    local chars = self:chars_at(self.cursor_y)
    if self.cursor_x > 0 then
        table.remove(chars, self.cursor_x)
        self.lines[self.cursor_y + 1] = table.concat(chars, "")
        self.cursor_x = self.cursor_x - 1
        self.is_modified = true
    elseif self.cursor_y > 0 then
        local prev_chars = self:chars_at(self.cursor_y - 1)
        local prev_len = #prev_chars
        self.lines[self.cursor_y] = table.concat(prev_chars, "") .. table.concat(chars, "")
        table.remove(self.lines, self.cursor_y + 1)
        self.cursor_y = self.cursor_y - 1
        self.cursor_x = prev_len
        self.is_modified = true
    end
end

function Editor:move_cursor(dx, dy)
    local new_y = math.max(0, math.min(#self.lines - 1, self.cursor_y + dy))
    if new_y ~= self.cursor_y then
        self.cursor_y = new_y
        local chars = self:chars_at(self.cursor_y)
        self.cursor_x = math.min(self.cursor_x, #chars)
    end

    if dx > 0 then
        local chars = self:chars_at(self.cursor_y)
        if self.cursor_x < #chars then
            self.cursor_x = self.cursor_x + 1
        elseif self.cursor_y < #self.lines - 1 then
            self.cursor_y = self.cursor_y + 1
            self.cursor_x = 0
        end
    elseif dx < 0 then
        if self.cursor_x > 0 then
            self.cursor_x = self.cursor_x - 1
        elseif self.cursor_y > 0 then
            self.cursor_y = self.cursor_y - 1
            local chars = self:chars_at(self.cursor_y)
            self.cursor_x = #chars
        end
    end
end

function Editor:read_key()
    local c = read_raw_byte()
    if not c then return nil end

    if c == "\27" then
        -- Read escape sequence (100ms timeout for bare Esc vs CSI/SS3/Meta)
        return with_tty_vtime(1, function()
            local c2 = read_raw_byte()
            if not c2 then return "\27" end

            if c2 == "[" then
                local seq = "\27["
                while true do
                    local next_c = read_raw_byte()
                    if not next_c then break end
                    seq = seq .. next_c
                    local b = string.byte(next_c)
                    if b >= 0x40 and b <= 0x7E then break end
                end
                return seq
            elseif c2 == "O" then
                local c3 = read_raw_byte()
                if not c3 then return "\27O" end
                local ss3 = { A = "\27[A", B = "\27[B", C = "\27[C", D = "\27[D", H = "\27[H", F = "\27[F" }
                return ss3[c3] or ("\27O" .. c3)
            else
                return "\27" .. c2
            end
        end)
    end

    -- UTF-8 multibyte
    local b = string.byte(c)
    local len = 1
    if b >= 0xF0 and b <= 0xF4 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC2 then len = 2 end

    if len > 1 then
        c = with_tty_vtime(1, function()
            local s = c
            for _ = 2, len do
                local next_b = read_raw_byte()
                if not next_b then break end
                s = s .. next_b
            end
            return s
        end)
    end

    return scrub_utf8(c)
end

function Editor:read_bracketed_paste()
    return with_tty_vtime(2, function()
        local buf = {}
        local end_marker = "\27[201~"
        local tail = ""
        while true do
            local c = read_raw_byte()
            if not c then break end
            table.insert(buf, c)
            tail = (tail .. c):sub(-#end_marker)
            if tail == end_marker then
                local full = table.concat(buf)
                return full:sub(1, -#end_marker - 1)
            end
        end
        return table.concat(buf)
    end)
end

-- =============================================================================
-- 5. Main Loop
-- =============================================================================
function Editor:cleanup()
    set_title("")
    io.write("\27[?2004l\27[?1000l\27[?1006l\27[?1049l\27[?25h\27[0m")
    io.flush()
    set_raw_mode(false)
end

function Editor:run()
    local tty_ok = os.execute("test -t 0")
    if not tty_ok then
        io.stderr:write("エラー: inzm.lua は対話型ターミナル (TTY) で実行してください。\n")
        os.exit(1)
    end

    set_raw_mode(true)
    -- 代替画面バッファ & SGRマウスモード & Bracketed Paste 有効化
    io.write("\27[?1049h\27[2J\27[H\27[?1000h\27[?1006h\27[?2004h")
    io.flush()

    local ok, err = xpcall(function()
        is_eaw = probe_eaw()
        self:load_init_lua()
        self:render()

        while self.running do
            local key = self:read_key()
            if not key then break end

            if self.status_message ~= "" and not self.command_mode then
                self.status_message = ""
            end
            if key ~= "\17" and key ~= "\3" then
                self.quit_confirmed = false
            end

            -- Bracketed Paste (\27[200~ ... \27[201~)
            if key == "\27[200~" then
                local pasted = self:read_bracketed_paste():gsub("\r\n", "\n"):gsub("\r", "\n")
                if self.command_mode then
                    local first_line = scrub_utf8(pasted:match("^([^\n]*)") or "")
                    local clean_parts = {}
                    for _, code in ipairs(utf8_codepoints(first_line)) do
                        if code == 9 then
                            table.insert(clean_parts, " ")
                        elseif code >= 0x20 and code ~= 0x7F and not (code >= 0x80 and code < 0xA0) then
                            table.insert(clean_parts, utf8.char(code))
                        end
                    end
                    self.command_buffer = self.command_buffer .. table.concat(clean_parts)
                else
                    self:insert_pasted_text(pasted)
                end
            -- ==================== Command Mode (`Ctrl+E`) ====================
            elseif self.command_mode then
            if key == "\r" or key == "\n" then
                self:execute_command(self.command_buffer)
            elseif key == "\27" or key == "\3" then -- Esc / Ctrl+C
                self.command_mode = false
                self.command_buffer = ""
            elseif key == "\127" or key == "\8" then -- Backspace
                if #self.command_buffer > 0 then
                    local chars = {}
                    for _, code in ipairs(utf8_codepoints(self.command_buffer)) do
                        table.insert(chars, utf8.char(code))
                    end
                    table.remove(chars)
                    self.command_buffer = table.concat(chars, "")
                else
                    self.command_mode = false
                end
            elseif not key:match("^\27") and key >= " " then
                self.command_buffer = self.command_buffer .. key
            end

        -- ==================== Normal Edit Mode ====================
        else
            -- ==================== SGR Mouse Events (`\27[<btn;col;rowM/m`) ====================
            local m_btn, m_col, m_row, m_rel = key:match("^\27%[<(%d+);(%d+);(%d+)([Mm])")
            if m_btn then
                local btn = tonumber(m_btn)
                local col = tonumber(m_col)
                local row = tonumber(m_row)
                local release = (m_rel == "m")

                if not release and self.mouse_enabled then
                    local _, win_rows = get_window_size()
                    local screen_rows = math.max(1, win_rows - 2)

                    -- 1. 左クリック: クリック位置へカーソルジャンプ！
                    if btn == 0 then
                        if row >= 1 and row <= screen_rows then
                            local target_y = self.row_offset + (row - 1)
                            if target_y < #self.lines then
                                self.cursor_y = target_y
                                local text_col = math.max(0, col - 5) -- 行番号幅(4)+1-indexed
                                local chars = self:chars_at(self.cursor_y)
                                local cur_w = 0
                                local target_x = 0
                                for idx, ch in ipairs(chars) do
                                    local cp = utf8.codepoint(ch)
                                    local cw = sanitize_codepoint(cp, cur_w, 4)
                                    if cur_w + cw > text_col then break end
                                    cur_w = cur_w + cw
                                    target_x = idx
                                end
                                self.cursor_x = target_x
                            end
                        end
                    -- 2. マウスホイール: 上下スクロール！
                    elseif btn == 64 then
                        self:move_cursor(0, -3) -- スクロールアップ
                    elseif btn == 65 then
                        self:move_cursor(0, 3)  -- スクロールダウン
                    end
                end

            -- Ctrl+Q (\17) or Ctrl+C (\3): Exit
            elseif key == "\17" or key == "\3" then
                if self.is_modified and not self.quit_confirmed then
                    self.quit_confirmed = true
                    self.status_message = "Unsaved changes! Press Ctrl+Q again to force quit"
                else
                    break
                end

            -- Ctrl+S (\19): Save
            elseif key == "\19" then
                self:save_file()
                self.quit_confirmed = false

            -- Ctrl+E (\5): Command Prompt (micro's signature command bar!)
            elseif key == "\5" then
                self.command_mode = true
                self.command_buffer = ""

            -- Ctrl+F (\6): Find in buffer
            elseif key == "\6" then
                self.command_mode = true
                self.command_buffer = "find "

            -- Ctrl+D (\4): Duplicate line
            elseif key == "\4" then
                local cur = self.lines[self.cursor_y + 1] or ""
                table.insert(self.lines, self.cursor_y + 2, cur)
                self.cursor_y = self.cursor_y + 1
                self.is_modified = true
                self.status_message = "Duplicated line"

            -- Ctrl+K (\11): Cut line
            elseif key == "\11" then
                if #self.lines > 1 then
                    self.cut_buffer = table.remove(self.lines, self.cursor_y + 1)
                    if self.cursor_y >= #self.lines then self.cursor_y = #self.lines - 1 end
                else
                    self.lines[1] = ""
                end
                self.cursor_x = math.min(self.cursor_x, #self:chars_at(self.cursor_y))
                self.is_modified = true
                self.status_message = "Cut line"

            -- Ctrl+U (\21): Paste line
            elseif key == "\21" then
                if self.cut_buffer then
                    table.insert(self.lines, self.cursor_y + 2, self.cut_buffer)
                    self.cursor_y = self.cursor_y + 1
                    self.is_modified = true
                    self.status_message = "Pasted line"
                end

            -- Navigation
            elseif key == "\27[A" then self:move_cursor(0, -1) -- Up
            elseif key == "\27[B" then self:move_cursor(0, 1)  -- Down
            elseif key == "\27[C" then self:move_cursor(1, 0)  -- Right
            elseif key == "\27[D" then self:move_cursor(-1, 0) -- Left
            elseif key == "\27[H" or key == "\27[1~" then self.cursor_x = 0 -- Home
            elseif key == "\27[F" or key == "\27[4~" then self.cursor_x = #self:chars_at(self.cursor_y) -- End
            elseif key == "\27[5~" then -- PageUp
                local _, rows = get_window_size()
                self:move_cursor(0, -(rows - 2))
            elseif key == "\27[6~" then -- PageDown
                local _, rows = get_window_size()
                self:move_cursor(0, rows - 2)

            -- Text editing
            elseif key == "\r" or key == "\n" then
                self:insert_newline()
            elseif key == "\127" or key == "\8" then
                self:delete_backward()
            elseif not key:match("^\27") and key >= " " then
                self:insert_text(key)
            end
        end

        if self.running then
            self:render()
        end
    end
    end, debug.traceback)

    self:cleanup()
    if not ok then
        io.stderr:write("Editor error: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

-- --- Entrypoint ---
local target_file = arg[1] or "sample.txt"
Editor:load_file(target_file)
Editor:run()
