import AppKit
import InzmCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            openWindow(fileURL: nil)
        } else {
            for arg in args where !arg.hasPrefix("-") {
                let url = URL(fileURLWithPath: arg).standardizedFileURL
                openWindow(fileURL: url)
            }
            if windowControllers.isEmpty {
                openWindow(fileURL: nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            openWindow(fileURL: URL(fileURLWithPath: path).standardizedFileURL)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for wc in windowControllers {
            if !wc.confirmCloseIfNeeded() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    private func openWindow(fileURL: URL?, asTabOf parent: EditorWindowController? = nil) {
        if let url = fileURL,
           let existing = windowControllers.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let wc = EditorWindowController(fileURL: fileURL)
        wc.onRequestNewTab = { [weak self] current in
            self?.openWindow(fileURL: nil, asTabOf: current)
        }
        wc.onCloseCleanup = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(wc)

        if let parentWindow = parent?.window, let newWin = wc.window {
            parentWindow.addTabbedWindow(newWin, ordered: .above)
            newWin.makeKeyAndOrderFront(nil)
        } else {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Menu Actions

    @objc func newDocument(_ sender: Any?) {
        openWindow(fileURL: nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                openWindow(fileURL: url)
            }
        }
    }

    // MARK: - Standard macOS / CotEditor-style Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About inzm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide inzm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit inzm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(EditorWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 3. Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Duplicate Line", action: #selector(EditorWindowController.duplicateCurrentLine(_:)), keyEquivalent: "d")
        let delLine = editMenu.addItem(withTitle: "Delete Line", action: #selector(EditorWindowController.deleteCurrentLine(_:)), keyEquivalent: "K")
        delLine.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Jump to Line…", action: #selector(EditorWindowController.jumpToLine(_:)), keyEquivalent: "l")
        editMenu.addItem(.separator())

        // Find Submenu (macOS Standard Find Bar)
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        let findItem = findMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findReplaceItem = findMenu.addItem(withTitle: "Find and Replace…", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "f")
        findReplaceItem.keyEquivalentModifierMask = [.command, .option]
        findReplaceItem.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        let findNext = findMenu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPrev = findMenu.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "G")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        let useSel = findMenu.addItem(withTitle: "Use Selection for Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "e")
        useSel.tag = NSTextFinder.Action.setSearchString.rawValue
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 4. View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let inspectorItem = viewMenu.addItem(withTitle: "Inspect Character (Unicode)", action: #selector(EditorWindowController.toggleCharacterInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Line Numbers", action: #selector(EditorWindowController.toggleLineNumbers(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Toggle Status Bar", action: #selector(EditorWindowController.toggleStatusBar(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Toggle Syntax Highlight", action: #selector(EditorWindowController.toggleSyntaxHighlight(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Bigger Font", action: #selector(EditorWindowController.increaseFontSize(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Smaller Font", action: #selector(EditorWindowController.decreaseFontSize(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Reset Font Size", action: #selector(EditorWindowController.resetFontSize(_:)), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
