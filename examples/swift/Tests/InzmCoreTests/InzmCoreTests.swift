import Foundation
import Testing
@testable import InzmCore

@Test func detectAndApplyLineEndings() {
    #expect(LineEnding.detect(in: "a\r\nb\r\nc") == .crlf)
    #expect(LineEnding.detect(in: "a\rb\rc") == .cr)
    #expect(LineEnding.detect(in: "a\nb\nc") == .lf)

    let normalized = LineEnding.normalizeToLF("one\r\ntwo\rthree\n")
    #expect(normalized == "one\ntwo\nthree\n")
    #expect(LineEnding.crlf.apply(toNormalized: normalized) == "one\r\ntwo\r\nthree\r\n")
}

@Test func utf8AndBomRoundTrip() {
    let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("こんにちは\r\n世界".utf8)
    let decoded = TextEncodingKind.decode(data: Data(bomBytes))
    #expect(decoded != nil)
    #expect(decoded?.encoding == .utf8BOM)
    #expect(decoded?.lineEnding == .crlf)
    #expect(decoded?.text == "こんにちは\n世界")

    let reencoded = TextEncodingKind.utf8BOM.encode(normalizedText: "こんにちは\n世界", lineEnding: .crlf)
    #expect(Array(reencoded) == bomBytes)
}

@Test func inspectUnicodeGraphemeClustersAndCursor() {
    let text = "a🍣\n👨‍👩‍👧‍👦か゚"
    let nsText = text as NSString
    // Cursor right after family emoji on line 2: "a🍣\n👨‍👩‍👧‍👦"
    let pos = ("a🍣\n👨‍👩‍👧‍👦" as NSString).length
    let stats = TextInspector.inspect(text: text, utf16Range: NSRange(location: pos, length: 0))

    #expect(stats.lineCount == 2)
    #expect(stats.characterCount == 5) // 'a', '🍣', '\n', '👨‍👩‍👧‍👦', 'か゚'
    #expect(stats.cursorLine == 2)
    #expect(stats.cursorColumn == 2) // 1-indexed grapheme column after 1 family emoji
    #expect(stats.scalarDetails.map(\.codePoint) == ["U+304B", "U+309A"]) // か + semi-voiced mark

    // Selection over the family emoji
    let familyRange = NSRange(location: ("a🍣\n" as NSString).length, length: ("👨‍👩‍👧‍👦" as NSString).length)
    let selStats = TextInspector.inspect(text: text, utf16Range: familyRange)
    #expect(selStats.selectedCharacters == 1)
    #expect(selStats.scalarDetails.count == 7)
    #expect(nsText.length > stats.characterCount)
}

@Test func editorConfigResolutionAndFormatOnSave() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("inzm-swift-ec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let ecContent = """
    root = true

    [*]
    indent_style = space
    indent_size = 4
    trim_trailing_whitespace = true
    insert_final_newline = true

    [*.swift]
    indent_size = 2
    end_of_line = lf
    """
    try ecContent.write(to: tmpDir.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)

    let swiftFile = tmpDir.appendingPathComponent("App.swift")
    let settings = EditorConfigResolver.resolve(for: swiftFile)
    #expect(settings.indentStyle == .space)
    #expect(settings.indentSize == 2)
    #expect(settings.trimTrailingWhitespace == true)
    #expect(settings.insertFinalNewline == true)
    #expect(settings.endOfLine == .lf)

    let formatted = EditorConfigResolver.formatOnSave(normalizedText: "let x = 1   \nlet y = 2\t", settings: settings)
    #expect(formatted == "let x = 1\nlet y = 2\n")
}

@Test func rangeForLineAndSyntaxHighlight() {
    let text = "import Foundation\n// comment\nlet s = \"日本語\"\n"
    let r2 = TextInspector.rangeForLine(2, in: text)
    #expect((text as NSString).substring(from: r2.location).hasPrefix("// comment"))

    let tokens = SyntaxHighlighter.tokenize(text, language: .swift)
    #expect(tokens.contains { $0.kind == .keyword })
    #expect(tokens.contains { $0.kind == .comment })
    #expect(tokens.contains { $0.kind == .string })
}
