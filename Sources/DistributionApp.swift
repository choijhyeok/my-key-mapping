import AppKit
import Foundation

private let prefix = "com.jaehyeokchoi.MyKeyMapping."
private let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MyKeyMapping", isDirectory: true)
private let logs = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/MyKeyMapping", isDirectory: true)

private func failure(_ message: String) -> NSError {
    NSError(domain: "MyKeyMapping", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@discardableResult
private func command(_ executable: String, _ arguments: [String], required: Bool = true) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if required && process.terminationStatus != 0 {
        throw failure(String(data: data, encoding: .utf8) ?? "실행 실패: \(executable)")
    }
    return process.terminationStatus
}

private func validateBundle() throws {
    for name in ["PhraseTyper", "PhraseSettings"] {
        let app = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name).app")
        guard Bundle(url: app)?.bundleIdentifier == prefix + name,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(name)").path) else {
            throw failure("설치 파일에서 \(name) 앱을 찾을 수 없습니다.")
        }
    }
    guard let configuration = Bundle.main.url(forResource: "phrases", withExtension: "json") else {
        throw failure("기본 문구 파일이 없습니다.")
    }
    try validatePhrases(Data(contentsOf: configuration))
}

private func validatePhrases(_ data: Data) throws {
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: String]],
          entries.count == 10, Set(entries.compactMap { $0["digit"] }) == Set("0123456789".map(String.init)),
          entries.allSatisfy({ $0["text"] != nil }) else {
        throw failure("문구 파일에는 숫자 0~9와 입력 문구가 각각 한 번씩 있어야 합니다.")
    }
}

final class DistributionApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var message: NSTextField?
    private var startButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "MyKeyMapping 종료", action: #selector(quit), keyEquivalent: "q").target = self
        item.submenu = menu
        main.addItem(item)
        NSApp.mainMenu = main
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 330),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MyKeyMapping"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let heading = NSTextField(labelWithString: "자주 쓰는 문구를 단축키로 입력하세요")
        heading.font = .boldSystemFont(ofSize: 21)
        heading.frame = NSRect(x: 24, y: 270, width: 550, height: 30)
        content.addSubview(heading)
        let body = NSTextField(wrappingLabelWithString: "Control + Option + Command + 숫자: 문구 입력\nControl + Option + Command 3초 유지: 문구 보기 및 수정\n\n1. 설치 및 실행을 누르세요.\n2. 손쉬운 사용에서 PhraseTyper 앱의 입력 권한을 켜세요.\n3. 설치 및 실행을 다시 누르면 새 권한으로 시작합니다.")
        body.frame = NSRect(x: 24, y: 111, width: 550, height: 148)
        content.addSubview(body)
        let message = NSTextField(wrappingLabelWithString: "기존 문구는 유지됩니다. Fn 키는 Vial에서 연결할 수 있습니다.")
        message.frame = NSRect(x: 24, y: 60, width: 550, height: 43)
        content.addSubview(message)
        self.message = message
        let start = NSButton(title: "설치 및 실행", target: self, action: #selector(installAndStart))
        start.bezelStyle = .rounded
        start.frame = NSRect(x: 22, y: 20, width: 145, height: 32)
        content.addSubview(start)
        startButton = start
        let permissions = NSButton(title: "입력 권한 설정", target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .rounded
        permissions.frame = NSRect(x: 184, y: 20, width: 170, height: 32)
        content.addSubview(permissions)
        let settings = NSButton(title: "문구 설정 열기", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.frame = NSRect(x: 372, y: 20, width: 190, height: 32)
        content.addSubview(settings)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func installAndStart() {
        startButton?.isEnabled = false
        message?.stringValue = "설치 및 실행 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.install()
                DispatchQueue.main.async {
                    self?.message?.stringValue = "실행했습니다. 첫 설치 또는 업데이트 후에는 입력 권한을 허용하세요."
                    self?.startButton?.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    self?.message?.stringValue = error.localizedDescription
                    self?.startButton?.isEnabled = true
                }
            }
        }
    }

    private func install() throws {
        try validateBundle()
        let manager = FileManager.default
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        let configuration = support.appendingPathComponent("phrases.json")
        if manager.fileExists(atPath: configuration.path) {
            try validatePhrases(Data(contentsOf: configuration))
        } else {
            try manager.copyItem(at: Bundle.main.url(forResource: "phrases", withExtension: "json")!, to: configuration)
        }
        let agents = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try manager.createDirectory(at: agents, withIntermediateDirectories: true)
        for name in ["PhraseTyper", "PhraseSettings"] {
            let label = prefix + name
            let service = "gui/\(getuid())/\(label)"
            let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name).app")
            let target = support.appendingPathComponent("\(name).app")
            let existed = manager.fileExists(atPath: target.path)
            if existed && Bundle(url: target)?.bundleIdentifier != label {
                throw failure("다른 앱이 설치 경로를 사용 중입니다: \(target.path)")
            }
            let binary = "Contents/MacOS/\(name)"
            let changed: Bool
            if existed {
                changed = try Data(contentsOf: source.appendingPathComponent(binary)) !=
                    Data(contentsOf: target.appendingPathComponent(binary))
            } else {
                changed = true
            }
            if try command("/bin/launchctl", ["print", service], required: false) == 0 {
                try command("/bin/launchctl", ["bootout", service])
            }
            if changed {
                let staging = support.appendingPathComponent(".\(name)-\(UUID().uuidString).app")
                let previous = support.appendingPathComponent(".\(name)-previous-\(UUID().uuidString).app")
                try manager.copyItem(at: source, to: staging)
                do {
                    if existed { try manager.moveItem(at: target, to: previous) }
                    try manager.moveItem(at: staging, to: target)
                } catch {
                    if manager.fileExists(atPath: previous.path) && !manager.fileExists(atPath: target.path) {
                        try? manager.moveItem(at: previous, to: target)
                    }
                    if manager.fileExists(atPath: staging.path) { try? manager.removeItem(at: staging) }
                    throw error
                }
                if existed && name == "PhraseTyper" {
                    // An ad-hoc update changes the code requirement; clear only this app's stale grant.
                    try command("/usr/bin/tccutil", ["reset", "Accessibility", label])
                }
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
            }
            let definition: [String: Any] = [
                "Label": label, "ProgramArguments": [target.appendingPathComponent(binary).path], "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua", "StandardOutPath": logs.appendingPathComponent("\(name).out.log").path,
                "StandardErrorPath": logs.appendingPathComponent("\(name).err.log").path
            ]
            let plist = agents.appendingPathComponent("\(label).plist")
            try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: plist, options: .atomic)
            try command("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
        }
    }

    @objc private func openPermissions() {
        let helper = support.appendingPathComponent("PhraseTyper.app")
        if FileManager.default.fileExists(atPath: helper.path) { NSWorkspace.shared.activateFileViewerSelecting([helper]) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        let helper = support.appendingPathComponent("PhraseSettings.app")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            message?.stringValue = "먼저 설치 및 실행을 눌러 주세요."
            return
        }
        let options = NSWorkspace.OpenConfiguration()
        options.arguments = ["--show"]
        NSWorkspace.shared.openApplication(at: helper, configuration: options) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.message?.stringValue = error.localizedDescription } }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--validate-bundle") {
    do { try validateBundle(); print("PASS: bundled helpers and default configuration"); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = DistributionApp()
app.delegate = delegate
app.run()
