import Foundation

struct ModifierHold {
    private var startedAt: TimeInterval?
    private var blocked = false

    mutating func update(chordDown: Bool, otherKeyDown: Bool, now: TimeInterval) -> Bool {
        guard chordDown else {
            startedAt = nil
            blocked = false
            return false
        }
        if otherKeyDown { blocked = true }
        guard !blocked else { return false }
        guard let startedAt else {
            self.startedAt = now
            return false
        }
        guard now - startedAt >= 3 else { return false }
        blocked = true
        return true
    }
}
