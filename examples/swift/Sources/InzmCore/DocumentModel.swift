import Foundation

// MARK: - Line Ending & Encoding

public enum LineEnding: String, CaseIterable, Sendable, Equatable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    public static func detect(in text: String) -> LineEnding {
        var crlfCount = 0
        var lfCount = 0
        var crCount = 0

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" {
                    crlfCount += 1
                    i += 2
                    continue
                }
                crCount += 1
            } else if s == "\n" {
                lfCount += 1
            }
            i += 1
        }

        if crlfCount > lfCount && crlfCount >= crCount { return .crlf }
        if crCount > lfCount && crCount > crlfCount { return .cr }
        return .lf
    }

    /// Normalizes any CRLF / CR / LF sequences to internal LF (`\n`) for AppKit NSTextView.
    public static func normalizeToLF(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Converts LF-normalized text to the target line ending for saving to disk.
    public func apply(toNormalized text: String) -> String {
        let lf = LineEnding.normalizeToLF(text)
        switch self {
        case .lf: return lf
        case .crlf: return lf.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return lf.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}

public enum TextEncodingKind: String, CaseIterable, Sendable, Equatable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 with BOM"

    public static func decode(data: Data) -> (text: String, encoding: TextEncodingKind, lineEnding: LineEnding)? {
        let utf8BomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBom = data.count >= 3 && Array(data.prefix(3)) == utf8BomBytes
        let payload = hasBom ? data.dropFirst(3) : Data(data)
        guard let rawString = String(data: Data(payload), encoding: .utf8) else {
            return nil
        }
        let detectedLineEnding = LineEnding.detect(in: rawString)
        let normalized = LineEnding.normalizeToLF(rawString)
        return (normalized, hasBom ? .utf8BOM : .utf8, detectedLineEnding)
    }

    public func encode(normalizedText: String, lineEnding: LineEnding) -> Data {
        let converted = lineEnding.apply(toNormalized: normalizedText)
        var out = Data()
        if self == .utf8BOM {
            out.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        out.append(Data(converted.utf8))
        return out
    }
}

// MARK: - Unicode & Cursor Statistics

public struct DocumentStats: Sendable, Equatable {
    public let lineCount: Int
    public let characterCount: Int
    public let utf8ByteCount: Int
    public let cursorLine: Int     // 1-indexed
    public let cursorColumn: Int   // 1-indexed grapheme column
    public let selectedCharacters: Int
    public let currentCharacterSummary: String?
    public let scalarDetails: [UnicodeScalarDetail]
}

public struct UnicodeScalarDetail: Sendable, Equatable {
    public let scalar: String
    public let codePoint: String
    public let name: String
}

public enum TextInspector {
    /// Computes CotEditor-style status bar statistics and Unicode scalar details.
    /// `utf16Range` uses UTF-16 offsets matching NSTextView's `NSRange`.
    public static func inspect(text: String, utf16Range: NSRange) -> DocumentStats {
        let nsText = text as NSString
        let safeLoc = max(0, min(utf16Range.location, nsText.length))
        let safeLen = max(0, min(utf16Range.length, nsText.length - safeLoc))

        // Line count (at least 1 line; trailing newline adds empty visual line)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = max(1, lines.count)

        // Compute 1-indexed cursor line & column (grapheme count from line start)
        let prefixRange = NSRange(location: 0, length: safeLoc)
        let prefixStr = nsText.substring(with: prefixRange)
        let prefixLines = prefixStr.split(separator: "\n", omittingEmptySubsequences: false)
        let cursorLine = max(1, prefixLines.count)
        let cursorColumn = (prefixLines.last?.count ?? 0) + 1

        // Selected characters or character right after/before cursor
        let selectedStr = safeLen > 0 ? nsText.substring(with: NSRange(location: safeLoc, length: safeLen)) : ""
        let inspectedChar: Character? = {
            if let first = selectedStr.first {
                return first
            }
            if safeLoc < nsText.length {
                let tail = nsText.substring(from: safeLoc)
                return tail.first
            }
            return nil
        }()

        var summary: String?
        var details: [UnicodeScalarDetail] = []
        if let ch = inspectedChar {
            let scalars = Array(ch.unicodeScalars)
            let codePoints = scalars.map { String(format: "U+%04X", $0.value) }
            let preview = ch.isNewline ? "\\n" : (ch == "\t" ? "\\t" : String(ch))
            summary = "\(preview) (\(codePoints.joined(separator: " ")))"
            details = scalars.map { scalar in
                let cp = String(format: "U+%04X", scalar.value)
                let uniName = scalar.properties.name ?? scalarDisplayFallback(scalar)
                return UnicodeScalarDetail(scalar: String(scalar), codePoint: cp, name: uniName)
            }
        }

        return DocumentStats(
            lineCount: lineCount,
            characterCount: text.count,
            utf8ByteCount: text.utf8.count,
            cursorLine: cursorLine,
            cursorColumn: cursorColumn,
            selectedCharacters: selectedStr.count,
            currentCharacterSummary: summary,
            scalarDetails: details
        )
    }

    /// Returns the UTF-16 NSRange covering the specified 1-indexed line number.
    public static func rangeForLine(_ targetLine: Int, in text: String) -> NSRange {
        let clampedTarget = max(1, targetLine)
        let nsText = text as NSString
        var currentLine = 1
        var lineStart = 0
        var i = 0
        while i < nsText.length {
            if currentLine == clampedTarget {
                break
            }
            if nsText.character(at: i) == 0x0A { // '\n'
                currentLine += 1
                lineStart = i + 1
            }
            i += 1
        }
        return NSRange(location: lineStart, length: 0)
    }

    private static func scalarDisplayFallback(_ scalar: UnicodeScalar) -> String {
        switch scalar.value {
        case 0x0A: return "LINE FEED"
        case 0x0D: return "CARRIAGE RETURN"
        case 0x09: return "CHARACTER TABULATION"
        default: return "CONTROL CHARACTER"
        }
    }
}

// MARK: - EditorConfig Resolver & Save Formatting

public enum IndentStyle: String, Sendable, Equatable {
    case space
    case tab
}

public struct EditorConfigSettings: Sendable, Equatable {
    public var indentStyle: IndentStyle = .space
    public var indentSize: Int = 4
    public var endOfLine: LineEnding?
    public var trimTrailingWhitespace: Bool = false
    public var insertFinalNewline: Bool = false

    public init(
        indentStyle: IndentStyle = .space,
        indentSize: Int = 4,
        endOfLine: LineEnding? = nil,
        trimTrailingWhitespace: Bool = false,
        insertFinalNewline: Bool = false
    ) {
        self.indentStyle = indentStyle
        self.indentSize = indentSize
        self.endOfLine = endOfLine
        self.trimTrailingWhitespace = trimTrailingWhitespace
        self.insertFinalNewline = insertFinalNewline
    }

    public var tabInsertionString: String {
        switch indentStyle {
        case .tab: return "\t"
        case .space: return String(repeating: " ", count: max(1, indentSize))
        }
    }

    public var shortLabel: String {
        let style = indentStyle == .tab ? "Tab" : "Space"
        return "\(style): \(indentSize)"
    }
}

public enum EditorConfigResolver {
    public static func resolve(for fileURL: URL) -> EditorConfigSettings {
        let absPath = fileURL.standardizedFileURL.path
        var dir = fileURL.standardizedFileURL.deletingLastPathComponent()
        var configs: [(dirPath: String, content: String)] = []

        while true {
            let candidate = dir.appendingPathComponent(".editorconfig")
            if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                configs.append((dir.path, content))
                if hasRootTrue(in: content) {
                    break
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                break
            }
            dir = parent
        }

        // Apply from outermost root to innermost directory
        var result = EditorConfigSettings()
        for entry in configs.reversed() {
            let relPath: String
            if absPath.hasPrefix(entry.dirPath + "/") {
                relPath = String(absPath.dropFirst(entry.dirPath.count + 1))
            } else {
                relPath = fileURL.lastPathComponent
            }
            apply(content: entry.content, relativePath: relPath, into: &result)
        }
        return result
    }

    public static func formatOnSave(normalizedText: String, settings: EditorConfigSettings) -> String {
        var lines = LineEnding.normalizeToLF(normalizedText).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if settings.trimTrailingWhitespace {
            lines = lines.map { line in
                var trimmed = line
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed.removeLast()
                }
                return trimmed
            }
        }

        var out = lines.joined(separator: "\n")
        if settings.insertFinalNewline && !out.isEmpty && !out.hasSuffix("\n") {
            out.append("\n")
        }
        return out
    }

    private static func hasRootTrue(in content: String) -> Bool {
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.lowercased().replacingOccurrences(of: " ", with: "") == "root=true" {
                return true
            }
        }
        return false
    }

    private static func apply(content: String, relativePath: String, into settings: inout EditorConfigSettings) {
        var inMatchingSection = false
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let pattern = String(trimmed.dropFirst().dropLast())
                let target = pattern.contains("/") ? relativePath : fileName
                inMatchingSection = matchesGlob(pattern: pattern, target: target)
                continue
            }
            guard inMatchingSection, let eq = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()

            switch key {
            case "indent_style":
                if val == "tab" { settings.indentStyle = .tab }
                else if val == "space" { settings.indentStyle = .space }
            case "indent_size":
                if let n = Int(val), n > 0 { settings.indentSize = n }
            case "end_of_line":
                if val == "lf" { settings.endOfLine = .lf }
                else if val == "crlf" { settings.endOfLine = .crlf }
                else if val == "cr" { settings.endOfLine = .cr }
            case "trim_trailing_whitespace":
                if val == "true" { settings.trimTrailingWhitespace = true }
                else if val == "false" { settings.trimTrailingWhitespace = false }
            case "insert_final_newline":
                if val == "true" { settings.insertFinalNewline = true }
                else if val == "false" { settings.insertFinalNewline = false }
            default:
                break
            }
        }
    }

    /// Supports common EditorConfig globs: `*`, `**`, `?`, and `{a,b,c}` brace expansion.
    public static func matchesGlob(pattern: String, target: String) -> Bool {
        let expanded = expandBraces(pattern)
        return expanded.contains { singlePattern in
            let regexPattern = globToRegex(singlePattern)
            guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$") else {
                return false
            }
            let nsTarget = target as NSString
            return regex.firstMatch(in: target, range: NSRange(location: 0, length: nsTarget.length)) != nil
        }
    }

    private static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
              let close = pattern[open...].firstIndex(of: "}") else {
            return [pattern]
        }
        let prefix = String(pattern[..<open])
        let inner = String(pattern[pattern.index(after: open)..<close])
        let suffix = String(pattern[pattern.index(after: close)...])
        var results: [String] = []
        for option in inner.split(separator: ",", omittingEmptySubsequences: false) {
            for rest in expandBraces(suffix) {
                results.append(prefix + option + rest)
            }
        }
        return results
    }

    private static func globToRegex(_ glob: String) -> String {
        var regex = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    regex += ".*"
                    i += 2
                    continue
                }
                regex += "[^/]*"
            } else if c == "?" {
                regex += "[^/]"
            } else if "\\^$.|+()[]{}".contains(c) {
                regex += "\\\(c)"
            } else {
                regex.append(c)
            }
            i += 1
        }
        return regex
    }
}

