import Foundation
import IOKit
import IOKit.hid

private var lastReport: [UInt8]?
private let inputCallback: IOHIDReportCallback = { _, result, _, _, _, report, length in
    guard result == kIOReturnSuccess else { return }
    lastReport = Array(UnsafeBufferPointer(start: report, count: Int(length)))
}

struct Snapshot: Codable {
    let formatVersion: Int
    let uid: String
    let vialProtocol: UInt32
    let layers: Int
    let rows: Int
    let cols: Int
    let definitionXZ: String
    let keymap: String
}

struct PatchEntry: Codable, Equatable {
    let digit: String
    let phrase: String
    let row: Int
    let col: Int
    let original: UInt16
    let replacement: UInt16
}

struct PatchPlan: Codable, Equatable {
    let uid: String
    let entries: [PatchEntry]
}

final class VialDevice {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)

    init() throws {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x4b45, kIOHIDProductIDKey: 0x3635] as CFDictionary)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw error("HID manager open failed: 0x\(String(UInt32(bitPattern: status), radix: 16))") }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard let selected = devices.first(where: {
            (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue == 0xFF60 &&
            (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue == 0x61
        }) else { throw error("Vial HID interface was not found") }
        let openStatus = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else { throw error("Device open failed: 0x\(String(UInt32(bitPattern: openStatus), radix: 16)); quit Vial and retry") }
        device = selected
        reportBuffer.initialize(repeating: 0, count: 32)
        IOHIDDeviceRegisterInputReportCallback(selected, reportBuffer, 32, inputCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer.deallocate()
    }

    func send(_ payload: [UInt8]) throws -> [UInt8] {
        guard let device, payload.count <= 32 else { throw error("Invalid HID command") }
        var packet = [UInt8](repeating: 0, count: 32)
        packet.replaceSubrange(0..<payload.count, with: payload)
        lastReport = nil
        let status = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, CFIndex($0.count))
        }
        guard status == kIOReturnSuccess else { throw error("HID write failed: 0x\(String(UInt32(bitPattern: status), radix: 16))") }
        let deadline = Date().addingTimeInterval(2.0)
        while lastReport == nil && Date() < deadline { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true) }
        guard let response = lastReport else { throw error("Keyboard response timeout") }
        return response
    }
}

