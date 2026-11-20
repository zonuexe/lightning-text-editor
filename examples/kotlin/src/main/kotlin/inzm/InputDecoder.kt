package inzm

sealed interface InputEvent {
    data class CharInput(val text: String) : InputEvent
    data class Ctrl(val letter: Char) : InputEvent
    data class Alt(val letter: Char) : InputEvent
    data object Enter : InputEvent
    data object AltEnter : InputEvent
    data object Backspace : InputEvent
    data object AltBackspace : InputEvent
    data object Delete : InputEvent
    data object Tab : InputEvent
    data object Esc : InputEvent
    data object Up : InputEvent
    data object Down : InputEvent
    data object Left : InputEvent
    data object Right : InputEvent
    data object Home : InputEvent
    data object End : InputEvent
    data object PageUp : InputEvent
    data object PageDown : InputEvent
    data object ShiftUp : InputEvent
    data object ShiftDown : InputEvent
    data object ShiftLeft : InputEvent
    data object ShiftRight : InputEvent
    data object ShiftHome : InputEvent
    data object ShiftEnd : InputEvent
    data object AltLeft : InputEvent
    data object AltRight : InputEvent
    data object F2 : InputEvent
    data object CtrlSpace : InputEvent
    data class MouseLeftPress(val col: Int, val row: Int) : InputEvent
    data class MouseDrag(val col: Int, val row: Int) : InputEvent
    data object MouseRelease : InputEvent
    data object MouseWheelUp : InputEvent
    data object MouseWheelDown : InputEvent
    data class Paste(val text: String) : InputEvent
    data object UnknownEscape : InputEvent
}

/**
 * チャンク分断・結合、UTF-8マルチバイト境界、Alt+Key (ESC + key)、
 * SGR 1006 マウス、Bracketed Paste を扱うストリーミング入力デコーダ。
 */
class InputDecoder {
    private val buf = ArrayList<Byte>()

    fun feed(bytes: ByteArray, length: Int = bytes.size): List<InputEvent> {
        for (i in 0 until length) {
            buf.add(bytes[i])
        }
        return drain(timedOut = false)
    }

    fun flushTimeout(): List<InputEvent> = drain(timedOut = true)

    fun hasPendingEscape(): Boolean = buf.isNotEmpty() && buf[0] == 0x1B.toByte()

    private fun drain(timedOut: Boolean): List<InputEvent> {
        val events = ArrayList<InputEvent>()
        while (buf.isNotEmpty()) {
            val ev = decodeNext(timedOut) ?: break
            events.add(ev)
        }
        return events
    }

    private fun decodeNext(timedOut: Boolean): InputEvent? {
        if (buf.isEmpty()) return null
        val b0 = buf[0].toInt() and 0xFF

        if (b0 == 0x1B) {
            return decodeEscape(timedOut)
        }

        // Control keys (ASCII 0x00..0x1F, 0x7F)
        if (b0 == 0x00) {
            buf.removeAt(0)
            return InputEvent.CtrlSpace
        }
        if (b0 == 0x0D || b0 == 0x0A) {
            buf.removeAt(0)
            return InputEvent.Enter
        }
        if (b0 == 0x09) {
            buf.removeAt(0)
            return InputEvent.Tab
        }
        if (b0 == 0x7F || b0 == 0x08) {
            buf.removeAt(0)
            return InputEvent.Backspace
        }
        if (b0 in 1..26) {
            buf.removeAt(0)
            return InputEvent.Ctrl(('a'.code + b0 - 1).toChar())
        }
        if (b0 < 0x20) {
            buf.removeAt(0)
            return InputEvent.UnknownEscape
        }

        // UTF-8 character decoding with boundary protection
        val expectedLen = utf8SeqLength(b0)
        if (buf.size < expectedLen) {
            if (!timedOut) return null
            // Broken tail on timeout: drop 1 byte cleanly
            buf.removeAt(0)
            return InputEvent.CharInput("\uFFFD")
        }
        val slice = ByteArray(expectedLen) { buf[it] }
        repeat(expectedLen) { buf.removeAt(0) }
        val chStr = String(slice, Charsets.UTF_8)
        return InputEvent.CharInput(chStr)
    }

    private fun utf8SeqLength(leadByte: Int): Int = when {
        leadByte < 0x80 -> 1
        (leadByte and 0xE0) == 0xC0 -> 2
        (leadByte and 0xF0) == 0xE0 -> 3
        (leadByte and 0xF8) == 0xF0 -> 4
        else -> 1
    }

