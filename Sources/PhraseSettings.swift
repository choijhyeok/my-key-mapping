import AppKit
import ApplicationServices
import Foundation

private struct EditablePhrase: Codable {
    let digit: String
    let text: String
}

private let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
private let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MyKeyMapping", isDirectory: true)
private let configuration = support.appendingPathComponent("phrases.json")

final class PhraseSettings: NSObject, NSApplicationDelegate {
    private var hold = ModifierHold()
    private var timer: Timer?
    private var window: NSWindow?
    private var fields: [NSTextField] = []
    private var originalData: Data?
    private var saveButton: NSButton?
    private var message: NSTextField?
    private var statusItem: NSStatusItem?
    private var saving = false
    private var restartTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollModifiers() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        print("settings ready: hold Control+Option+Command for 3 seconds", terminator: "\n")
        fflush(stdout)
        if CommandLine.arguments.contains("--show") { showSettings(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    private func pollModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let required: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let relevant = required.union(.maskShift)
        let chordDown = flags.intersection(relevant) == required
        // Ignore modifier keys themselves. A digit or other key blocks opening until release.
        let modifierKeys: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        let otherKeyDown = chordDown && (0..<128).contains {
            !modifierKeys.contains(CGKeyCode($0)) && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
        if hold.update(chordDown: chordDown, otherKeyDown: otherKeyDown, now: ProcessInfo.processInfo.systemUptime) {
            showSettings(nil)
            print("settings opened: modifier hold", terminator: "\n")
            fflush(stdout)
        }
    }

    private func installMenus() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "문구 설정 종료", action: #selector(quit), keyEquivalent: "q").target = self
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        for (title, selector, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"),
                                      ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "문구"
        let menu = NSMenu()
        menu.addItem(withTitle: "Fn 문구 보기 및 수정…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "문구 설정 종료", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings(_ sender: Any?) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        do {
            let data = try Data(contentsOf: configuration)
            let entries = try JSONDecoder().decode([EditablePhrase].self, from: data)
            guard entries.count == 10, Set(entries.map(\.digit)) == Set(digits) else {
                throw failure("문구 파일에는 숫자 0~9가 각각 한 번씩 있어야 합니다.")
            }
            let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.digit, $0.text) })
            originalData = data
            buildWindow(values)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func buildWindow(_ values: [String: String]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 548),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fn 단축키 문구 설정"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let heading = NSTextField(labelWithString: "현재 문구를 확인하고 수정할 수 있습니다.")
        heading.font = .boldSystemFont(ofSize: 16)
        heading.frame = NSRect(x: 24, y: 500, width: 590, height: 24)
        content.addSubview(heading)
        let description = NSTextField(labelWithString: "Control + Option + Command를 3초간 누르면 이 창이 열립니다.")
        description.frame = NSRect(x: 24, y: 474, width: 590, height: 22)
        content.addSubview(description)
        fields = []
        for (index, digit) in digits.enumerated() {
            let y = CGFloat(428 - index * 36)
            let label = NSTextField(labelWithString: "Fn + \(digit)")
            label.frame = NSRect(x: 26, y: y + 4, width: 75, height: 22)
            content.addSubview(label)
            let field = NSTextField(string: values[digit] ?? "")
            field.frame = NSRect(x: 110, y: y, width: 506, height: 28)
            field.font = .systemFont(ofSize: 14)
            content.addSubview(field)
            fields.append(field)
        }
        let message = NSTextField(labelWithString: "저장하면 Fn 단축키에 바로 반영됩니다. Enter는 자동 전송하지 않습니다.")
        message.frame = NSRect(x: 24, y: 60, width: 592, height: 24)
        content.addSubview(message)
        self.message = message
        let cancel = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        cancel.frame = NSRect(x: 434, y: 18, width: 80, height: 32)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
        let save = NSButton(title: "저장", target: self, action: #selector(savePhrases))
        save.frame = NSRect(x: 530, y: 18, width: 86, height: 32)
        save.bezelStyle = .rounded
        content.addSubview(save)
        saveButton = save
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(fields.first)
        self.window = window
    }

    @objc private func closeWindow() { if !saving { window?.close() } }
    @objc private func quit() { if !saving { NSApp.terminate(nil) } }

    @objc private func savePhrases() {
        guard !saving else { return }
        window?.makeFirstResponder(nil)
        do {
            guard let originalData, try Data(contentsOf: configuration) == originalData else {
                throw failure("다른 곳에서 문구 파일이 변경됐습니다. 창을 닫고 다시 열어 주세요.")
            }
            let entries = zip(digits, fields).map { EditablePhrase(digit: $0.0, text: $0.1.stringValue) }
            guard entries.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw failure("입력 문구를 비워 둘 수 없습니다.")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(entries)
            try data.write(to: configuration, options: .atomic)
            self.originalData = data
            saving = true
            saveButton?.isEnabled = false
            message?.stringValue = "저장했습니다. 자동 입력 도우미에 반영 중…"
            waitForClipboardBeforeRestart()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func waitForClipboardBeforeRestart() {
        var changeCount = NSPasteboard.general.changeCount
        var quietSince = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let current = NSPasteboard.general.changeCount
            if current != changeCount {
                changeCount = current
                quietSince = now
            }
            // PhraseTyper restores the clipboard after 1.2 seconds. Waiting for a
            // longer quiet period also allows queued pastes to finish first.
            if now - quietSince >= 1.6 {
                timer.invalidate()
                self.restartTimer = nil
                self.restartTyper()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    private func restartTyper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.jaehyeokchoi.MyKeyMapping.PhraseTyper"]
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.saving = false
                self?.saveButton?.isEnabled = true
                self?.message?.stringValue = process.terminationStatus == 0
                    ? "저장 완료 · Fn 단축키에 반영했습니다."
                    : "문구는 저장됐지만 도우미를 다시 시작하지 못했습니다."
            }
        }
        do { try process.run() } catch {
            saving = false
            saveButton?.isEnabled = true
            message?.stringValue = "문구는 저장됐지만 도우미 실행에 실패했습니다."
        }
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "문구 설정"
        alert.informativeText = text
        alert.runModal()
    }
}

private func failure(_ text: String) -> NSError {
    NSError(domain: "PhraseSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = PhraseSettings()
app.delegate = delegate
app.run()