func error(_ message: String) -> NSError {
    NSError(domain: "MyKeyMapping", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func le32(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}

func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

func readSnapshot(_ vial: VialDevice) throws -> Snapshot {
    let id = try vial.send([0xFE, 0x00])
    let protocolVersion = le32(id)
    let uid = id[4..<12].map { String(format: "%02x", $0) }.joined()
    let size = Int(le32(try vial.send([0xFE, 0x01])))
    guard size > 0 && size < 1_000_000 else { throw error("Unexpected Vial definition size: \(size)") }
    var definition = Data()
    for block in 0..<((size + 31) / 32) {
        let n = UInt32(block)
        let response = try vial.send([0xFE, 0x02, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
        definition.append(contentsOf: response.prefix(min(32, size - definition.count)))
    }
    let layersResponse = try vial.send([0x11])
    let layers = Int(layersResponse[1])
    let definitionJSON = try decompressXZ(definition)
    guard let root = try JSONSerialization.jsonObject(with: definitionJSON) as? [String: Any],
          let matrix = root["matrix"] as? [String: Any],
          let rows = matrix["rows"] as? Int, let cols = matrix["cols"] as? Int,
          rows > 0, cols > 0, layers > 0 else { throw error("Vial definition has no valid matrix dimensions") }
    let byteCount = layers * rows * cols * 2
    var keymap = Data()
    for offset in stride(from: 0, to: byteCount, by: 28) {
        let count = min(28, byteCount - offset)
        let response = try vial.send([0x12, UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), UInt8(count)])
        guard response[0] == 0x12, response.count >= 4 + count else { throw error("Malformed keymap response at byte \(offset)") }
        keymap.append(contentsOf: response[4..<(4 + count)])
    }
    guard keymap.count == byteCount else { throw error("Incomplete keymap read") }
    return Snapshot(formatVersion: 1, uid: uid, vialProtocol: protocolVersion, layers: layers, rows: rows, cols: cols,
                    definitionXZ: definition.base64EncodedString(), keymap: keymap.base64EncodedString())
}

func decompressXZ(_ data: Data) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import lzma,sys;sys.stdout.buffer.write(lzma.decompress(sys.stdin.buffer.read()))"]
    let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = diagnostics
    try process.run()
    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "invalid XZ stream"
        throw error("Could not decode keyboard definition: \(detail)")
    }
    return result
}

func keycode(_ bytes: Data, _ snapshot: Snapshot, layer: Int, row: Int, col: Int) throws -> UInt16 {
    let offset = ((layer * snapshot.rows + row) * snapshot.cols + col) * 2
    guard offset + 1 < bytes.count else { throw error("Key position outside matrix") }
    return be16(Array(bytes), offset)
}

func layoutKeyOrder(_ snapshot: Snapshot) throws -> [String] {
    guard let compressed = Data(base64Encoded: snapshot.definitionXZ) else { throw error("Invalid saved layout definition") }
    let root = try JSONSerialization.jsonObject(with: decompressXZ(compressed)) as? [String: Any]
    let layouts = root?["layouts"] as? [String: Any]
    guard let rows = layouts?["keymap"] as? [[Any]] else { throw error("Could not read the physical key layout") }
    return rows.flatMap { $0.compactMap { $0 as? String } }
}

func makePlan(from snapshot: Snapshot, current: Snapshot) throws -> PatchPlan {
    guard current.uid == snapshot.uid, current.keymap == snapshot.keymap else {
        throw error("The live keyboard map differs from the pre-change backup; refusing to patch")
    }
    let bytes = Data(base64Encoded: snapshot.keymap)!
    let order = try layoutKeyOrder(snapshot)
    let digits: [(String, UInt16, String)] = [
        ("1", 0x001E, "push pr 진행"), ("2", 0x001F, "알려줘"), ("3", 0x0020, "계속해줘"),
        ("4", 0x0021, "진행해줘"), ("5", 0x0022, "확인해줘"), ("6", 0x0023, "artifact 확인"),
        ("7", 0x0024, "확인해봐"), ("8", 0x0025, "반영해줘"), ("9", 0x0026, "신규 이슈 발급해줘"),
        ("0", 0x0027, "수정해줘")
    ]
    var positions: [(String, UInt16, String, Int, Int, Int)] = []
    for (digit, code, phrase) in digits {
        var found: [(Int, Int)] = []
        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols where try keycode(bytes, snapshot, layer: 0, row: row, col: col) == code {
                found.append((row, col))
            }
        }
        guard found.count == 1 else { throw error("Base layer must contain exactly one physical \(digit) key; found \(found.count)") }
        let (row, col) = found[0]
        let label = "\(row),\(col)"
        guard let layoutIndex = order.firstIndex(of: label) else { throw error("Physical key \(label) is missing from the layout") }
        positions.append((digit, code, phrase, row, col, layoutIndex))
    }
    guard positions.map({ $0.5 }) == positions.map({ $0.5 }).sorted(),
          order.firstIndex(of: "4,1") != nil,
          try keycode(bytes, snapshot, layer: 0, row: 4, col: 1) == 0x5221 else {
        throw error("Physical digit order or Fn(MO(1)) position did not match the expected layout")
    }
    let entries = try positions.map { digit, code, phrase, row, col, _ -> PatchEntry in
        let original = try keycode(bytes, snapshot, layer: 1, row: row, col: col)
        return PatchEntry(digit: digit, phrase: phrase, row: row, col: col, original: original,
                          replacement: 0x0D00 | code)
    }
    return PatchPlan(uid: snapshot.uid, entries: entries)
}

func getUnlockState(_ vial: VialDevice) throws -> UInt8 {
    try vial.send([0xFE, 0x05])[0]
}

func setKey(_ vial: VialDevice, layer: UInt8, entry: PatchEntry, code: UInt16) throws {
    _ = try vial.send([0x05, layer, UInt8(entry.row), UInt8(entry.col), UInt8(code >> 8), UInt8(code & 0xFF)])
}

func expectedMap(_ snapshot: Snapshot, layer: Int, changes: [(PatchEntry, UInt16)]) throws -> Data {
    guard let original = Data(base64Encoded: snapshot.keymap) else { throw error("Invalid keymap snapshot") }
    var expected = original
    for (entry, code) in changes {
        let offset = ((layer * snapshot.rows + entry.row) * snapshot.cols + entry.col) * 2
        guard offset + 1 < expected.count else { throw error("Patch position outside saved keymap") }
        expected.replaceSubrange(offset..<(offset + 2), with: [UInt8(code >> 8), UInt8(code & 0xFF)])
    }
    return expected
}

