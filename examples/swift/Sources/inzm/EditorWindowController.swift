import AppKit
import InzmCore

// MARK: - CotEditor-style NSTextView Subclass

@MainActor
final class EditorTextView: NSTextView {
    var editorConfig = EditorConfigSettings()

    override func insertTab(_ sender: Any?) {
        let tabStr = editorConfig.tabInsertionString
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: tabStr) {
            replaceCharacters(in: range, with: tabStr)
            didChangeText()
        }
    }

    override func insertNewline(_ sender: Any?) {
        let nsText = string as NSString
        let sel = selectedRange()
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        let prefixLen = max(0, sel.location - lineRange.location)
        let currentPrefix = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLen))
        var indent = ""
        for ch in currentPrefix {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }
        let insertion = "\n" + indent
        if shouldChangeText(in: sel, replacementString: insertion) {
            replaceCharacters(in: sel, with: insertion)
            didChangeText()
        }
    }
}

// MARK: - Window Controller

@MainActor
final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let scrollView = NSScrollView()
    let textView = EditorTextView()
    private var rulerView: LineNumberRulerView!

    private let statusBar = NSView()
    private let leftStatusLabel = NSTextField(labelWithString: "")
    private let encodingButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lineEndingButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inspectorButton = NSButton(title: "U+", target: nil, action: nil)

    private(set) var fileURL: URL?
    private(set) var isModified = false {
        didSet {
            window?.isDocumentEdited = isModified
            updateWindowTitle()
        }
    }

    private var encodingKind: TextEncodingKind = .utf8
    private var lineEnding: LineEnding = .lf
    private var syntaxLanguage: SyntaxLanguage = .plain
    private var editorConfig = EditorConfigSettings()
    private var fontSize: CGFloat = 13.5
    private var showsLineNumbers = true
    private var showsStatusBar = true
    private var highlightsSyntax = true
    private var lastScalarDetails: [UnicodeScalarDetail] = []
    private var inspectorPopover: NSPopover?

    var onRequestNewTab: ((EditorWindowController) -> Void)?
    var onCloseCleanup: ((EditorWindowController) -> Void)?

    convenience init(fileURL: URL? = nil) {
        let rect = NSRect(x: 0, y: 0, width: 880, height: 640)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "inzm-editor-tab"
        window.minSize = NSSize(width: 480, height: 320)

        self.init(window: window)
        window.delegate = self
        setupUI()

        if let url = fileURL {
            loadFile(at: url)
        } else {
            updateMetadataAndHighlight()
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // ScrollView & TextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.font = editorFont()

        // Code/Text Editor Essentials (disable smart substitutions)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self

        scrollView.documentView = textView

        // Line Number Ruler
        rulerView = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showsLineNumbers

        // Status Bar
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(separator)

        leftStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        leftStatusLabel.textColor = .secondaryLabelColor
        leftStatusLabel.lineBreakMode = .byTruncatingTail
        leftStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        inspectorButton.bezelStyle = .inline
        inspectorButton.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        inspectorButton.toolTip = "Unicode 文字情報 (⌥⌘I)"
        inspectorButton.target = self
        inspectorButton.action = #selector(toggleCharacterInspector(_:))
        inspectorButton.translatesAutoresizingMaskIntoConstraints = false

        configurePopUp(languageButton, items: SyntaxLanguage.allCases.map(\.rawValue), action: #selector(languageChanged(_:)))
        configurePopUp(encodingButton, items: TextEncodingKind.allCases.map(\.rawValue), action: #selector(encodingChanged(_:)))
        configurePopUp(lineEndingButton, items: LineEnding.allCases.map(\.rawValue), action: #selector(lineEndingChanged(_:)))

        let rightStack = NSStackView(views: [inspectorButton, languageButton, encodingButton, lineEndingButton])
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        statusBar.addSubview(leftStatusLabel)
        statusBar.addSubview(rightStack)

        contentView.addSubview(scrollView)
        contentView.addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),

            leftStatusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            leftStatusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            leftStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),

            rightStack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        updateWindowTitle()
    }

    private func configurePopUp(_ button: NSPopUpButton, items: [String], action: Selector) {
        button.controlSize = .small
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11)
        button.addItems(withTitles: items)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func editorFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: - File I/O

    func loadFile(at url: URL) {
        self.fileURL = url
        self.editorConfig = EditorConfigResolver.resolve(for: url)
        self.textView.editorConfig = self.editorConfig
        self.syntaxLanguage = SyntaxLanguage.detect(for: url)

        if let ecLineEnding = editorConfig.endOfLine {
            self.lineEnding = ecLineEnding
        }

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                if let decoded = TextEncodingKind.decode(data: data) {
                    self.encodingKind = decoded.encoding
                    self.lineEnding = decoded.lineEnding
                    textView.string = decoded.text
                } else {
                    showErrorAlert(title: "読み込みエラー", message: "UTF-8 として開けませんでした: \(url.lastPathComponent)")
                }
            } catch {
                showErrorAlert(title: "読み込みエラー", message: error.localizedDescription)
            }
        } else {
            textView.string = ""
        }

        textView.undoManager?.removeAllActions()
        isModified = false
        updateMetadataAndHighlight()
    }

    @discardableResult
    func saveDocumentAction() -> Bool {
        if let url = fileURL {
            return writeDocument(to: url)
        }
        return saveDocumentAsAction()
    }

    @discardableResult
    func saveDocumentAsAction() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "untitled.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let targetURL = panel.url else {
            return false
        }
        self.fileURL = targetURL
        self.editorConfig = EditorConfigResolver.resolve(for: targetURL)
        self.textView.editorConfig = self.editorConfig
        self.syntaxLanguage = SyntaxLanguage.detect(for: targetURL)
        if let ecEOL = editorConfig.endOfLine {
            self.lineEnding = ecEOL
        }
        return writeDocument(to: targetURL)
    }

    private func writeDocument(to url: URL) -> Bool {
        let formatted = EditorConfigResolver.formatOnSave(normalizedText: textView.string, settings: editorConfig)
        if formatted != textView.string {
            let savedSelection = textView.selectedRange()
            textView.string = formatted
            let clampedLoc = min(savedSelection.location, (formatted as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
        }
        let encoded = encodingKind.encode(normalizedText: textView.string, lineEnding: lineEnding)
        do {
            try encoded.write(to: url, options: .atomic)
            isModified = false
            updateMetadataAndHighlight()
            return true
        } catch {
            showErrorAlert(title: "保存エラー", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - NSTextViewDelegate & Updates

    func textDidChange(_ notification: Notification) {
        isModified = true
        updateMetadataAndHighlight()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateStatusBar()
        rulerView.needsDisplay = true
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        rulerView.needsDisplay = true
    }

    private func updateMetadataAndHighlight() {
        languageButton.selectItem(withTitle: syntaxLanguage.rawValue)
        encodingButton.selectItem(withTitle: encodingKind.rawValue)
        lineEndingButton.selectItem(withTitle: lineEnding.rawValue)

        applySyntaxHighlight()
        rulerView.updateThickness()
        updateStatusBar()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let baseTitle = fileURL?.lastPathComponent ?? "Untitled"
        window?.title = baseTitle
        window?.representedURL = fileURL
    }

    private func updateStatusBar() {
        let stats = TextInspector.inspect(text: textView.string, utf16Range: textView.selectedRange())
        lastScalarDetails = stats.scalarDetails

        var parts: [String] = [
            "Ln \(stats.cursorLine), Col \(stats.cursorColumn)",
            "\(stats.lineCount) lines",
            "\(stats.characterCount) chars",
            "\(stats.utf8ByteCount) B",
        ]
        if stats.selectedCharacters > 0 {
            parts.append("Sel: \(stats.selectedCharacters)")
        }
        if let summary = stats.currentCharacterSummary {
            parts.append(summary)
        }
        parts.append("EC: \(editorConfig.shortLabel)")
        leftStatusLabel.stringValue = parts.joined(separator: "   |   ")
        inspectorButton.isEnabled = !lastScalarDetails.isEmpty
    }

    private func applySyntaxHighlight() {
        guard let layoutManager = textView.layoutManager else { return }
        let nsText = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

        guard highlightsSyntax, syntaxLanguage != .plain else { return }

        let tokens = SyntaxHighlighter.tokenize(textView.string, language: syntaxLanguage)
        for token in tokens where NSMaxRange(token.range) <= nsText.length {
            let color: NSColor
            switch token.kind {
            case .keyword: color = .systemPink
            case .typeOrHeading: color = .systemCyan
            case .string: color = .systemOrange
            case .comment: color = .secondaryLabelColor
            case .number: color = .systemPurple
            }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
        }
    }

    // MARK: - CotEditor-like Editing & View Actions

    @objc func saveDocument(_ sender: Any?) { saveDocumentAction() }
    @objc func saveDocumentAs(_ sender: Any?) { saveDocumentAsAction() }

    @objc func newTab(_ sender: Any?) {
        onRequestNewTab?(self)
    }

    @objc func duplicateCurrentLine(_ sender: Any?) {
        let nsText = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        var lineStr = nsText.substring(with: lineRange)
        let insertLoc: Int
        if lineStr.hasSuffix("\n") {
            insertLoc = NSMaxRange(lineRange)
        } else {
            lineStr = "\n" + lineStr
            insertLoc = NSMaxRange(lineRange)
        }
        let target = NSRange(location: insertLoc, length: 0)
        if textView.shouldChangeText(in: target, replacementString: lineStr) {
            textView.replaceCharacters(in: target, with: lineStr)
            textView.didChangeText()
        }
    }

    @objc func deleteCurrentLine(_ sender: Any?) {
        let nsText = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        if textView.shouldChangeText(in: lineRange, replacementString: "") {
            textView.replaceCharacters(in: lineRange, with: "")
            textView.didChangeText()
        }
    }

    @objc func jumpToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "指定行へ移動 (Jump to Line)"
        alert.informativeText = "移動先の行番号を入力してください:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let stats = TextInspector.inspect(text: textView.string, utf16Range: textView.selectedRange())
        input.stringValue = "\(stats.cursorLine)"
        alert.accessoryView = input
        alert.addButton(withTitle: "移動")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn, let targetLine = Int(input.stringValue.trimmingCharacters(in: .whitespaces)) {
            let targetRange = TextInspector.rangeForLine(targetLine, in: textView.string)
            textView.setSelectedRange(targetRange)
            textView.scrollRangeToVisible(targetRange)
            updateStatusBar()
            rulerView.needsDisplay = true
        }
    }

    @objc func increaseFontSize(_ sender: Any?) {
        fontSize = min(36.0, fontSize + 1.5)
        textView.font = editorFont()
        rulerView.updateThickness()
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        fontSize = max(9.0, fontSize - 1.5)
        textView.font = editorFont()
        rulerView.updateThickness()
    }

    @objc func resetFontSize(_ sender: Any?) {
        fontSize = 13.5
        textView.font = editorFont()
        rulerView.updateThickness()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        showsLineNumbers.toggle()
        scrollView.rulersVisible = showsLineNumbers
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        showsStatusBar.toggle()
        statusBar.isHidden = !showsStatusBar
    }

    @objc func toggleSyntaxHighlight(_ sender: Any?) {
        highlightsSyntax.toggle()
        applySyntaxHighlight()
    }

    @objc func toggleCharacterInspector(_ sender: Any?) {
        if let pop = inspectorPopover, pop.isShown {
            pop.close()
            return
        }
        guard !lastScalarDetails.isEmpty else { return }

        let vc = NSViewController()
        let lines = lastScalarDetails.map { "\($0.scalar)   \($0.codePoint)   \($0.name)" }
        let label = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: max(60, 28 + lines.count * 20)))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        vc.view = container

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: inspectorButton.bounds, of: inspectorButton, preferredEdge: .maxY)
        self.inspectorPopover = popover
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let lang = SyntaxLanguage(rawValue: title) {
            syntaxLanguage = lang
            applySyntaxHighlight()
        }
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let enc = TextEncodingKind(rawValue: title) {
            if encodingKind != enc {
                encodingKind = enc
                isModified = true
            }
        }
    }

    @objc private func lineEndingChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let eol = LineEnding(rawValue: title) {
            if lineEnding != eol {
                lineEnding = eol
                isModified = true
            }
        }
    }

    // MARK: - NSWindowDelegate (Safe Close)

    func confirmCloseIfNeeded() -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        let name = fileURL?.lastPathComponent ?? "Untitled"
        alert.messageText = "「\(name)」への変更を保存しますか？"
        alert.informativeText = "保存せずに閉じると、編集した内容は失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocumentAction()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        onCloseCleanup?(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLineNumbers(_:)):
            menuItem.state = showsLineNumbers ? .on : .off
        case #selector(toggleStatusBar(_:)):
            menuItem.state = showsStatusBar ? .on : .off
        case #selector(toggleSyntaxHighlight(_:)):
            menuItem.state = highlightsSyntax ? .on : .off
        case #selector(toggleCharacterInspector(_:)):
            return !lastScalarDetails.isEmpty
        default:
            break
        }
        return true
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