    private fun decodeEscape(timedOut: Boolean): InputEvent? {
        if (buf.size == 1) {
            if (!timedOut) return null
            buf.removeAt(0)
            return InputEvent.Esc
        }

        val b1 = buf[1].toInt() and 0xFF
        if (b1 == '['.code) {
            return decodeCSI(timedOut)
        }
        if (b1 == 'O'.code) {
            if (buf.size < 3) {
                if (!timedOut) return null
                buf.removeAt(0)
                return InputEvent.Esc
            }
            val b2 = buf[2].toInt() and 0xFF
            repeat(3) { buf.removeAt(0) }
            return when (b2) {
                'A'.code -> InputEvent.Up
                'B'.code -> InputEvent.Down
                'C'.code -> InputEvent.Right
                'D'.code -> InputEvent.Left
                'H'.code -> InputEvent.Home
                'F'.code -> InputEvent.End
                'Q'.code -> InputEvent.F2
                else -> InputEvent.UnknownEscape
            }
        }

        // Alt+Key (ESC + byte)
        buf.removeAt(0) // drop ESC
        buf.removeAt(0) // drop key byte
        return when (b1) {
            0x0D, 0x0A -> InputEvent.AltEnter
            0x7F, 0x08 -> InputEvent.AltBackspace
            else -> {
                if (b1 in 0x20..0x7E) {
                    InputEvent.Alt(b1.toChar().lowercaseChar())
                } else {
                    InputEvent.UnknownEscape
                }
            }
        }
    }

    private fun decodeCSI(timedOut: Boolean): InputEvent? {
        // Bracketed Paste: \x1b[200~ ... \x1b[201~
        val pasteStart = "\u001B[200~".toByteArray()
        val pasteEnd = "\u001B[201~".toByteArray()
        if (startsWith(pasteStart)) {
            val endIdx = indexOfBytes(pasteEnd, startFrom = pasteStart.size)
            if (endIdx < 0) {
                if (!timedOut) return null
                // Incomplete paste on timeout: discard marker safely
                repeat(pasteStart.size) { buf.removeAt(0) }
                return InputEvent.UnknownEscape
            }
            val payload = ByteArray(endIdx - pasteStart.size) { buf[pasteStart.size + it] }
            repeat(endIdx + pasteEnd.size) { buf.removeAt(0) }
            return InputEvent.Paste(String(payload, Charsets.UTF_8))
        }

        // Wait for final byte 0x40..0x7E
        var finalIdx = -1
        for (i in 2 until buf.size) {
            val b = buf[i].toInt() and 0xFF
            if (b in 0x40..0x7E) {
                finalIdx = i
                break
            }
        }
        if (finalIdx < 0) {
            if (!timedOut) return null
            repeat(2) { buf.removeAt(0) }
            return InputEvent.UnknownEscape
        }

        val seqBytes = ByteArray(finalIdx - 1) { buf[2 + it] }
        repeat(finalIdx + 1) { buf.removeAt(0) }
        val seq = String(seqBytes, Charsets.US_ASCII)

        // SGR Mouse: <btn;col;rowM or m
        if (seq.startsWith("<")) {
            val isRelease = seq.endsWith("m")
            val parts = seq.substring(1, seq.length - 1).split(';')
            if (parts.size == 3) {
                val btn = parts[0].toIntOrNull()
                val col = parts[1].toIntOrNull()
                val row = parts[2].toIntOrNull()
                if (btn != null && col != null && row != null) {
                    return when {
                        btn == 64 -> InputEvent.MouseWheelUp
                        btn == 65 -> InputEvent.MouseWheelDown
                        btn == 32 && !isRelease -> InputEvent.MouseDrag(col, row)
                        btn == 0 && !isRelease -> InputEvent.MouseLeftPress(col, row)
                        btn == 0 && isRelease -> InputEvent.MouseRelease
                        else -> InputEvent.UnknownEscape
                    }
                }
            }
            return InputEvent.UnknownEscape
        }

        return when (seq) {
            "A" -> InputEvent.Up
            "B" -> InputEvent.Down
            "C" -> InputEvent.Right
            "D" -> InputEvent.Left
            "H", "1~", "7~" -> InputEvent.Home
            "F", "4~", "8~" -> InputEvent.End
            "3~" -> InputEvent.Delete
            "5~" -> InputEvent.PageUp
            "6~" -> InputEvent.PageDown
            "1;2A" -> InputEvent.ShiftUp
            "1;2B" -> InputEvent.ShiftDown
            "1;2C" -> InputEvent.ShiftRight
            "1;2D" -> InputEvent.ShiftLeft
            "1;2H" -> InputEvent.ShiftHome
            "1;2F" -> InputEvent.ShiftEnd
            "1;3C", "1;5C" -> InputEvent.AltRight
            "1;3D", "1;5D" -> InputEvent.AltLeft
            "12~" -> InputEvent.F2
            "13;2u", "13;5u" -> InputEvent.AltEnter // optional Kitty Ctrl/Shift+Enter
            else -> InputEvent.UnknownEscape
        }
    }

    private fun startsWith(prefix: ByteArray): Boolean {
        if (buf.size < prefix.size) return false
        for (i in prefix.indices) {
            if (buf[i] != prefix[i]) return false
        }
        return true
    }

    private fun indexOfBytes(needle: ByteArray, startFrom: Int): Int {
        outer@ for (i in startFrom..(buf.size - needle.size)) {
            for (j in needle.indices) {
                if (buf[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
