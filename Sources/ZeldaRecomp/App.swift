import AppKit
import MetalKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import NESCore

@main
enum ZeldaRecompMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Metal view that also receives keyboard input for the game.
final class GameView: MTKView {
    var input: InputManager?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        if onKeyDown?(event) == true { return }
        _ = input?.keyDown(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) == true { return }
        input?.keyUp(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        let f = event.modifierFlags
        let down: Bool
        switch event.keyCode {
        case 56, 60: down = f.contains(.shift)
        case 59, 62: down = f.contains(.control)
        case 58, 61: down = f.contains(.option)
        case 57: down = f.contains(.capsLock)
        default: return
        }
        if down { _ = input?.keyDown(event.keyCode) } else { input?.keyUp(event.keyCode) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = SettingsStore()
    lazy var input = InputManager(store: store)
    let core = EmulatorCore()
    var audio: AudioOutput?
    var window: NSWindow!
    var view: GameView!
    var renderer: Renderer?
    var settingsWindow: NSWindow?
    var statsLabel: NSTextField!
    var toastLabel: NSTextField!
    var toastTimer: Timer?
    var cancellables = Set<AnyCancellable>()
    var slot = 1
    var userPaused = false
    var pauseItem: NSMenuItem?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let a = AudioOutput(ring: core.audioRing)
        audio = a
        core.audioSampleRate = a.sampleRate
        a.volume = store.system.volume
        createWindow()
        store.$system
            .sink { [weak self] s in
                self?.core.apply(system: s)
                self?.audio?.volume = s.volume
            }
            .store(in: &cancellables)
        store.$graphics
            .sink { [weak self] g in self?.statsLabel?.isHidden = !g.showStats }
            .store(in: &cancellables)
        openInitialROM()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        core.flushBattery()
        writeCoverageFile()
        core.stop()
        audio?.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        input.clearKeys()
        if store.system.pauseInBackground { core.paused = true }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        core.paused = userPaused
    }

    // MARK: window

    private func createWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1170, height: 960)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "The Legend of Zelda — Recomp"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 512, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self

