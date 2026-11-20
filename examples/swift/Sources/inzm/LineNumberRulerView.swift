import AppKit

@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateThickness() {
        guard let textView else { return }
        let lineCount = max(1, textView.string.split(separator: "\n", omittingEmptySubsequences: false).count)
        let digits = max(3, String(lineCount).count)
        let desired = CGFloat(digits) * 9.0 + 20.0
        if abs(ruleThickness - desired) > 1.0 {
            ruleThickness = desired
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        // Background
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        rect.fill()

        // Right separator
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.width - 0.5, y: rect.minY))
        border.line(to: NSPoint(x: bounds.width - 0.5, y: rect.maxY))
        border.lineWidth = 1.0
        border.stroke()

        let content = textView.string as NSString
        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Compute current cursor line number (1-indexed)
        let selectedLoc = min(textView.selectedRange().location, content.length)
        let cursorLineNumber = currentLineNumber(at: selectedLoc, in: content)

        // Count logical line number up to charRange.location
        var lineNumber = currentLineNumber(at: charRange.location, in: content)
        var index = charRange.location
        let textInsetY = textView.textContainerOrigin.y
        let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(10, baseFont.pointSize - 1.5), weight: .regular)
        let activeFont = NSFont.monospacedDigitSystemFont(ofSize: max(10, baseFont.pointSize - 1.5), weight: .semibold)

        while index <= content.length {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let glyphForLine = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect: NSRect
            if glyphForLine < layoutManager.numberOfGlyphs {
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphForLine, effectiveRange: nil, withoutAdditionalLayout: true)
            } else {
                lineRect = layoutManager.extraLineFragmentRect
            }

            let yPos = lineRect.minY + textInsetY - visibleRect.minY
            let isActive = (lineNumber == cursorLineNumber)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isActive ? activeFont : numberFont,
                .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: bounds.width - size.width - 8.0,
                y: yPos + (lineRect.height - size.height) * 0.5
            )
            label.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= index { break }
            index = nextIndex
            if index >= NSMaxRange(charRange) && index < content.length { break }
            if index == content.length {
                // Draw trailing empty line number if document ends with '\n'
                if content.length > 0 && content.character(at: content.length - 1) == 0x0A {
                    let extraRect = layoutManager.extraLineFragmentRect
                    if extraRect.height > 0 {
                        let extraY = extraRect.minY + textInsetY - visibleRect.minY
                        let isTailActive = (lineNumber == cursorLineNumber)
                        let tailAttrs: [NSAttributedString.Key: Any] = [
                            .font: isTailActive ? activeFont : numberFont,
                            .foregroundColor: isTailActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
                        ]
                        let tailLabel = "\(lineNumber)" as NSString
                        let tailSize = tailLabel.size(withAttributes: tailAttrs)
                        tailLabel.draw(
                            at: NSPoint(x: bounds.width - tailSize.width - 8.0, y: extraY + (extraRect.height - tailSize.height) * 0.5),
                            withAttributes: tailAttrs
                        )
                    }
                }
                break
            }
        }
    }

    private func currentLineNumber(at utf16Location: Int, in content: NSString) -> Int {
        let clamped = max(0, min(utf16Location, content.length))
        var line = 1
        var i = 0
        while i < clamped {
            if content.character(at: i) == 0x0A {
                line += 1
            }
            i += 1
        }
        return line
    }
}
