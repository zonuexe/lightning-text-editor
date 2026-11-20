package inzm

import java.io.InputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.system.exitProcess

private sealed interface LoopMsg {
    data class Bytes(val data: ByteArray, val len: Int) : LoopMsg
    data object Eof : LoopMsg
    data object Winch : LoopMsg
    data object Terminate : LoopMsg
}

private class SttyGuard {
    private var origStty: String? = null
    private var active = false

    fun enterRawMode() {
        origStty = runSttyCapture("-g")?.trim()?.takeIf { it.isNotEmpty() }
        // raw disables canonical mode, echo, signals (intr/quit/susp/dsusp), iexten (werase/lnext/discard), and opost
        runStty("raw", "-echo", "-ixon", "-icrnl")
        active = true
    }

    @Synchronized
    fun restore() {
        if (!active) return
        active = false
        // Flush terminal cleanup sequences BEFORE restoring stty
        System.out.print("\u001B[?2004l\u001B[?1006l\u001B[?1002l\u001B[?1049l\u001B[?25h\u001B[0m")
        System.out.flush()
        val orig = origStty
        if (orig != null) {
            runStty(orig)
        } else {
            runStty("sane")
        }
    }

    private fun runStty(vararg args: String) {
        runCatching {
            val cmd = listOf("/bin/stty") + args
            ProcessBuilder(cmd)
                .redirectInput(ProcessBuilder.Redirect.INHERIT)
                .start()
                .waitFor()
        }
    }

    private fun runSttyCapture(vararg args: String): String? {
        return runCatching {
            val cmd = listOf("/bin/stty") + args
            val proc = ProcessBuilder(cmd)
                .redirectInput(ProcessBuilder.Redirect.INHERIT)
                .start()
            val out = proc.inputStream.bufferedReader().readText()
            proc.waitFor()
            out
        }.getOrNull()
    }
}

private fun queryTerminalSize(): Pair<Int, Int> {
    return runCatching {
        val proc = ProcessBuilder("/bin/stty", "size")
            .redirectInput(ProcessBuilder.Redirect.INHERIT)
            .start()
        val out = proc.inputStream.bufferedReader().readText().trim()
        proc.waitFor()
        val parts = out.split(Regex("\\s+"))
        if (parts.size == 2) {
            val r = parts[0].toInt()
            val c = parts[1].toInt()
            if (c > 0 && r > 0) return c to r
        }
        80 to 24
    }.getOrDefault(80 to 24)
}

/**
 * 起動時 1 回のみ DSR (\x1b[6n) で端末が曖昧文字 '※' を 1 列か 2 列のどちらで描画するか実測する。
 */
private fun probeEaw(stdin: InputStream): Boolean {
    return runCatching {
        System.out.print("\u001B7\u001B[1;1H\u001B[2K\u001B[8m※\u001B[6n\u001B[0m\u001B[1;1H\u001B[2K\u001B8")
        System.out.flush()
        val sb = StringBuilder()
        val deadline = System.nanoTime() + 120_000_000L
        while (System.nanoTime() < deadline) {
            if (stdin.available() > 0) {
                val b = stdin.read()
                if (b < 0) break
                sb.append(b.toChar())
                if (b == 'R'.code && sb.contains("\u001B[")) break
            } else {
                Thread.sleep(2)
            }
        }
        val match = Regex("\u001B\\[\\d+;(\\d+)R").find(sb.toString())
        val col = match?.groupValues?.getOrNull(1)?.toIntOrNull()
        (col ?: 2) >= 3
    }.getOrDefault(false)
}

fun main(args: Array<String>) {
    if (System.console() == null) {
        System.err.println("Error: inzm requires an interactive TTY terminal.")
        exitProcess(1)
    }

    val guard = SttyGuard()
    guard.enterRawMode()
    Runtime.getRuntime().addShutdownHook(Thread { guard.restore() })

    val (initCols, initRows) = queryTerminalSize()
    val detectedEaw = probeEaw(System.`in`)

    val editor = EditorCore(cols = initCols, rows = initRows, isEaw = detectedEaw)
    if (args.isNotEmpty()) {
        for (arg in args) {
            editor.openFile(arg)
        }
    }

    val queue = LinkedBlockingQueue<LoopMsg>()

    // Signal integration into single event loop via sun.misc.Signal (non-blocking)
    runCatching {
        sun.misc.Signal.handle(sun.misc.Signal("WINCH")) { queue.offer(LoopMsg.Winch) }
        sun.misc.Signal.handle(sun.misc.Signal("TERM")) { queue.offer(LoopMsg.Terminate) }
        sun.misc.Signal.handle(sun.misc.Signal("INT")) { queue.offer(LoopMsg.Terminate) }
    }

    // Raw stdin reader thread
    thread(isDaemon = true, name = "inzm-stdin") {
        val buf = ByteArray(1024)
        while (true) {
            val n = runCatching { System.`in`.read(buf) }.getOrDefault(-1)
            if (n < 0) {
                queue.offer(LoopMsg.Eof)
                break
            }
            if (n > 0) {
                queue.offer(LoopMsg.Bytes(buf.copyOf(n), n))
            }
        }
    }

    // Alternate screen + SGR 1002/1006 Mouse + Bracketed Paste
    System.out.print("\u001B[?1049h\u001B[?1002h\u001B[?1006h\u001B[?2004h")
    System.out.print(editor.render())
    System.out.flush()

    val decoder = InputDecoder()

    try {
        while (editor.isRunning) {
            val waitMs = if (decoder.hasPendingEscape()) 40L else 5000L
            val msg = queue.poll(waitMs, TimeUnit.MILLISECONDS)
            var dirty = false

            when (msg) {
                null -> {
                    if (decoder.hasPendingEscape()) {
                        for (ev in decoder.flushTimeout()) {
                            editor.handleEvent(ev)
                            dirty = true
                        }
                    }
                }
                is LoopMsg.Bytes -> {
                    for (ev in decoder.feed(msg.data, msg.len)) {
                        editor.handleEvent(ev)
                        dirty = true
                    }
                }
                LoopMsg.Winch -> {
                    val (c, r) = queryTerminalSize()
                    editor.cols = c
                    editor.rows = r
                    editor.ensureCursorVisible()
                    dirty = true
                }
                LoopMsg.Eof, LoopMsg.Terminate -> {
                    editor.isRunning = false
                }
            }

            if (dirty && editor.isRunning) {
                System.out.print(editor.render())
                System.out.flush()
            }
        }
    } finally {
        guard.restore()
    }
}