        view = GameView(frame: rect, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.input = input
        view.onKeyDown = { [weak self] e in self?.hotkeyDown(e) ?? false }
        view.onKeyUp = { [weak self] e in self?.hotkeyUp(e) ?? false }
        guard let r = Renderer(view: view, core: core, store: store, input: input) else {
            let alert = NSAlert()
            alert.messageText = "Metal renderer failed to initialise"
            alert.informativeText = Renderer.lastError ?? "No Metal device available."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        renderer = r
        view.delegate = r
        window.contentView = view

        statsLabel = overlayLabel(size: 11, weight: .medium)
        statsLabel.isHidden = !store.graphics.showStats
        view.addSubview(statsLabel)
        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statsLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        r.statsHandler = { [weak self] s in
            guard let self else { return }
            self.statsLabel.stringValue = s
        }

        toastLabel = overlayLabel(size: 15, weight: .semibold)
        toastLabel.alphaValue = 0
        view.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func overlayLabel(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = .white
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        l.layer?.cornerRadius = 6
        l.translatesAutoresizingMaskIntoConstraints = false
        l.drawsBackground = false
        return l
    }

    func toast(_ text: String) {
        toastLabel.stringValue = "  \(text)  "
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastLabel.animator().alphaValue = 1
        }
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.toastLabel.animator().alphaValue = 0
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) { input.clearKeys() }

    // MARK: hotkeys (handled in the game view so they never reach the game)

    private func hotkeyDown(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 122: // F1: hold to compare with the original image
            renderer?.compareOriginal = true
            toast("Original")
            return true
        case 120: cyclePreset(); return true      // F2
        case 99: toggleStats(nil); return true    // F3
        case 53:                                  // Esc leaves full screen
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return true }
            return false
        default: return false
        }
    }

    private func hotkeyUp(_ e: NSEvent) -> Bool {
        if e.keyCode == 122 { renderer?.compareOriginal = false; return true }
        return false
    }

    private var presetIndex = GraphicsPreset.allCases.firstIndex(of: .remastered) ?? 0

    private func cyclePreset() {
        let all = GraphicsPreset.allCases
        presetIndex = (presetIndex + 1) % all.count
        store.apply(preset: all[presetIndex])
        toast("Preset: \(all[presetIndex].rawValue)")
    }

    // MARK: ROM

    private func openInitialROM() {
        let fm = FileManager.default
        var candidates: [String] = []
        if let p = UserDefaults.standard.string(forKey: "zr.romPath") { candidates.append(p) }
        if let p = Bundle.main.object(forInfoDictionaryKey: "ZRDefaultROMPath") as? String { candidates.append(p) }
        for p in candidates where fm.fileExists(atPath: p) {
            if load(URL(fileURLWithPath: p)) { return }
        }
        openROM(nil)
    }

    @discardableResult
    private func load(_ url: URL) -> Bool {
        do {
            try core.load(romURL: url, settings: store.system)
            UserDefaults.standard.set(url.path, forKey: "zr.romPath")
            if nes_recomp_available() != 0 && !core.recompMatches {
                toast("This ROM differs from the recompiled one — using the interpreter")
            } else if core.recompMatches {
                toast("Native recompiled code active")
            }
            return true
        } catch {
            let a = NSAlert()
            a.messageText = "Could not load ROM"
            a.informativeText = error.localizedDescription
            a.runModal()
            return false
        }
    }

    @objc func openROM(_ sender: Any?) {
        let p = NSOpenPanel()
        p.title = "Choose your The Legend of Zelda ROM (.nes)"
        p.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: "nes") { p.allowedContentTypes = [t] }
        if p.runModal() == .OK, let url = p.url { load(url) }
    }

    // MARK: menu actions

    @objc func togglePause(_ sender: Any?) {
        userPaused.toggle()
        core.paused = userPaused
        pauseItem?.title = userPaused ? "Resume" : "Pause"
        toast(userPaused ? "Paused" : "Resumed")
    }

    @objc func softReset(_ sender: Any?) { core.reset(hard: false); toast("Reset") }
    @objc func hardReset(_ sender: Any?) { core.flushBattery(); core.reset(hard: true); toast("Power cycled") }

    @objc func quickSave(_ sender: Any?) { toast(core.saveState(slot: slot) ? "Saved state \(slot)" : "Save failed") }
    @objc func quickLoad(_ sender: Any?) { toast(core.loadState(slot: slot) ? "Loaded state \(slot)" : "No state in slot \(slot)") }
    @objc func selectSlot(_ sender: NSMenuItem) { slot = sender.tag; toast("State slot \(slot)") }

    @objc func applyPresetItem(_ sender: NSMenuItem) {
        let p = GraphicsPreset.allCases[sender.tag]
        presetIndex = sender.tag
        store.apply(preset: p)
        toast("Preset: \(p.rawValue)")
    }

    @objc func toggleStats(_ sender: Any?) {
        store.graphics.showStats.toggle()
        toast(store.graphics.showStats ? "Stats on" : "Stats off")
    }

    @objc func toggleFullScreen(_ sender: Any?) { window.toggleFullScreen(nil) }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store, input: input, core: core))
            let w = NSWindow(contentViewController: host)
            w.title = "Zelda Recomp Settings"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 600, height: 720))
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "The Legend of Zelda — Native Recomp"
        a.informativeText = """
        A static recompilation of the NES game's 6502 code into native C, running on a cycle-counted \
        PPU/APU runtime with a Metal 2026-style renderer (relief lighting, shadows, dynamic lights, HDR bloom).

        Requires your own ROM dump; no game data is included.
        Recompiled code: \(nes_recomp_available() != 0 ? String(format: "built for PRG CRC %08X", nes_recomp_rom_crc()) : "not generated (interpreter only)")
        Loaded ROM: \(core.isLoaded ? String(format: "PRG CRC %08X", core.romCRC) : "none")
        """
        a.runModal()
    }

    @objc func exportCoverage(_ sender: Any?) {
        let report = core.coverageReport()
        let p = NSSavePanel()
        p.nameFieldStringValue = "coverage_misses.txt"
        if p.runModal() == .OK, let url = p.url {
            try? report.write(to: url, atomically: true, encoding: .utf8)
            toast(report.isEmpty ? "No interpreter fallbacks so far" : "Coverage exported")
        }
    }

    @objc func openSaveFolder(_ sender: Any?) {
        NSWorkspace.shared.open(EmulatorCore.supportDirectory)
    }

    private func writeCoverageFile() {
        let report = core.coverageReport()
        guard !report.isEmpty else { return }
        let dir = EmulatorCore.supportDirectory.appendingPathComponent("coverage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(format: "misses_%08X_%d.txt", core.romCRC, Int(Date().timeIntervalSince1970)))
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: menu

    private func fkey(_ k: Int) -> String { String(Character(UnicodeScalar(UInt32(k))!)) }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Zelda Recomp", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Zelda Recomp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Zelda Recomp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "Game")
        file.addItem(withTitle: "Open ROM…", action: #selector(openROM(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        let qs = file.addItem(withTitle: "Quick Save", action: #selector(quickSave(_:)), keyEquivalent: fkey(NSF5FunctionKey))
        qs.keyEquivalentModifierMask = []
        let ql = file.addItem(withTitle: "Quick Load", action: #selector(quickLoad(_:)), keyEquivalent: fkey(NSF8FunctionKey))
        ql.keyEquivalentModifierMask = []
        let slotItem = NSMenuItem(title: "State Slot", action: nil, keyEquivalent: "")
        let slots = NSMenu()
        for i in 1...9 {
            let it = slots.addItem(withTitle: "Slot \(i)", action: #selector(selectSlot(_:)), keyEquivalent: "\(i)")
            it.keyEquivalentModifierMask = [.option]
            it.tag = i
        }
        slotItem.submenu = slots
        file.addItem(slotItem)
        file.addItem(.separator())
        file.addItem(withTitle: "Open Save Folder", action: #selector(openSaveFolder(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Export Recompiler Coverage…", action: #selector(exportCoverage(_:)), keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        let emuItem = NSMenuItem()
        let emu = NSMenu(title: "Emulation")
        pauseItem = emu.addItem(withTitle: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "p")
        emu.addItem(withTitle: "Reset", action: #selector(softReset(_:)), keyEquivalent: "r")
        let hr = emu.addItem(withTitle: "Power Cycle", action: #selector(hardReset(_:)), keyEquivalent: "r")
        hr.keyEquivalentModifierMask = [.command, .shift]
        emuItem.submenu = emu
        main.addItem(emuItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (i, p) in GraphicsPreset.allCases.enumerated() {
            let it = viewMenu.addItem(withTitle: "Preset: \(p.rawValue)", action: #selector(applyPresetItem(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i
        }
        viewMenu.addItem(.separator())
        let st = viewMenu.addItem(withTitle: "Show Performance Stats", action: #selector(toggleStats(_:)), keyEquivalent: fkey(NSF3FunctionKey))
        st.keyEquivalentModifierMask = []
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
