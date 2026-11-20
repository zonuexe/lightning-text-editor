package inzm

import java.io.File
import kotlin.math.max
import kotlin.math.min

class TextBuffer(
    var filename: String = "[No Name]",
    initialLines: List<String> = listOf(""),
    var editorConfig: EditorConfig = EditorConfig(),
) {
    val lines = ArrayList<String>(initialLines.ifEmpty { listOf("") })
    var cursorRow: Int = 0
    var cursorCol: Int = 0 // code-point index within lines[cursorRow]
    var rowOffset: Int = 0
    var colOffset: Int = 0
    var anchor: Pos? = null
    var isModified: Boolean = false

    fun cursorPos(): Pos = Pos(cursorRow, cursorCol)

    fun hasSelection(): Boolean {
        val a = anchor ?: return false
        return a != cursorPos()
    }

    fun normalizedSelection(): Pair<Pos, Pos>? {
        val a = anchor ?: return null
        val b = cursorPos()
        if (a == b) return null
        return if (a <= b) a to b else b to a
    }

    fun clampCursor() {
        if (lines.isEmpty()) lines.add("")
        cursorRow = cursorRow.coerceIn(0, lines.lastIndex)
        val cpLen = UnicodeWidth.codePointCount(lines[cursorRow])
        cursorCol = cursorCol.coerceIn(0, cpLen)
    }

    fun extractRangeText(start: Pos, end: Pos): String {
        if (start == end) return ""
        if (start.row == end.row) {
            return UnicodeWidth.sliceCodePoints(lines[start.row], start.col, end.col)
        }
        val sb = StringBuilder()
        sb.append(UnicodeWidth.sliceCodePoints(lines[start.row], start.col))
        for (r in (start.row + 1) until end.row) {
            sb.append('\n').append(lines[r])
        }
        sb.append('\n').append(UnicodeWidth.sliceCodePoints(lines[end.row], 0, end.col))
        return sb.toString()
    }

    fun deleteRange(start: Pos, end: Pos) {
        if (start == end) return
        if (start.row == end.row) {
            val line = lines[start.row]
            val before = UnicodeWidth.sliceCodePoints(line, 0, start.col)
            val after = UnicodeWidth.sliceCodePoints(line, end.col)
            lines[start.row] = before + after
        } else {
            val before = UnicodeWidth.sliceCodePoints(lines[start.row], 0, start.col)
            val after = UnicodeWidth.sliceCodePoints(lines[end.row], end.col)
            lines[start.row] = before + after
            for (r in end.row downTo (start.row + 1)) {
                lines.removeAt(r)
            }
        }
        cursorRow = start.row
        cursorCol = start.col
        anchor = null
        isModified = true
        clampCursor()
    }

    /**
     * 改行を含む任意文字列をカーソル位置へ挿入し、(挿入開始位置, 挿入終了位置) を返す。
     */
    fun insertTextAtCursor(text: String): Pair<Pos, Pos> {
        normalizedSelection()?.let { (s, e) -> deleteRange(s, e) }
        val start = cursorPos()
        val normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        val parts = normalized.split('\n')

        val curLine = lines[cursorRow]
        val before = UnicodeWidth.sliceCodePoints(curLine, 0, cursorCol)
        val after = UnicodeWidth.sliceCodePoints(curLine, cursorCol)

        if (parts.size == 1) {
            lines[cursorRow] = before + parts[0] + after
            cursorCol += UnicodeWidth.codePointCount(parts[0])
        } else {
            lines[cursorRow] = before + parts[0]
            for (i in 1 until parts.lastIndex) {
                lines.add(cursorRow + i, parts[i])
            }
            val lastRow = cursorRow + parts.lastIndex
            val lastPart = parts.last()
            lines.add(lastRow, lastPart + after)
            cursorRow = lastRow
            cursorCol = UnicodeWidth.codePointCount(lastPart)
        }

        isModified = true
        val end = cursorPos()
        return start to end
    }

    fun content(): String = lines.joinToString("\n")
}

enum class PromptMode {
    NONE,
    ACTION,
    SEARCH,
    OPEN_FILE,
    SAVE_AS,
}

