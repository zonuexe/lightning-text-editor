package inzm

import java.io.File

data class Pos(val row: Int, val col: Int) : Comparable<Pos> {
    override fun compareTo(other: Pos): Int {
        if (row != other.row) return row.compareTo(other.row)
        return col.compareTo(other.col)
    }
}

object UnicodeWidth {
    fun codePointCount(s: String): Int = s.codePointCount(0, s.length)

    fun sliceCodePoints(s: String, startCp: Int, endCp: Int = codePointCount(s)): String {
        val total = codePointCount(s)
        val from = startCp.coerceIn(0, total)
        val to = endCp.coerceIn(from, total)
        val startOffset = s.offsetByCodePoints(0, from)
        val endOffset = s.offsetByCodePoints(0, to)
        return s.substring(startOffset, endOffset)
    }

    fun codePointsList(s: String): List<Int> {
        val list = ArrayList<Int>(codePointCount(s))
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            list.add(cp)
            i += Character.charCount(cp)
        }
        return list
    }

    fun fromCodePoints(cps: List<Int>): String {
        val sb = StringBuilder(cps.size)
        for (cp in cps) {
            sb.appendCodePoint(cp)
        }
        return sb.toString()
    }

    fun charWidth(cp: Int, isEaw: Boolean): Int {
        // Combining / zero-width / ZWJ
        if (cp == 0x200D || (cp in 0xFE00..0xFE0F) || (cp in 0x0300..0x036F) || (cp in 0x3099..0x309A)) {
            return 0
        }
        // Wide / Fullwidth CJK & Emoji
        if ((cp in 0x1100..0x115F) ||
            (cp in 0x2E80..0xA4CF && cp != 0x303F) ||
            (cp in 0xAC00..0xD7A3) ||
            (cp in 0xF900..0xFAFF) ||
            (cp in 0xFE10..0xFE19) ||
            (cp in 0xFE30..0xFE6F) ||
            (cp in 0xFF01..0xFF60) ||
            (cp in 0xFFE0..0xFFE6) ||
            (cp in 0x1F300..0x1FAFF) ||
            (cp in 0x20000..0x323AF)
        ) {
            return 2
        }
        // East Asian Ambiguous symbols
        if ((cp in 0x0370..0x03FF) ||
            (cp in 0x0400..0x04FF) ||
            (cp in 0x2010..0x205E) ||
            (cp in 0x2100..0x214F) ||
            (cp in 0x2190..0x21FF) ||
            (cp in 0x2200..0x22FF) ||
            (cp in 0x25A0..0x25FF) ||
            (cp in 0x2600..0x27BF)
        ) {
            return if (isEaw) 2 else 1
        }
        return 1
    }

    data class SanitizedLine(val displayText: String, val visualWidth: Int)

    fun sanitizeForTerminal(line: String, tabWidth: Int = 4, isEaw: Boolean = false): SanitizedLine {
        val sb = StringBuilder()
        var col = 0
        var i = 0
        while (i < line.length) {
            val cp = line.codePointAt(i)
            when {
                cp == '\t'.code -> {
                    val spaces = tabWidth - (col % tabWidth)
                    sb.append(" ".repeat(spaces))
                    col += spaces
                }
                cp < 0x20 -> {
                    sb.append('^').append((cp + 64).toChar())
                    col += 2
                }
                cp == 0x7F -> {
                    sb.append("^?")
                    col += 2
                }
                cp in 0x80..0x9F -> {
                    sb.append('?')
                    col += 1
                }
                else -> {
                    sb.appendCodePoint(cp)
                    col += charWidth(cp, isEaw)
                }
            }
            i += Character.charCount(cp)
        }
        return SanitizedLine(sb.toString(), col)
    }

    fun visualWidthUpTo(line: String, cpLimit: Int, tabWidth: Int = 4, isEaw: Boolean = false): Int {
        val prefix = sliceCodePoints(line, 0, cpLimit)
        return sanitizeForTerminal(prefix, tabWidth, isEaw).visualWidth
    }

    fun visualColToCodePointIndex(line: String, targetVisualCol: Int, tabWidth: Int = 4, isEaw: Boolean = false): Int {
        var col = 0
        var cpIdx = 0
        var i = 0
        while (i < line.length) {
            val cp = line.codePointAt(i)
            val w = when {
                cp == '\t'.code -> tabWidth - (col % tabWidth)
                cp < 0x20 || cp == 0x7F -> 2
                cp in 0x80..0x9F -> 1
                else -> charWidth(cp, isEaw)
            }
            if (col + w > targetVisualCol) {
                return cpIdx
            }
            col += w
            cpIdx += 1
            i += Character.charCount(cp)
        }
        return cpIdx
    }

    fun isWordChar(cp: Int): Boolean {
        return Character.isLetterOrDigit(cp) || cp == '_'.code
    }
}