func main() throws {
    let command = CommandLine.arguments.dropFirst().first ?? "backup"
    let vial = try VialDevice()
    let snapshot = try readSnapshot(vial)
    let backupURL = URL(fileURLWithPath: "backups/original-\(snapshot.uid).json")
    let planURL = URL(fileURLWithPath: "backups/patch-plan-\(snapshot.uid).json")
    if command == "backup" {
        if FileManager.default.fileExists(atPath: backupURL.path) { throw error("Backup already exists at \(backupURL.path); refusing to overwrite") }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = try JSONEncoder().encode(snapshot)
        try json.write(to: backupURL, options: .atomic)
        print("Saved pre-change device backup: \(backupURL.path)")
        print("UID \(snapshot.uid), Vial \(snapshot.vialProtocol), layers \(snapshot.layers), matrix \(snapshot.rows)x\(snapshot.cols), keymap bytes \(Data(base64Encoded: snapshot.keymap)!.count)")
    } else if command == "inspect" {
        let bytes = Data(base64Encoded: snapshot.keymap)!
        for row in 0..<snapshot.rows {
            let values = try (0..<snapshot.cols).map { col in String(format: "%04X", try keycode(bytes, snapshot, layer: 0, row: row, col: col)) }
            print("L0 row \(row): " + values.joined(separator: " "))
        }
        for row in 0..<snapshot.rows {
            let values = try (0..<snapshot.cols).map { col in String(format: "%04X", try keycode(bytes, snapshot, layer: 1, row: row, col: col)) }
            print("L1 row \(row): " + values.joined(separator: " "))
        }
        print("Backup: \(backupURL.path)")
    } else if command == "plan" || command == "apply" || command == "rollback" {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error("Required pre-change backup is missing: \(backupURL.path)") }
        let backup = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: backupURL))
        guard backup.uid == snapshot.uid else { throw error("Connected keyboard UID does not match the saved backup") }
        let plan: PatchPlan
        if command == "plan" {
            plan = try makePlan(from: backup, current: snapshot)
            try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
            print("Patch plan saved: \(planURL.path)")
            for e in plan.entries { print("Fn+\(e.digit) [\(e.row),\(e.col)] 0x\(String(e.original, radix: 16, uppercase: true)) -> 0x\(String(e.replacement, radix: 16, uppercase: true))  \(e.phrase)") }
        } else {
            guard FileManager.default.fileExists(atPath: planURL.path) else { throw error("Patch plan is missing; create and inspect it first") }
            plan = try JSONDecoder().decode(PatchPlan.self, from: Data(contentsOf: planURL))
            guard plan.uid == snapshot.uid else { throw error("Patch plan UID does not match the connected keyboard") }
            let bytes = Data(base64Encoded: snapshot.keymap)!
            let canonicalPlan = try makePlan(from: backup, current: backup)
            guard plan == canonicalPlan else { throw error("Saved patch plan differs from the backed-up layout; refusing to write") }
            if command == "apply" {
                guard snapshot.keymap == backup.keymap else { throw error("The live keymap changed after backup; refusing to overwrite") }
                let unlock = try getUnlockState(vial)
                guard unlock == 1 else { throw error("Vial reports the keyboard locked; press its physical unlock combination and retry") }
                for entry in plan.entries { try setKey(vial, layer: 1, entry: entry, code: entry.replacement) }
                let after = try readSnapshot(vial)
                let expected = try expectedMap(backup, layer: 1, changes: plan.entries.map { ($0, $0.replacement) })
                guard after.keymap == expected.base64EncodedString() else {
                    throw error("Full keymap read-back differs from the planned ten-key patch; no further writes were attempted")
                }
                print("Applied and read back \(plan.entries.count) Fn+digit mappings on layer 1.")
            } else {
                for entry in plan.entries {
                    let current = try keycode(bytes, snapshot, layer: 1, row: entry.row, col: entry.col)
                    guard current == entry.original || current == entry.replacement else {
                        throw error("Rollback stopped before writing: Fn+\(entry.digit) is 0x\(String(current, radix: 16)); expected original or configured value")
                    }
                }
                let unlock = try getUnlockState(vial)
                guard unlock == 1 else { throw error("Vial reports the keyboard locked; press its physical unlock combination and retry") }
                let rollbackChanges = try plan.entries.compactMap { entry -> (PatchEntry, UInt16)? in
                    let current = try keycode(bytes, snapshot, layer: 1, row: entry.row, col: entry.col)
                    return current == entry.replacement ? (entry, entry.original) : nil
                }
                let expected = try expectedMap(snapshot, layer: 1, changes: rollbackChanges)
                for entry in plan.entries where try keycode(bytes, snapshot, layer: 1, row: entry.row, col: entry.col) == entry.replacement {
                    try setKey(vial, layer: 1, entry: entry, code: entry.original)
                }
                let after = try readSnapshot(vial)
                guard after.keymap == expected.base64EncodedString() else {
                    throw error("Rollback read-back differs from the mapped-key restoration; other live edits were preserved")
                }
                print("Restored all \(plan.entries.count) mapped Fn+digit keys to their backed-up values.")
            }
        }
    } else {
        throw error("Usage: VialSetup.swift backup|inspect|plan|apply|rollback")
    }
}

do { try main() } catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