// MARK: - Syntax Highlighting

public enum SyntaxLanguage: String, CaseIterable, Sendable, Equatable {
    case plain = "Plain Text"
    case swift = "Swift"
    case markdown = "Markdown"
    case json = "JSON"
    case code = "Code"

    public static func detect(for fileURL: URL?) -> SyntaxLanguage {
        guard let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty else {
            return .plain
        }
        switch ext {
        case "swift": return .swift
        case "md", "markdown": return .markdown
        case "json", "jsonc": return .json
        case "ts", "tsx", "js", "jsx", "rs", "go", "py", "rb", "php", "c", "h", "cpp", "java", "zig", "mbt", "lua", "sh":
            return .code
        default:
            return .plain
        }
    }
}

public enum HighlightKind: Sendable, Equatable {
    case keyword
    case typeOrHeading
    case string
    case comment
    case number
}

public struct HighlightToken: Sendable, Equatable {
    public let range: NSRange // UTF-16 range for NSLayoutManager
    public let kind: HighlightKind
}

public enum SyntaxHighlighter {
    public static func tokenize(_ text: String, language: SyntaxLanguage) -> [HighlightToken] {
        guard language != .plain, !text.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var tokens: [HighlightToken] = []

        func appendMatches(_ pattern: String, options: NSRegularExpression.Options = [], kind: HighlightKind) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: fullRange) {
                tokens.append(HighlightToken(range: match.range, kind: kind))
            }
        }

        switch language {
        case .plain:
            break
        case .swift, .code:
            appendMatches(#"\b[0-9]+(\.[0-9]+)?\b"#, kind: .number)
            appendMatches(#"\b(func|fn|def|function|let|var|const|val|mut|pub|public|private|internal|struct|class|enum|protocol|interface|impl|import|export|return|if|else|switch|case|default|for|while|guard|break|continue|defer|async|await|try|catch|throw|throws|true|false|nil|null|self|Self)\b"#, kind: .keyword)
            appendMatches(#"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .typeOrHeading)
            appendMatches(#""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#, kind: .string)
            appendMatches(#"(//|#).*$"#, options: .anchorsMatchLines, kind: .comment)
        case .markdown:
            appendMatches(#"^#{1,6}\s+.*$"#, options: .anchorsMatchLines, kind: .typeOrHeading)
            appendMatches(#"`[^`\n]+`"#, kind: .string)
            appendMatches(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, kind: .keyword)
            appendMatches(#"^>\s.*$"#, options: .anchorsMatchLines, kind: .comment)
        case .json:
            appendMatches(#"\b(true|false|null)\b"#, kind: .keyword)
            appendMatches(#"-?\b[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\b"#, kind: .number)
            appendMatches(#""([^"\\]|\\.)*""#, kind: .string)
        }

        return tokens
    }
}
