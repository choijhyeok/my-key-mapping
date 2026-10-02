import AppKit
import ApplicationServices
import Carbon
import Foundation

struct Phrase: Decodable {
    let digit: String
    let text: String
}

private struct ClipboardItem {
    let values: [(String, Data)]
}

private struct PendingPaste {
    let text: String
    let deadline: Date
}

private let appSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MyKeyMapping", isDirectory: true)
private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/MyKeyMapping/phrase-typer.log")

final class PhraseTyper: NSObject, NSApplicationDelegate {
    static var shared: PhraseTyper!
    private var phrases: [String: String] = [:]
    private var registrations: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var statusItem: NSStatusItem?
    private var scratchWindow: NSWindow?
    private var scratchView: NSTextView?
    private var pending: [PendingPaste] = []
    private var pasteInProgress = false
    private let selfTest = CommandLine.arguments.contains("--self-test")
    private var selfTestInitialClipboard: [ClipboardItem] = []
    private var selfTestInitialChangeCount = 0
    private var selfTestHeldCheckPassed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        do {
            try loadPhrases()
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            guard trusted else {
                log("AX_PERMISSION_REQUIRED: allow PhraseTyper.app in System Settings > Privacy & Security > Accessibility, then restart it")
                if selfTest { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) } }
                return
            }
            try registerHotkeys()
            log("ready: registered \(registrations.count) of 10 hotkeys; AX trusted; pid=\(ProcessInfo.processInfo.processIdentifier)")
            installMenu()
            if selfTest { beginSelfTest() }
        } catch {
            log("startup failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func loadPhrases() throws {
        let url = appSupport.appendingPathComponent("phrases.json")
        let entries = try JSONDecoder().decode([Phrase].self, from: Data(contentsOf: url))
        guard entries.count == 10, Set(entries.map(\.digit)) == Set(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]) else {
            throw NSError(domain: "PhraseTyper", code: 1, userInfo: [NSLocalizedDescriptionKey: "phrases.json must define digits 0–9 exactly once"])
        }
        phrases = Dictionary(uniqueKeysWithValues: entries.map { ($0.digit, $0.text) })
    }

    private func registerHotkeys() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            if status == noErr { PhraseTyper.shared?.fireHotkey(Int(hotKey.id)) }
            return noErr
        }, 1, &type, nil, &eventHandler)
        guard installStatus == noErr else { throw error("Could not install Carbon hotkey handler (\(installStatus))") }

        let keycodes: [(String, UInt32)] = [("1",18),("2",19),("3",20),("4",21),("5",23),("6",22),("7",26),("8",28),("9",25),("0",29)]
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for (index, pair) in keycodes.enumerated() {
            let identifier = EventHotKeyID(signature: OSType(0x4D4B4D50), id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(pair.1, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else { throw error("Could not register Ctrl+Option+Command+\(pair.0) (\(status))") }
            registrations.append(reference)
        }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌃⌥⌘"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open paste test", action: #selector(openScratch), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Phrase Typer", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openScratch() { showScratch() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showScratch() {
        if let scratchWindow { scratchWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 190),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Phrase Typer paste test"
        let label = NSTextField(labelWithString: "Scratch field for testing phrase pastes. Nothing is sent automatically.")
        label.frame = NSRect(x: 18, y: 145, width: 520, height: 22)
        let view = NSTextView(frame: NSRect(x: 12, y: 12, width: 536, height: 120))
        view.isEditable = true
        view.isRichText = false
        view.font = .systemFont(ofSize: 15)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 536, height: 120))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(scroll)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        scratchWindow = window
        scratchView = view
    }

    private func fireHotkey(_ id: Int) {
        let digit = id == 10 ? "0" : String(id)
        guard let text = phrases[digit] else { return }
        log("hotkey Fn+\(digit) received")
        pending.append(PendingPaste(text: text, deadline: Date().addingTimeInterval(2.0)))
        processQueue()
    }

    private func modifiersAreReleased() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        return flags.intersection(modifiers).isEmpty
    }

    private func processQueue() {
        guard !pasteInProgress, let job = pending.first else { return }
        guard modifiersAreReleased() else {
            if Date() >= job.deadline {
                pending.removeFirst()
                log("phrase paste cancelled: modifier keys stayed held for 2 seconds")
                processQueue()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.processQueue() }
            }
            return
        }
        pending.removeFirst()
        pasteInProgress = true
        paste(job.text)
    }

    private func clipboardSnapshot() -> [ClipboardItem] {
        NSPasteboard.general.pasteboardItems?.map { item in
            ClipboardItem(values: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        } ?? []
    }

    private func clipboardMatches(_ expected: [ClipboardItem]) -> Bool {
        func normalized(_ items: [ClipboardItem]) -> [[String: String]] {
            items.map { item in Dictionary(uniqueKeysWithValues: item.values.map { ($0.0, $0.1.base64EncodedString()) }) }
        }
        return normalized(expected) == normalized(clipboardSnapshot())
    }

    private func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = clipboardSnapshot()
        board.clearContents()
        board.setString(text, forType: .string)
        let ownedChangeCount = board.changeCount
        guard postCommandV() else {
            if board.changeCount == ownedChangeCount { restoreClipboard(saved, to: board) }
            log("paste cancelled: could not create Command+V events")
            pasteInProgress = false
            processQueue()
            return
        }
        log("paste sent: \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if board.changeCount == ownedChangeCount {
                self?.restoreClipboard(saved, to: board)
                self?.log("clipboard restored")
            } else {
                self?.log("clipboard changed by another app; left it untouched")
            }
            self?.pasteInProgress = false
            self?.processQueue()
        }
    }

    private func restoreClipboard(_ saved: [ClipboardItem], to board: NSPasteboard) {
        board.clearContents()
        if !saved.isEmpty {
            let items = saved.map { savedItem -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in savedItem.values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                return item
            }
            board.writeObjects(items)
        }
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            log("could not create paste key events")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func beginSelfTest() {
        showScratch()
        guard let view = scratchView else { NSApp.terminate(nil); return }
        view.string = ""
        selfTestInitialClipboard = clipboardSnapshot()
        selfTestInitialChangeCount = NSPasteboard.general.changeCount
        postChordForSelfTestDown(keycode: 18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let view = self.scratchView else { return }
            self.selfTestHeldCheckPassed = view.string.isEmpty && NSPasteboard.general.changeCount == self.selfTestInitialChangeCount
            self.log("self-test held-chord \(self.selfTestHeldCheckPassed ? "PASS" : "FAIL"): no paste while modifiers are held")
            self.postChordForSelfTestUp(keycode: 18)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, let view = self.scratchView else { NSApp.terminate(nil); return }
            let expected = self.phrases["1"] ?? ""
            let clipboardRestored = self.clipboardMatches(self.selfTestInitialClipboard)
            let succeeded = self.selfTestHeldCheckPassed && view.string == expected && clipboardRestored
            self.log("self-test \(succeeded ? "PASS" : "FAIL"): deferred paste, exact scratch text, clipboard restored=\(clipboardRestored); got \(String(reflecting: view.string))")
            NSApp.terminate(nil)
        }
    }

    private func postChordForSelfTestDown(keycode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { log("self-test failed to create event source"); return }
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(59,.maskControl),(58,[.maskControl,.maskAlternate]),(55,[.maskControl,.maskAlternate,.maskCommand])]
        for (code, flags) in modifiers {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) { event.flags = flags; event.post(tap: .cghidEventTap) }
        }
        if let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true) {
            event.flags = CGEventFlags.maskControl.union(.maskAlternate).union(.maskCommand)
            event.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    private func postChordForSelfTestUp(keycode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) {
            event.flags = CGEventFlags.maskControl.union(.maskAlternate).union(.maskCommand)
            event.post(tap: .cghidEventTap)
        }
        let releases: [(CGKeyCode, CGEventFlags)] = [(55,[.maskControl,.maskAlternate]),(58,.maskControl),(59,[])]
        for (code, flags) in releases {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) { event.flags = flags; event.post(tap: .cghidEventTap) }
        }
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
            } else { try? data.write(to: logURL, options: .atomic) }
        }
    }
}

private func error(_ message: String) -> NSError {
    NSError(domain: "PhraseTyper", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = PhraseTyper()
app.delegate = delegate
app.run()
