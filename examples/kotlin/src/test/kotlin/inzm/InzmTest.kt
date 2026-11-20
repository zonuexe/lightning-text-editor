package inzm

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.io.File
import java.nio.file.Files

class InzmTest {

    @Test
    fun `kill ring appends consecutive kills and resets on non-kill action`() {
        val ring = KillRing(capacity = 4)
        ring.pushKill("hello ")
        ring.pushKill("world") // consecutive kill appends
        assertEquals(1, ring.size)
        assertEquals("hello world", ring.snapshot()[0])

        ring.breakChain()
        ring.pushKill("second")
        assertEquals(2, ring.size)
        assertEquals(listOf("second", "hello world"), ring.snapshot())
    }

    @Test
    fun `yank and Alt+Y yank-pop cycles through kill ring in-place`() {
        val ed = EditorCore(cols = 80, rows = 24)
        val buf = ed.activeBuffer()
        buf.lines[0] = "alpha"
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Ctrl('k')) // kill 1 -> "alpha"
        buf.lines[0] = "beta"
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Left) // break chain
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Ctrl('k')) // kill 2 -> "beta"
        buf.lines[0] = "gamma"
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Left) // break chain
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Ctrl('k')) // kill 3 -> "gamma"

        // Paste on clean line
        buf.lines[0] = ">"
        buf.cursorCol = 1
        ed.handleEvent(InputEvent.Ctrl('y'))
        assertEquals(">gamma", buf.lines[0])

        // Alt+Y replaces "gamma" with "beta"
        ed.handleEvent(InputEvent.Alt('y'))
        assertEquals(">beta", buf.lines[0])

        // Next Alt+Y replaces "beta" with "alpha"
        ed.handleEvent(InputEvent.Alt('y'))
        assertEquals(">alpha", buf.lines[0])

        // Wraps around back to "gamma"
        ed.handleEvent(InputEvent.Alt('y'))
        assertEquals(">gamma", buf.lines[0])
    }

    @Test
    fun `yank-pop does nothing if previous command was not yank`() {
        val ed = EditorCore()
        val buf = ed.activeBuffer()
        buf.lines[0] = "abc"
        buf.cursorCol = 0
        ed.handleEvent(InputEvent.Ctrl('k'))
        ed.handleEvent(InputEvent.CharInput("X"))
        ed.handleEvent(InputEvent.Alt('y'))
        assertEquals("X", buf.lines[0])
        assertTrue(ed.statusMessage.contains("not a yank"))
    }

    @Test
    fun `jEdit Ctrl+E two-stroke chord and Action Bar work properly`() {
        val ed = EditorCore(cols = 80, rows = 24)
        val buf = ed.activeBuffer()
        buf.lines[0] = "line one"
        buf.lines.add("line two")

        // Ctrl+E followed by 'd' duplicates current line
        ed.handleEvent(InputEvent.Ctrl('e'))
        ed.handleEvent(InputEvent.CharInput("d"))
        assertEquals(listOf("line one", "line one", "line two"), buf.lines)

        // Action Bar: goto 3
        ed.handleEvent(InputEvent.F2)
        for (ch in "goto 3") {
            ed.handleEvent(InputEvent.CharInput(ch.toString()))
        }
        ed.handleEvent(InputEvent.Enter)
        assertEquals(2, buf.cursorRow)
    }

    @Test
    fun `unicode wide characters, tab sanitization, and SGR mouse click match gutterWidth`() {
        val ed = EditorCore(cols = 80, rows = 24, isEaw = false)
        val buf = ed.activeBuffer()
        buf.lines[0] = "あ🍣x"
        val gw = ed.gutterWidth() // digits(3) + 3 = 6
        // Row 1 = tab bar, Row 2 = line 1. "あ" occupies cols (1+gw)..(1+gw+1), "🍣" occupies (1+gw+2)..(1+gw+3)
        // Clicking on 'x' at 1-indexed screen column (1 + gw + 4)
        ed.handleEvent(InputEvent.MouseLeftPress(col = 1 + gw + 4, row = 2))
        assertEquals(2, buf.cursorCol) // code point index 2 ('x')

        // Viewport-only wheel scroll does not drag cursor back
        for (i in 1..40) buf.lines.add("line $i")
        buf.cursorRow = 0
        ed.handleEvent(InputEvent.MouseWheelDown)
        assertEquals(3, buf.rowOffset)
        assertEquals(0, buf.cursorRow)
    }

    @Test
    fun `streaming input decoder parses Alt+Y, split UTF-8, SGR mouse, and bare Esc`() {
        val dec = InputDecoder()
        // Split ESC + 'y' -> Alt('y')
        assertTrue(dec.feed(byteArrayOf(0x1B)).isEmpty())
        assertTrue(dec.hasPendingEscape())
        assertEquals(listOf(InputEvent.Alt('y')), dec.feed(byteArrayOf('y'.code.toByte())))

        // Bare Esc via timeout
        assertTrue(dec.feed(byteArrayOf(0x1B)).isEmpty())
        assertEquals(listOf(InputEvent.Esc), dec.flushTimeout())

        // Split UTF-8 'あ' (E3 81 82)
        assertTrue(dec.feed(byteArrayOf(0xE3.toByte(), 0x81.toByte())).isEmpty())
        assertEquals(listOf(InputEvent.CharInput("あ")), dec.feed(byteArrayOf(0x82.toByte())))

        // SGR mouse wheel + bracketed paste
        val events = dec.feed("\u001B[<64;10;5M\u001B[200~hello\u001B[201~".toByteArray())
        assertEquals(listOf(InputEvent.MouseWheelUp, InputEvent.Paste("hello")), events)
    }

    @Test
    fun `save applies EditorConfig formatting`() {
        val dir = Files.createTempDirectory("inzm-kt-test").toFile()
        try {
            File(dir, ".editorconfig").writeText(
                """
                root = true
                [*]
                trim_trailing_whitespace = true
                insert_final_newline = true
                """.trimIndent()
            )
            val target = File(dir, "demo.txt")
            val ed = EditorCore()
            ed.openFile(target.absolutePath)
            ed.activeBuffer().lines[0] = "hello   "
            assertTrue(ed.saveActiveBuffer())
            assertEquals("hello\n", target.readText(Charsets.UTF_8))
        } finally {
            dir.deleteRecursively()
        }
    }
}