class EditorCore(
    var cols: Int = 80,
    var rows: Int = 24,
    var isEaw: Boolean = false,
    val tabWidth: Int = 4,
) {
    val buffers = ArrayList<TextBuffer>().apply { add(TextBuffer()) }
    var activeBufIdx: Int = 0
    val killRing = KillRing(capacity = 32)

    var isRunning: Boolean = true
    var statusMessage: String = "jEdit-like Kotlin Editor | F2: Action | C-k: Kill | C-y: Yank | M-y: YankPop | C-e C-k: Ring"
    var quitWarned: Boolean = false
    var pendingCtrlE: Boolean = false

    // Kill Ring オーバーレイ選択 UI
    var showingKillRingModal: Boolean = false
    var killRingSelectedIdx: Int = 0

    // プロンプト (Action Bar / Search / Open / Save As)
    var promptMode: PromptMode = PromptMode.NONE
    var promptInput: String = ""
    var searchQuery: String = ""

    fun activeBuffer(): TextBuffer {
        if (buffers.isEmpty()) buffers.add(TextBuffer())
        activeBufIdx = activeBufIdx.coerceIn(0, buffers.lastIndex)
        return buffers[activeBufIdx]
    }

    fun textRows(): Int = max(1, rows - 3) // Row 1: TabBar, Rows - 1: StatusBar, Rows: Prompt/Message

    /**
     * 単一のガター描画幅情報源。"%*d │ " -> digits + 3 列。
     */
    fun gutterWidth(): Int {
        val digits = max(3, activeBuffer().lines.size.toString().length)
        return digits + 3
    }

    fun openFile(path: String) {
        val absPath = File(path).absolutePath
        val existingIdx = buffers.indexOfFirst { it.filename != "[No Name]" && File(it.filename).absolutePath == absPath }
        if (existingIdx >= 0) {
            activeBufIdx = existingIdx
            statusMessage = "Switched to: $path"
            ensureCursorVisible()
            return
        }

        val cfg = EditorConfigResolver.resolve(path)
        val f = File(path)
        val lines = if (f.isFile) {
            val raw = f.readText(Charsets.UTF_8).replace("\r\n", "\n").replace("\r", "\n")
            val split = raw.split('\n').toMutableList()
            if (split.size > 1 && split.last().isEmpty()) {
                split.removeAt(split.lastIndex)
            }
            if (split.isEmpty()) listOf("") else split
        } else {
            listOf("")
        }
        val buf = TextBuffer(filename = path, initialLines = lines, editorConfig = cfg)
        if (buffers.size == 1 && buffers[0].filename == "[No Name]" && !buffers[0].isModified && buffers[0].lines == listOf("")) {
            buffers[0] = buf
            activeBufIdx = 0
        } else {
            buffers.add(buf)
            activeBufIdx = buffers.lastIndex
        }
        statusMessage = if (f.isFile) "Opened $path" else "New file: $path"
        ensureCursorVisible()
    }

    fun saveActiveBuffer(targetPath: String? = null): Boolean {
        val buf = activeBuffer()
        val path = targetPath ?: buf.filename
        if (path == "[No Name]" || path.isBlank()) {
            promptMode = PromptMode.SAVE_AS
            promptInput = ""
            statusMessage = "Enter filename to save"
            return false
        }
        val cfg = EditorConfigResolver.resolve(path)
        buf.editorConfig = cfg
        if (cfg.trimTrailingWhitespace) {
            for (i in buf.lines.indices) {
                buf.lines[i] = buf.lines[i].trimEnd { it == ' ' || it == '\t' }
            }
            buf.clampCursor()
        }
        val eol = when (cfg.endOfLine) {
            "crlf" -> "\r\n"
            "cr" -> "\r"
            else -> "\n"
        }
        var out = buf.lines.joinToString(eol)
        if (out.isNotEmpty()) out += eol
        File(path).writeText(out, Charsets.UTF_8)
        buf.filename = path
        buf.isModified = false
        quitWarned = false
        statusMessage = "Saved ${out.toByteArray(Charsets.UTF_8).size} bytes to $path"
        return true
    }

    fun ensureCursorVisible() {
        val buf = activeBuffer()
        buf.clampCursor()
        val tr = textRows()
        if (buf.cursorRow < buf.rowOffset) buf.rowOffset = buf.cursorRow
        if (buf.cursorRow >= buf.rowOffset + tr) buf.rowOffset = buf.cursorRow - tr + 1

        val textCols = max(1, cols - gutterWidth())
        val vx = UnicodeWidth.visualWidthUpTo(buf.lines[buf.cursorRow], buf.cursorCol, tabWidth, isEaw)
        if (vx < buf.colOffset) buf.colOffset = vx
        if (vx >= buf.colOffset + textCols) buf.colOffset = vx - textCols + 1
    }

    fun handleEvent(ev: InputEvent) {
        if (showingKillRingModal) {
            handleKillRingModalEvent(ev)
            return
        }
        if (promptMode != PromptMode.NONE) {
            handlePromptEvent(ev)
            return
        }
        if (pendingCtrlE) {
            handleCtrlEChord(ev)
            return
        }

        val buf = activeBuffer()
        when (ev) {
            is InputEvent.CharInput -> {
                quitWarned = false
                killRing.breakChain()
                buf.insertTextAtCursor(ev.text)
                ensureCursorVisible()
            }
            InputEvent.Enter -> {
                quitWarned = false
                killRing.breakChain()
                buf.insertTextAtCursor("\n")
                ensureCursorVisible()
            }
            InputEvent.Tab -> {
                quitWarned = false
                killRing.breakChain()
                buf.insertTextAtCursor(buf.editorConfig.tabInsertion())
                ensureCursorVisible()
            }
            InputEvent.Backspace -> {
                quitWarned = false
                killRing.breakChain()
                performBackspace(buf)
                ensureCursorVisible()
            }
            InputEvent.Delete -> {
                quitWarned = false
                killRing.breakChain()
                performDelete(buf)
                ensureCursorVisible()
            }
            InputEvent.AltBackspace -> {
                quitWarned = false
                performKillWordBackward(buf)
                ensureCursorVisible()
            }
            is InputEvent.Paste -> {
                quitWarned = false
                killRing.breakChain()
                buf.insertTextAtCursor(ev.text)
                statusMessage = "Pasted ${UnicodeWidth.codePointCount(ev.text)} chars"
                ensureCursorVisible()
            }

            // Navigation
            InputEvent.Left -> moveCursor(0, -1, extendSelection = false)
            InputEvent.Right -> moveCursor(0, 1, extendSelection = false)
            InputEvent.Up -> moveCursor(-1, 0, extendSelection = false)
            InputEvent.Down -> moveCursor(1, 0, extendSelection = false)
            InputEvent.Home -> moveLineEdge(toEnd = false, extendSelection = false)
            InputEvent.End -> moveLineEdge(toEnd = true, extendSelection = false)
            InputEvent.PageUp -> movePage(-1)
            InputEvent.PageDown -> movePage(1)
            InputEvent.AltLeft -> moveWord(forward = false)
            InputEvent.AltRight -> moveWord(forward = true)

            // Shift Selection
            InputEvent.ShiftLeft -> moveCursor(0, -1, extendSelection = true)
            InputEvent.ShiftRight -> moveCursor(0, 1, extendSelection = true)
            InputEvent.ShiftUp -> moveCursor(-1, 0, extendSelection = true)
            InputEvent.ShiftDown -> moveCursor(1, 0, extendSelection = true)
            InputEvent.ShiftHome -> moveLineEdge(toEnd = false, extendSelection = true)
            InputEvent.ShiftEnd -> moveLineEdge(toEnd = true, extendSelection = true)

            InputEvent.CtrlSpace -> {
                killRing.breakChain()
                buf.anchor = buf.cursorPos()
                statusMessage = "Mark set at (${buf.cursorRow + 1}, ${buf.cursorCol + 1})"
            }
            InputEvent.Esc -> {
                quitWarned = false
                killRing.breakChain()
                if (buf.anchor != null) {
                    buf.anchor = null
                    statusMessage = "Selection cleared"
                }
            }

            // Kill Ring & Editing Shortcuts
            is InputEvent.Ctrl -> handleCtrlKey(ev.letter)
            is InputEvent.Alt -> handleAltKey(ev.letter)

            InputEvent.F2, InputEvent.AltEnter -> {
                killRing.breakChain()
                promptMode = PromptMode.ACTION
                promptInput = ""
            }

            // Mouse (SGR 1006)
            is InputEvent.MouseLeftPress -> handleMouseClick(ev.col, ev.row, isDrag = false)
            is InputEvent.MouseDrag -> handleMouseClick(ev.col, ev.row, isDrag = true)
            InputEvent.MouseRelease -> Unit
            InputEvent.MouseWheelUp -> scrollViewport(-3)
            InputEvent.MouseWheelDown -> scrollViewport(3)
            InputEvent.UnknownEscape -> Unit
        }
    }

    private fun handleCtrlKey(letter: Char) {
        val buf = activeBuffer()
        when (letter) {
            'q' -> requestQuit(force = false)
            's' -> {
                killRing.breakChain()
                saveActiveBuffer()
            }
            'o' -> {
                killRing.breakChain()
                promptMode = PromptMode.OPEN_FILE
                promptInput = ""
            }
            'f' -> {
                killRing.breakChain()
                promptMode = PromptMode.SEARCH
                promptInput = searchQuery
            }
            'e' -> {
                pendingCtrlE = true
                statusMessage = "C-e ..."
            }
            'k' -> {
                quitWarned = false
                performKillToEndOfLine(buf)
                ensureCursorVisible()
            }
            'y' -> {
                quitWarned = false
                performYank()
                ensureCursorVisible()
            }
            'w' -> {
                quitWarned = false
                performKillRegionOrWordBackward(buf)
                ensureCursorVisible()
            }
            'a' -> moveLineEdge(toEnd = false, extendSelection = false)
            'd' -> {
                quitWarned = false
                killRing.breakChain()
                performDelete(buf)
                ensureCursorVisible()
            }
            'n' -> switchBuffer(1)
            'p' -> switchBuffer(-1)
            'g' -> {
                quitWarned = false
                killRing.breakChain()
                buf.anchor = null
                statusMessage = "Cancelled"
            }
            't' -> {
                isEaw = !isEaw
                statusMessage = "EAW mode: ${if (isEaw) "WIDE (2)" else "NARROW (1)"}"
                ensureCursorVisible()
            }
        }
    }

    private fun handleAltKey(letter: Char) {
        val buf = activeBuffer()
        when (letter) {
            'y' -> {
                quitWarned = false
                performYankPop()
                ensureCursorVisible()
            }
            'w' -> {
                performCopyRegion(buf)
            }
            'd' -> {
                quitWarned = false
                performKillWordForward(buf)
                ensureCursorVisible()
            }
            'f' -> moveWord(forward = true)
            'b' -> moveWord(forward = false)
        }
    }

    /**
     * jEdit スタイル 2 ストローク (`Ctrl+E` + 次キー)
     */
    private fun handleCtrlEChord(ev: InputEvent) {
        pendingCtrlE = false
        val buf = activeBuffer()
        when (ev) {
            is InputEvent.Ctrl -> when (ev.letter) {
                'k' -> openKillRingModal()
                'd' -> {
                    performKillWholeLine(buf)
                    ensureCursorVisible()
                }
                'n' -> switchBuffer(1)
                'p' -> switchBuffer(-1)
                else -> statusMessage = "C-e C-${ev.letter} is undefined"
            }
            is InputEvent.CharInput -> when (ev.text.lowercase()) {
                "k" -> openKillRingModal()
                "d" -> {
                    killRing.breakChain()
                    duplicateCurrentLine(buf)
                    ensureCursorVisible()
                }
                "x" -> {
                    performKillWholeLine(buf)
                    ensureCursorVisible()
                }
                "n" -> switchBuffer(1)
                "p" -> switchBuffer(-1)
                "w" -> closeCurrentBuffer(force = false)
                "a" -> {
                    promptMode = PromptMode.ACTION
                    promptInput = ""
                }
                "j" -> {
                    promptMode = PromptMode.ACTION
                    promptInput = "goto "
                }
                else -> statusMessage = "C-e ${ev.text} is undefined"
            }
            InputEvent.Enter -> {
                promptMode = PromptMode.ACTION
                promptInput = ""
            }
            InputEvent.Esc -> statusMessage = "C-e cancelled"
            else -> statusMessage = "C-e cancelled"
        }
    }

    // MARK: - Kill Ring Core Actions

    fun performKillToEndOfLine(buf: TextBuffer) {
        val line = buf.lines[buf.cursorRow]
        val cpLen = UnicodeWidth.codePointCount(line)
        if (buf.cursorCol < cpLen) {
            val killed = UnicodeWidth.sliceCodePoints(line, buf.cursorCol)
            buf.lines[buf.cursorRow] = UnicodeWidth.sliceCodePoints(line, 0, buf.cursorCol)
            buf.isModified = true
            buf.anchor = null
            killRing.pushKill(killed, appendToCurrent = true, prepend = false)
            statusMessage = "Killed ${UnicodeWidth.codePointCount(killed)} chars (Ring: ${killRing.size})"
        } else if (buf.cursorRow < buf.lines.lastIndex) {
            val next = buf.lines.removeAt(buf.cursorRow + 1)
            buf.lines[buf.cursorRow] = line + next
            buf.isModified = true
            buf.anchor = null
            killRing.pushKill("\n", appendToCurrent = true, prepend = false)
            statusMessage = "Killed newline (Ring: ${killRing.size})"
        } else {
            statusMessage = "End of buffer"
        }
    }

    fun performKillWholeLine(buf: TextBuffer) {
        val lineText = buf.lines[buf.cursorRow]
        if (buf.lines.size > 1) {
            buf.lines.removeAt(buf.cursorRow)
            buf.clampCursor()
            buf.cursorCol = 0
            killRing.pushKill(lineText + "\n", appendToCurrent = true, prepend = false)
        } else {
            buf.lines[0] = ""
            buf.cursorCol = 0
            killRing.pushKill(lineText, appendToCurrent = true, prepend = false)
        }
        buf.isModified = true
        buf.anchor = null
        statusMessage = "Killed line (Ring: ${killRing.size})"
    }

    fun performKillWordForward(buf: TextBuffer) {
        val start = buf.cursorPos()
        moveWord(forward = true, keepKillChain = true)
        val end = buf.cursorPos()
        if (start < end) {
            val killed = buf.extractRangeText(start, end)
            buf.deleteRange(start, end)
            killRing.pushKill(killed, appendToCurrent = true, prepend = false)
            statusMessage = "Killed word (Ring: ${killRing.size})"
        }
    }

    fun performKillWordBackward(buf: TextBuffer) {
        val end = buf.cursorPos()
        moveWord(forward = false, keepKillChain = true)
        val start = buf.cursorPos()
        if (start < end) {
            val killed = buf.extractRangeText(start, end)
            buf.deleteRange(start, end)
            killRing.pushKill(killed, appendToCurrent = true, prepend = true)
            statusMessage = "Killed backward word (Ring: ${killRing.size})"
        }
    }

    fun performKillRegionOrWordBackward(buf: TextBuffer) {
        val sel = buf.normalizedSelection()
        if (sel != null) {
            val (s, e) = sel
            val killed = buf.extractRangeText(s, e)
            buf.deleteRange(s, e)
            killRing.pushKill(killed, appendToCurrent = true, prepend = false)
            statusMessage = "Killed region (${UnicodeWidth.codePointCount(killed)} chars)"
        } else {
            performKillWordBackward(buf)
        }
    }

    fun performCopyRegion(buf: TextBuffer) {
        val sel = buf.normalizedSelection()
        if (sel != null) {
            val (s, e) = sel
            val copied = buf.extractRangeText(s, e)
            killRing.pushCopy(copied)
            buf.anchor = null
            statusMessage = "Copied ${UnicodeWidth.codePointCount(copied)} chars to Kill Ring"
        } else {
            val line = buf.lines[buf.cursorRow]
            killRing.pushCopy(line + "\n")
            statusMessage = "Copied current line to Kill Ring"
        }
    }

    fun performYank() {
        val text = killRing.beginYank()
        if (text == null) {
            statusMessage = "Kill Ring is empty"
            return
        }
        val buf = activeBuffer()
        val (start, end) = buf.insertTextAtCursor(text)
        killRing.lastYankSpan = KillRing.YankSpan(activeBufIdx, start.row, start.col, end.row, end.col)
        statusMessage = "Yanked [1/${killRing.size}]"
    }

    fun performYankPop() {
        val span = killRing.lastYankSpan
        if (!killRing.lastActionWasYank || span == null || span.bufferIndex != activeBufIdx) {
            statusMessage = "Previous command was not a yank (press Ctrl+Y first)"
            return
        }
        val replacement = killRing.yankPop() ?: return
        val buf = activeBuffer()
        buf.deleteRange(Pos(span.startRow, span.startCol), Pos(span.endRow, span.endCol))
        val (newStart, newEnd) = buf.insertTextAtCursor(replacement)
        killRing.lastYankSpan = KillRing.YankSpan(activeBufIdx, newStart.row, newStart.col, newEnd.row, newEnd.col)
        val preview = previewEntry(replacement, 28)
        statusMessage = "Yank-Pop [${killRing.yankPointer + 1}/${killRing.size}]: \"$preview\""
    }

    private fun openKillRingModal() {
        if (killRing.isEmpty()) {
            statusMessage = "Kill Ring is empty"
            return
        }
        showingKillRingModal = true
        killRingSelectedIdx = 0
    }

    private fun handleKillRingModalEvent(ev: InputEvent) {
        val items = killRing.snapshot()
        if (items.isEmpty()) {
            showingKillRingModal = false
            return
        }
        when (ev) {
            InputEvent.Up, InputEvent.Ctrl('p') -> {
                killRingSelectedIdx = (killRingSelectedIdx - 1 + items.size) % items.size
            }
            InputEvent.Down, InputEvent.Ctrl('n') -> {
                killRingSelectedIdx = (killRingSelectedIdx + 1) % items.size
            }
            InputEvent.Enter -> {
                val chosen = killRing.yankAt(killRingSelectedIdx)
                showingKillRingModal = false
                if (chosen != null) {
                    val buf = activeBuffer()
                    val (s, e) = buf.insertTextAtCursor(chosen)
                    killRing.lastYankSpan = KillRing.YankSpan(activeBufIdx, s.row, s.col, e.row, e.col)
                    statusMessage = "Yanked Ring #${killRingSelectedIdx + 1}"
                    ensureCursorVisible()
                }
            }
            InputEvent.Esc, InputEvent.Ctrl('g') -> {
                showingKillRingModal = false
                statusMessage = "Closed Kill Ring selector"
            }
            is InputEvent.CharInput -> {
                val num = ev.text.toIntOrNull()
                if (num != null && num in 1..items.size) {
                    val idx = num - 1
                    val chosen = killRing.yankAt(idx)
                    showingKillRingModal = false
                    if (chosen != null) {
                        val buf = activeBuffer()
                        val (s, e) = buf.insertTextAtCursor(chosen)
                        killRing.lastYankSpan = KillRing.YankSpan(activeBufIdx, s.row, s.col, e.row, e.col)
                        statusMessage = "Yanked Ring #$num"
                        ensureCursorVisible()
                    }
                }
            }
            else -> Unit
        }
    }

    // MARK: - Basic Editing & Navigation

    private fun performBackspace(buf: TextBuffer) {
        val sel = buf.normalizedSelection()
        if (sel != null) {
            buf.deleteRange(sel.first, sel.second)
            return
        }
        if (buf.cursorCol > 0) {
            val line = buf.lines[buf.cursorRow]
            val before = UnicodeWidth.sliceCodePoints(line, 0, buf.cursorCol - 1)
            val after = UnicodeWidth.sliceCodePoints(line, buf.cursorCol)
            buf.lines[buf.cursorRow] = before + after
            buf.cursorCol -= 1
            buf.isModified = true
        } else if (buf.cursorRow > 0) {
            val prev = buf.lines[buf.cursorRow - 1]
            val cur = buf.lines.removeAt(buf.cursorRow)
            buf.cursorRow -= 1
            buf.cursorCol = UnicodeWidth.codePointCount(prev)
            buf.lines[buf.cursorRow] = prev + cur
            buf.isModified = true
        }
    }

    private fun performDelete(buf: TextBuffer) {
        val sel = buf.normalizedSelection()
        if (sel != null) {
            buf.deleteRange(sel.first, sel.second)
            return
        }
        val line = buf.lines[buf.cursorRow]
        val cpLen = UnicodeWidth.codePointCount(line)
        if (buf.cursorCol < cpLen) {
            val before = UnicodeWidth.sliceCodePoints(line, 0, buf.cursorCol)
            val after = UnicodeWidth.sliceCodePoints(line, buf.cursorCol + 1)
            buf.lines[buf.cursorRow] = before + after
            buf.isModified = true
        } else if (buf.cursorRow < buf.lines.lastIndex) {
            val next = buf.lines.removeAt(buf.cursorRow + 1)
            buf.lines[buf.cursorRow] = line + next
            buf.isModified = true
        }
    }

    private fun duplicateCurrentLine(buf: TextBuffer) {
        val line = buf.lines[buf.cursorRow]
        buf.lines.add(buf.cursorRow + 1, line)
        buf.cursorRow += 1
        buf.isModified = true
        statusMessage = "Duplicated line"
    }

    private fun moveCursor(dRow: Int, dCol: Int, extendSelection: Boolean) {
        quitWarned = false
        killRing.breakChain()
        val buf = activeBuffer()
        if (extendSelection) {
            if (buf.anchor == null) buf.anchor = buf.cursorPos()
        } else {
            buf.anchor = null
        }

        if (dRow != 0) {
            buf.cursorRow = (buf.cursorRow + dRow).coerceIn(0, buf.lines.lastIndex)
            buf.clampCursor()
        }
        if (dCol < 0) {
            if (buf.cursorCol > 0) {
                buf.cursorCol -= 1
            } else if (buf.cursorRow > 0) {
                buf.cursorRow -= 1
                buf.cursorCol = UnicodeWidth.codePointCount(buf.lines[buf.cursorRow])
            }
        } else if (dCol > 0) {
            val cpLen = UnicodeWidth.codePointCount(buf.lines[buf.cursorRow])
            if (buf.cursorCol < cpLen) {
                buf.cursorCol += 1
            } else if (buf.cursorRow < buf.lines.lastIndex) {
                buf.cursorRow += 1
                buf.cursorCol = 0
            }
        }
        ensureCursorVisible()
    }

    private fun moveLineEdge(toEnd: Boolean, extendSelection: Boolean) {
        quitWarned = false
        killRing.breakChain()
        val buf = activeBuffer()
        if (extendSelection) {
            if (buf.anchor == null) buf.anchor = buf.cursorPos()
        } else {
            buf.anchor = null
        }
        buf.cursorCol = if (toEnd) UnicodeWidth.codePointCount(buf.lines[buf.cursorRow]) else 0
        ensureCursorVisible()
    }

    private fun movePage(dir: Int) {
        quitWarned = false
        killRing.breakChain()
        val buf = activeBuffer()
        buf.anchor = null
        val step = max(1, textRows() - 1) * dir
        buf.cursorRow = (buf.cursorRow + step).coerceIn(0, buf.lines.lastIndex)
        ensureCursorVisible()
    }

    private fun moveWord(forward: Boolean, keepKillChain: Boolean = false) {
        if (!keepKillChain) killRing.breakChain()
        val buf = activeBuffer()
        buf.anchor = null
        if (forward) {
            var r = buf.cursorRow
            var c = buf.cursorCol
            while (r < buf.lines.size) {
                val cps = UnicodeWidth.codePointsList(buf.lines[r])
                if (c >= cps.size) {
                    if (r < buf.lines.lastIndex) {
                        r++
                        c = 0
                        buf.cursorRow = r
                        buf.cursorCol = c
                        return
                    }
                    break
                }
                while (c < cps.size && !UnicodeWidth.isWordChar(cps[c])) c++
                while (c < cps.size && UnicodeWidth.isWordChar(cps[c])) c++
                buf.cursorRow = r
                buf.cursorCol = c
                return
            }
        } else {
            var r = buf.cursorRow
            var c = buf.cursorCol
            if (c == 0) {
                if (r > 0) {
                    buf.cursorRow = r - 1
                    buf.cursorCol = UnicodeWidth.codePointCount(buf.lines[buf.cursorRow])
                }
                return
            }
            val cps = UnicodeWidth.codePointsList(buf.lines[r])
            while (c > 0 && !UnicodeWidth.isWordChar(cps[c - 1])) c--
            while (c > 0 && UnicodeWidth.isWordChar(cps[c - 1])) c--
            buf.cursorCol = c
        }
    }

    // MARK: - Mouse & Viewport Scroll

    private fun handleMouseClick(screenCol: Int, screenRow: Int, isDrag: Boolean) {
        killRing.breakChain()
        val buf = activeBuffer()
        if (!isDrag && screenRow == 1) {
            clickTabBar(screenCol)
            return
        }
        val textStartRow = 2
        val textEndRow = 1 + textRows()
        if (screenRow !in textStartRow..textEndRow) return

        val targetRow = (buf.rowOffset + (screenRow - textStartRow)).coerceIn(0, buf.lines.lastIndex)
        val gw = gutterWidth()
        val visualCol = max(0, screenCol - 1 - gw) + buf.colOffset
        val targetCol = UnicodeWidth.visualColToCodePointIndex(buf.lines[targetRow], visualCol, tabWidth, isEaw)

        if (isDrag) {
            if (buf.anchor == null) buf.anchor = buf.cursorPos()
        } else {
            buf.anchor = Pos(targetRow, targetCol)
        }
        buf.cursorRow = targetRow
        buf.cursorCol = targetCol
        buf.clampCursor()
    }

    private fun clickTabBar(col: Int) {
        var cur = 1
        for (i in buffers.indices) {
            val label = tabLabel(i, buffers[i])
            val end = cur + UnicodeWidth.sanitizeForTerminal(label, tabWidth, isEaw).visualWidth
            if (col in cur until end) {
                activeBufIdx = i
                ensureCursorVisible()
                return
            }
            cur = end
        }
    }

    /**
     * ビューポートのみスクロールする（cursorRow を引っ張らない）。
     */
    fun scrollViewport(delta: Int) {
        val buf = activeBuffer()
        val maxOffset = max(0, buf.lines.size - 1)
        buf.rowOffset = (buf.rowOffset + delta).coerceIn(0, maxOffset)
    }

    // MARK: - Multi-buffer & Action Bar / Search Prompts

    fun switchBuffer(delta: Int) {
        if (buffers.size <= 1) return
        killRing.breakChain()
        activeBufIdx = (activeBufIdx + delta + buffers.size) % buffers.size
        statusMessage = "Buffer ${activeBufIdx + 1}/${buffers.size}: ${activeBuffer().filename}"
        ensureCursorVisible()
    }

    fun closeCurrentBuffer(force: Boolean) {
        val buf = activeBuffer()
        if (buf.isModified && !force) {
            statusMessage = "Unsaved changes! Save or use Action 'bd!' / 'q!'"
            return
        }
        if (buffers.size <= 1) {
            buffers[0] = TextBuffer()
            activeBufIdx = 0
            statusMessage = "Cleared last buffer"
        } else {
            buffers.removeAt(activeBufIdx)
            if (activeBufIdx >= buffers.size) activeBufIdx = buffers.lastIndex
            statusMessage = "Closed buffer"
        }
    }

    fun requestQuit(force: Boolean) {
        val dirtyCount = buffers.count { it.isModified }
        if (dirtyCount > 0 && !force && !quitWarned) {
            quitWarned = true
            statusMessage = "WARNING: $dirtyCount unsaved buffer(s). Press Ctrl+Q again to discard and quit."
            return
        }
        isRunning = false
    }

    private fun handlePromptEvent(ev: InputEvent) {
        when (ev) {
            InputEvent.Esc, InputEvent.Ctrl('g') -> {
                promptMode = PromptMode.NONE
                promptInput = ""
                statusMessage = "Cancelled"
            }
            InputEvent.Enter -> {
                val mode = promptMode
                val text = promptInput
                promptMode = PromptMode.NONE
                promptInput = ""
                executePrompt(mode, text)
            }
            InputEvent.Backspace -> {
                if (promptInput.isNotEmpty()) {
                    val cpLen = UnicodeWidth.codePointCount(promptInput)
                    promptInput = UnicodeWidth.sliceCodePoints(promptInput, 0, cpLen - 1)
                    if (promptMode == PromptMode.SEARCH) performIncrementalSearch(promptInput)
                }
            }
            is InputEvent.CharInput -> {
                promptInput += ev.text
                if (promptMode == PromptMode.SEARCH) performIncrementalSearch(promptInput)
            }
            InputEvent.Ctrl('f') -> {
                if (promptMode == PromptMode.SEARCH && promptInput.isNotEmpty()) {
                    performIncrementalSearch(promptInput, fromNextChar = true)
                }
            }
            else -> Unit
        }
    }

    private fun executePrompt(mode: PromptMode, raw: String) {
        val cmd = raw.trim()
        when (mode) {
            PromptMode.SEARCH -> {
                searchQuery = cmd
                performIncrementalSearch(cmd, fromNextChar = false)
            }
            PromptMode.OPEN_FILE -> if (cmd.isNotEmpty()) openFile(cmd)
            PromptMode.SAVE_AS -> if (cmd.isNotEmpty()) saveActiveBuffer(cmd)
            PromptMode.ACTION -> runActionCommand(cmd)
            PromptMode.NONE -> Unit
        }
    }

    fun runActionCommand(raw: String) {
        val parts = raw.trim().split(Regex("\\s+"), limit = 2)
        val cmd = parts.getOrNull(0)?.lowercase().orEmpty()
        val arg = parts.getOrNull(1)?.trim().orEmpty()
        when (cmd) {
            "" -> Unit
            "save", "w" -> saveActiveBuffer(arg.ifEmpty { null })
            "open", "e" -> if (arg.isNotEmpty()) openFile(arg) else statusMessage = "Usage: open <file>"
            "new" -> {
                buffers.add(TextBuffer())
                activeBufIdx = buffers.lastIndex
                statusMessage = "New buffer"
            }
            "next", "bn" -> switchBuffer(1)
            "prev", "bp" -> switchBuffer(-1)
            "close", "bd" -> closeCurrentBuffer(force = false)
            "bd!" -> closeCurrentBuffer(force = true)
            "goto", "g" -> {
                val n = arg.toIntOrNull()
                if (n != null && n >= 1) {
                    val buf = activeBuffer()
                    buf.cursorRow = (n - 1).coerceIn(0, buf.lines.lastIndex)
                    buf.cursorCol = 0
                    buf.anchor = null
                    ensureCursorVisible()
                    statusMessage = "Jumped to line ${buf.cursorRow + 1}"
                } else {
                    statusMessage = "Usage: goto <line>"
                }
            }
            "dup" -> duplicateCurrentLine(activeBuffer())
            "killring", "kr" -> openKillRingModal()
            "eaw" -> {
                isEaw = !isEaw
                statusMessage = "EAW mode: ${if (isEaw) "WIDE (2)" else "NARROW (1)"}"
                ensureCursorVisible()
            }
            "quit", "q" -> requestQuit(force = false)
            "quit!", "q!" -> requestQuit(force = true)
            "wq" -> if (saveActiveBuffer(arg.ifEmpty { null })) requestQuit(force = true)
            else -> statusMessage = "Unknown action: $cmd"
        }
    }

    fun performIncrementalSearch(query: String, fromNextChar: Boolean = false) {
        searchQuery = query
        if (query.isEmpty()) return
        val buf = activeBuffer()
        val startRow = buf.cursorRow
        val startOffset = if (fromNextChar) buf.cursorCol + 1 else buf.cursorCol

        for (step in buf.lines.indices) {
            val r = (startRow + step) % buf.lines.size
            val line = buf.lines[r]
            val fromCp = if (step == 0) startOffset.coerceAtMost(UnicodeWidth.codePointCount(line)) else 0
            val charStart = line.offsetByCodePoints(0, fromCp)
            val foundCharIdx = line.indexOf(query, startIndex = charStart, ignoreCase = true)
            if (foundCharIdx >= 0) {
                buf.cursorRow = r
                buf.cursorCol = line.codePointCount(0, foundCharIdx)
                buf.anchor = null
                ensureCursorVisible()
                statusMessage = "Found \"$query\" at Ln ${r + 1}, Col ${buf.cursorCol + 1}"
                return
            }
        }
        statusMessage = "Not found: \"$query\""
    }

    // MARK: - Rendering (Pure ANSI output, no \x1b[2J per frame)

    private fun tabLabel(index: Int, buf: TextBuffer): String {
        val name = File(buf.filename).name.ifEmpty { buf.filename }
        val mod = if (buf.isModified) "*" else ""
        return if (index == activeBufIdx) " [${index + 1}: $name$mod] " else "  ${index + 1}: $name$mod  "
    }

    fun render(): String {
        val buf = activeBuffer()
        val tr = textRows()
        val gw = gutterWidth()
        val digits = gw - 3
        val textCols = max(1, cols - gw)
        val sel = buf.normalizedSelection()

        val out = StringBuilder(4096)
        out.append("\u001B[?2026h\u001B[?25l\u001B[H")

        // 1. Row 1: Tab Bar
        out.append("\u001B[7m")
        val tabBar = StringBuilder()
        for (i in buffers.indices) {
            tabBar.append(tabLabel(i, buffers[i]))
        }
        val tabVis = clipVisual(tabBar.toString(), max(1, cols - 1))
        out.append(tabVis).append("\u001B[0m\u001B[K\r\n")

        // 2. Text Area (Rows 2 .. rows - 2)
        for (i in 0 until tr) {
            val lineIdx = buf.rowOffset + i
            if (lineIdx < buf.lines.size) {
                val numStr = (lineIdx + 1).toString().padStart(digits, ' ')
                out.append("\u001B[90m").append(numStr).append(" │ \u001B[0m")
                out.append(renderLineSlice(buf.lines[lineIdx], lineIdx, buf.colOffset, textCols, sel))
            } else {
                out.append("\u001B[90m~").append(" ".repeat(max(0, gw - 1))).append("\u001B[0m")
            }
            out.append("\u001B[K\r\n")
        }

        // 3. Status Bar (Row rows - 1)
        val ringHead = killRing.currentEntry()?.let { previewEntry(it, 18) } ?: "(empty)"
        val modFlag = if (buf.isModified) " [+]" else ""
        val statusLeft = " ${buf.filename}$modFlag | Ring[${killRing.size}]: \"$ringHead\" | EC:${buf.editorConfig.shortLabel()}"
        val statusRight = " Ln ${buf.cursorRow + 1}/${buf.lines.size}, Col ${buf.cursorCol + 1} "
        val barWidth = max(1, cols - 1)
        val leftClip = clipVisual(statusLeft, max(0, barWidth - UnicodeWidth.sanitizeForTerminal(statusRight, tabWidth, isEaw).visualWidth))
        val leftW = UnicodeWidth.sanitizeForTerminal(leftClip, tabWidth, isEaw).visualWidth
        val rightW = UnicodeWidth.sanitizeForTerminal(statusRight, tabWidth, isEaw).visualWidth
        val pad = max(0, barWidth - leftW - rightW)
        out.append("\u001B[7m").append(leftClip).append(" ".repeat(pad)).append(statusRight).append("\u001B[0m\u001B[K\r\n")

        // 4. Bottom Action / Search / Message Line (Row rows)
        val bottomText = when (promptMode) {
            PromptMode.ACTION -> "Action> $promptInput"
            PromptMode.SEARCH -> "Search: $promptInput"
            PromptMode.OPEN_FILE -> "Open file: $promptInput"
            PromptMode.SAVE_AS -> "Save as: $promptInput"
            PromptMode.NONE -> statusMessage
        }
        out.append(clipVisual(UnicodeWidth.sanitizeForTerminal(bottomText, tabWidth, isEaw).displayText, max(1, cols - 1)))
        out.append("\u001B[K")

        // Optional Kill Ring Modal Overlay
        if (showingKillRingModal) {
            appendKillRingOverlay(out)
        }

        // 5. Cursor positioning (1-indexed CUP)
        if (promptMode != PromptMode.NONE) {
            val prefixLen = when (promptMode) {
                PromptMode.ACTION -> "Action> ".length
                PromptMode.SEARCH -> "Search: ".length
                PromptMode.OPEN_FILE -> "Open file: ".length
                PromptMode.SAVE_AS -> "Save as: ".length
                PromptMode.NONE -> 0
            }
            val pWidth = UnicodeWidth.sanitizeForTerminal(promptInput, tabWidth, isEaw).visualWidth
            val cx = min(cols, prefixLen + pWidth + 1)
            out.append("\u001B[").append(rows).append(';').append(cx).append("H\u001B[?25h")
        } else if (!showingKillRingModal) {
            val screenY = 2 + (buf.cursorRow - buf.rowOffset)
            val vx = UnicodeWidth.visualWidthUpTo(buf.lines[buf.cursorRow], buf.cursorCol, tabWidth, isEaw)
            val screenX = 1 + gw + (vx - buf.colOffset)
            if (screenY in 2..(rows - 2) && screenX in (1 + gw)..cols) {
                out.append("\u001B[").append(screenY).append(';').append(screenX).append("H\u001B[?25h")
            } else {
                out.append("\u001B[?25l")
            }
        }

        out.append("\u001B[?2026l")
        return out.toString()
    }

    private fun renderLineSlice(
        line: String,
        rowIdx: Int,
        colOffset: Int,
        maxCols: Int,
        sel: Pair<Pos, Pos>?,
    ): String {
        val sb = StringBuilder()
        var col = 0
        var cpIdx = 0
        var i = 0
        var activeStyle = false

        while (i < line.length) {
            val cp = line.codePointAt(i)
            val pos = Pos(rowIdx, cpIdx)
            val inSel = sel != null && pos >= sel.first && pos < sel.second
            val disp: String
            val w: Int
            when {
                cp == '\t'.code -> {
                    w = tabWidth - (col % tabWidth)
                    disp = " ".repeat(w)
                }
                cp < 0x20 -> {
                    w = 2
                    disp = "^" + (cp + 64).toChar()
                }
                cp == 0x7F -> {
                    w = 2
                    disp = "^?"
                }
                cp in 0x80..0x9F -> {
                    w = 1
                    disp = "?"
                }
                else -> {
                    w = UnicodeWidth.charWidth(cp, isEaw)
                    disp = String(Character.toChars(cp))
                }
            }

            if (col + w > colOffset && col < colOffset + maxCols) {
                if (inSel && !activeStyle) {
                    sb.append("\u001B[44;97m")
                    activeStyle = true
                } else if (!inSel && activeStyle) {
                    sb.append("\u001B[0m")
                    activeStyle = false
                }
                // 境界クリップ (全角が半分はみ出る場合は描画しない)
                if (col >= colOffset && col + w <= colOffset + maxCols) {
                    sb.append(disp)
                } else if (disp.all { it == ' ' }) {
                    val visSpaces = min(col + w, colOffset + maxCols) - max(col, colOffset)
                    if (visSpaces > 0) sb.append(" ".repeat(visSpaces))
                } else {
                    sb.append(' ')
                }
            }

            col += w
            cpIdx += 1
            i += Character.charCount(cp)
            if (col >= colOffset + maxCols) break
        }

        if (sel != null && rowIdx >= sel.first.row && rowIdx < sel.second.row && col - colOffset < maxCols) {
            if (!activeStyle) sb.append("\u001B[44;97m")
            sb.append(' ')
            activeStyle = true
        }
        if (activeStyle) sb.append("\u001B[0m")
        return sb.toString()
    }

    private fun appendKillRingOverlay(out: StringBuilder) {
        val items = killRing.snapshot()
        val maxShow = min(9, items.size)
        val boxW = min(max(36, cols - 8), 72)
        val startCol = max(2, (cols - boxW) / 2)
        val startRow = 3

        out.append("\u001B[").append(startRow).append(';').append(startCol).append("H\u001B[7m")
        out.append(clipVisual(" Kill Ring (${items.size}) [Enter/1-9: Yank, Esc: Close] ".padEnd(boxW, ' '), boxW))
        out.append("\u001B[0m")

        for (i in 0 until maxShow) {
            val r = startRow + 1 + i
            if (r >= rows - 1) break
            val selected = i == killRingSelectedIdx
            val preview = previewEntry(items[i], boxW - 10)
            val line = " ${if (selected) '>' else ' '} [${i + 1}] $preview".padEnd(boxW, ' ')
            out.append("\u001B[").append(r).append(';').append(startCol).append('H')
            if (selected) out.append("\u001B[44;97m") else out.append("\u001B[48;5;236;97m")
            out.append(clipVisual(line, boxW)).append("\u001B[0m")
        }
    }

    private fun clipVisual(str: String, maxWidth: Int): String {
        if (maxWidth <= 0) return ""
        val sb = StringBuilder()
        var w = 0
        var i = 0
        while (i < str.length) {
            val cp = str.codePointAt(i)
            val cw = UnicodeWidth.charWidth(cp, isEaw)
            if (w + cw > maxWidth) break
            sb.appendCodePoint(cp)
            w += cw
            i += Character.charCount(cp)
        }
        return sb.toString()
    }

    private fun previewEntry(s: String, maxWidth: Int): String {
        val singleLine = s.replace("\n", "\\n").replace("\t", "\\t")
        return clipVisual(singleLine, maxWidth)
    }
}