data class EditorConfig(
    val indentStyle: String = "space",
    val indentSize: Int = 4,
    val endOfLine: String = "lf",
    val trimTrailingWhitespace: Boolean = false,
    val insertFinalNewline: Boolean = false,
) {
    fun tabInsertion(): String = if (indentStyle == "tab") "\t" else " ".repeat(indentSize.coerceAtLeast(1))

    fun shortLabel(): String = "${if (indentStyle == "tab") "tab" else "sp"}:$indentSize"
}

object EditorConfigResolver {
    fun resolve(filePath: String): EditorConfig {
        val absFile = File(filePath).absoluteFile
        var dir: File? = absFile.parentFile
        val found = ArrayList<Pair<File, String>>()

        while (dir != null) {
            val candidate = File(dir, ".editorconfig")
            if (candidate.isFile) {
                val text = runCatching { candidate.readText(Charsets.UTF_8) }.getOrNull()
                if (text != null) {
                    found.add(dir to text)
                    if (isRootTrue(text)) break
                }
            }
            dir = dir.parentFile
        }

        var indentStyle = "space"
        var indentSize = 4
        var endOfLine = "lf"
        var trimTrailing = false
        var insertFinalNewline = false

        for ((cfgDir, text) in found.reversed()) {
            val relPath = runCatching {
                absFile.toPath().toAbsolutePath().normalize()
                    .let { cfgDir.toPath().toAbsolutePath().normalize().relativize(it).toString().replace('\\', '/') }
            }.getOrDefault(absFile.name)

            var active = false
            for (rawLine in text.lineSequence()) {
                val trimmed = rawLine.trim()
                if (trimmed.isEmpty() || trimmed.startsWith('#') || trimmed.startsWith(';')) continue
                if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
                    val pattern = trimmed.substring(1, trimmed.length - 1)
                    val target = if (pattern.contains('/')) relPath else absFile.name
                    active = matchGlob(pattern, target)
                    continue
                }
                if (!active) continue
                val eq = trimmed.indexOf('=')
                if (eq <= 0) continue
                val key = trimmed.substring(0, eq).trim().lowercase()
                val value = trimmed.substring(eq + 1).trim().lowercase()
                when (key) {
                    "indent_style" -> if (value == "tab" || value == "space") indentStyle = value
                    "indent_size" -> value.toIntOrNull()?.takeIf { it > 0 }?.let { indentSize = it }
                    "end_of_line" -> if (value in listOf("lf", "crlf", "cr")) endOfLine = value
                    "trim_trailing_whitespace" -> if (value == "true" || value == "false") trimTrailing = value == "true"
                    "insert_final_newline" -> if (value == "true" || value == "false") insertFinalNewline = value == "true"
                }
            }
        }

        return EditorConfig(indentStyle, indentSize, endOfLine, trimTrailing, insertFinalNewline)
    }

    private fun isRootTrue(text: String): Boolean {
        for (rawLine in text.lineSequence()) {
            val line = rawLine.trim()
            if (line.startsWith('[')) break
            if (line.replace(" ", "").equals("root=true", ignoreCase = true)) return true
        }
        return false
    }

    fun matchGlob(pattern: String, target: String): Boolean {
        return expandBraces(pattern).any { single ->
            val regex = buildString {
                append('^')
                var i = 0
                while (i < single.length) {
                    when (val c = single[i]) {
                        '*' -> {
                            if (i + 1 < single.length && single[i + 1] == '*') {
                                append(".*")
                                i += 2
                                continue
                            }
                            append("[^/]*")
                        }
                        '?' -> append("[^/]")
                        '\\', '^', '$', '.', '|', '+', '(', ')', '[', ']', '{', '}' -> append('\\').append(c)
                        else -> append(c)
                    }
                    i++
                }
                append('$')
            }
            Regex(regex).matches(target)
        }
    }

    private fun expandBraces(pattern: String): List<String> {
        val open = pattern.indexOf('{')
        if (open < 0) return listOf(pattern)
        val close = pattern.indexOf('}', open)
        if (close < 0) return listOf(pattern)
        val prefix = pattern.substring(0, open)
        val inner = pattern.substring(open + 1, close)
        val suffix = pattern.substring(close + 1)
        val out = ArrayList<String>()
        for (opt in inner.split(',')) {
            for (rest in expandBraces(suffix)) {
                out.add(prefix + opt + rest)
            }
        }
        return out
    }
}
