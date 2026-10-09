import AppKit

/// A user-assigned keyboard shortcut for a single sound, stored as a raw key code + modifier flags
/// so it round-trips through JSON without depending on AppKit's event types.
struct SoundShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifierFlags: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.keyCode = event.keyCode
        self.modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue == modifierFlags
    }

    /// Human readable representation, e.g. "⌘⇧S".
    var displayString: String {
        var result = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += SoundShortcut.keyName(for: keyCode)
        return result
    }

    static func keyName(for keyCode: UInt16) -> String {
        Self.keyCodeNames[keyCode] ?? "?"
    }

    private static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-",
        81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9", 36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1"
    ]
}
