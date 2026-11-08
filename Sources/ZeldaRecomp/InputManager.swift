import AppKit
import GameController

/// Collects keyboard + game controller state and maps it to NES buttons using the user's bindings.
final class InputManager {
    private let store: SettingsStore
    private var keysDown = Set<UInt16>()
    private(set) var padDown = Set<PadElement>()
    /// When non-nil, the next key / pad press is delivered here instead of to the game (rebinding UI).
    var keyCapture: ((UInt16) -> Void)?
    var padCapture: ((PadElement) -> Void)?
    private(set) var connectedControllers: [String] = []

    init(store: SettingsStore) {
        self.store = store
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshControllers() }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshControllers() }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refreshControllers()
    }

    private func refreshControllers() {
        connectedControllers = GCController.controllers().compactMap { $0.extendedGamepad != nil ? ($0.vendorName ?? "Controller") : nil }
    }

    // MARK: keyboard

    /// Returns true if the key was consumed.
    func keyDown(_ code: UInt16) -> Bool {
        if let cap = keyCapture { keyCapture = nil; cap(code); return true }
        keysDown.insert(code)
        return true
    }

    func keyUp(_ code: UInt16) { keysDown.remove(code) }
    func clearKeys() { keysDown.removeAll() }
    func isKeyDown(_ code: UInt16) -> Bool { keysDown.contains(code) }

    // MARK: controllers

    func poll() {
        var now = Set<PadElement>()
        let dz = store.input.stickDeadzone
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            if g.dpad.up.isPressed { now.insert(.dpadUp) }
            if g.dpad.down.isPressed { now.insert(.dpadDown) }
            if g.dpad.left.isPressed { now.insert(.dpadLeft) }
            if g.dpad.right.isPressed { now.insert(.dpadRight) }
            let x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value
            // 4-way with dominant axis: Zelda is a 4-direction game
            if abs(x) > dz || abs(y) > dz {
                if abs(x) >= abs(y) { now.insert(x > 0 ? .stickRight : .stickLeft) }
                else { now.insert(y > 0 ? .stickUp : .stickDown) }
            }
            if g.buttonA.isPressed { now.insert(.buttonA) }
            if g.buttonB.isPressed { now.insert(.buttonB) }
            if g.buttonX.isPressed { now.insert(.buttonX) }
            if g.buttonY.isPressed { now.insert(.buttonY) }
            if g.leftShoulder.isPressed { now.insert(.leftShoulder) }
            if g.rightShoulder.isPressed { now.insert(.rightShoulder) }
            if g.leftTrigger.isPressed { now.insert(.leftTrigger) }
            if g.rightTrigger.isPressed { now.insert(.rightTrigger) }
            if g.buttonMenu.isPressed { now.insert(.menu) }
            if g.buttonOptions?.isPressed == true { now.insert(.options) }
        }
        if let cap = padCapture, let newly = now.subtracting(padDown).first {
            padCapture = nil
            cap(newly)
        }
        padDown = now
    }

    /// Current NES controller byte.
    func buttons() -> UInt8 {
        if keyCapture != nil || padCapture != nil { return 0 }
        var m: UInt8 = 0
        let s = store.input
        for b in NESButton.allCases {
            if s.keyCodes(b).contains(where: { keysDown.contains($0) }) || s.padElements(b).contains(where: { padDown.contains($0) }) {
                m |= b.mask
            }
        }
        return m
    }

    var fastForwardHeld: Bool {
        keysDown.contains(store.input.fastForwardKey) || padDown.contains(store.input.fastForwardPad)
    }

    // MARK: names

    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 55: "⌘", 56: "Shift", 57: "Caps Lock",
            58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 76: "Enter",
            123: "←", 124: "→", 125: "↓", 126: "↑", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
            43: ",", 47: ".", 44: "/", 42: "\\",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
            82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7",
            91: "Num 8", 92: "Num 9",
        ]
        if let s = special[code] { return s }
        let letters: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return letters[code] ?? "Key \(code)"
    }
}
