import SwiftUI
import AppKit
import NESCore

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let input: InputManager
    let core: EmulatorCore

    var body: some View {
        TabView {
            GraphicsTab(store: store)
                .tabItem { Label("Graphics", systemImage: "sparkles") }
            LightingTab(store: store)
                .tabItem { Label("Lighting", systemImage: "sun.max") }
            UltraTab(store: store)
                .tabItem { Label("Ultra 2026", systemImage: "wand.and.stars") }
            PostTab(store: store)
                .tabItem { Label("Post FX", systemImage: "camera.filters") }
            ControlsTab(store: store, input: input)
                .tabItem { Label("Controls", systemImage: "gamecontroller") }
            SystemTab(store: store, core: core)
                .tabItem { Label("Audio & System", systemImage: "speaker.wave.3") }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 640)
    }
}

// MARK: - helpers

struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.2f"
    var body: some View {
        HStack {
            Text(title).frame(width: 160, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

struct PresetBar: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        HStack(spacing: 6) {
            ForEach(GraphicsPreset.allCases) { p in
                Button(p.rawValue) { store.apply(preset: p) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Graphics

struct GraphicsTab: View {
    @ObservedObject var store: SettingsStore
    var edrAvailable: Bool { (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1 }

    var body: some View {
        Form {
            Section("Presets") {
                PresetBar(store: store)
                Text("Hold F1 in game to compare with the original image. F2 cycles presets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Image") {
                Picker("Upscaler", selection: $store.graphics.upscaler) {
                    ForEach(Upscaler.allCases) { Text($0.label).tag($0) }
                }
                Picker("Internal resolution", selection: $store.graphics.internalScale) {
                    ForEach([2, 3, 4, 5, 6, 8], id: \.self) { s in Text("\(s)× (\(256 * s)×\(240 * s))").tag(s) }
                }
                Picker("Aspect ratio", selection: $store.graphics.aspect) {
                    ForEach(AspectMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Palette", selection: $store.graphics.palette) {
                    ForEach(PaletteChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Ambient fill (blurred side panels)", isOn: $store.graphics.ambientFill)
            }
            Section("Display") {
                Toggle("HDR / EDR output\(edrAvailable ? "" : " (this display has no EDR headroom)")", isOn: $store.graphics.hdrOutput)
                Toggle("V-Sync", isOn: $store.graphics.vsync)
                Toggle("Show performance stats (F3)", isOn: $store.graphics.showStats)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Lighting

struct LightingTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Section {
                Toggle("Relief lighting", isOn: $store.graphics.lighting)
            } footer: {
                Text("Derives height and normals from the scenery, lights it with a sun and sky, and adds soft shadows. The HUD is never lit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sun & sky") {
                SliderRow(title: "Sun direction", value: $store.graphics.sunAngle, range: 0...360, format: "%.0f°")
                SliderRow(title: "Sun elevation", value: $store.graphics.sunElevation, range: 10...85, format: "%.0f°")
                SliderRow(title: "Sun intensity", value: $store.graphics.sunIntensity, range: 0...1.5)
                SliderRow(title: "Ambient light", value: $store.graphics.ambient, range: 0...1.2)
            }
            .disabled(!store.graphics.lighting)
            Section("Surfaces") {
                SliderRow(title: "Relief depth", value: $store.graphics.reliefDepth, range: 0...2.5)
                SliderRow(title: "Scenery height", value: $store.graphics.objectHeight, range: 1...16, format: "%.0f px")
                SliderRow(title: "Sprite volume", value: $store.graphics.spriteVolume, range: 0...2)
                SliderRow(title: "Ambient occlusion", value: $store.graphics.ambientOcclusion, range: 0...1)
                Toggle("Animated water", isOn: $store.graphics.water)
            }
            .disabled(!store.graphics.lighting)
            Section("Shadows") {
                Toggle("Cast shadows (scenery + characters)", isOn: $store.graphics.shadows)
                SliderRow(title: "Shadow strength", value: $store.graphics.shadowStrength, range: 0...1)
                SliderRow(title: "Shadow softness", value: $store.graphics.shadowSoftness, range: 0...3)
            }
            .disabled(!store.graphics.lighting)
            Section("Dynamic lights") {
                Toggle("Flames & lantern light", isOn: $store.graphics.dynamicLights)
                SliderRow(title: "Light intensity", value: $store.graphics.lightIntensity, range: 0...3)
                SliderRow(title: "Emissive glow", value: $store.graphics.emissiveStrength, range: 0...5)
                SliderRow(title: "Cave & dungeon darkness", value: $store.graphics.indoorDarkness, range: 0...0.95)
            }
            .disabled(!store.graphics.lighting)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ultra

struct UltraTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Enable Ultra 2026") { store.apply(preset: .ultra) }
                        .buttonStyle(.borderedProminent)
                    Button("Turn all Ultra effects off") {
                        var g = store.graphics
                        g.giBounce = 0; g.cloudShadows = 0; g.windSway = 0; g.lightShafts = 0; g.particles = 0
                        g.waterReflections = 0; g.depthOfField = 0; g.anamorphicFlare = 0; g.ultraShadows = false
                        store.graphics = g
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                Text("Ultra builds on Remastered: 6× internal resolution, double shadow samples and the effects below. Every slider is live; set one to 0 to disable it. Lighting-based effects need Relief lighting on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Light") {
                SliderRow(title: "Global illumination", value: $store.graphics.giBounce, range: 0...1.5)
                SliderRow(title: "Volumetric light", value: $store.graphics.lightShafts, range: 0...1.5)
                Toggle("Ultra shadow quality (2× samples)", isOn: $store.graphics.ultraShadows)
            }
            Section("World") {
                SliderRow(title: "Cloud shadows", value: $store.graphics.cloudShadows, range: 0...1)
                SliderRow(title: "Wind in foliage", value: $store.graphics.windSway, range: 0...1.5)
                SliderRow(title: "Water reflections", value: $store.graphics.waterReflections, range: 0...1)
                SliderRow(title: "Particles (embers, motes)", value: $store.graphics.particles, range: 0...1.5)
            }
            Section("Lens") {
                SliderRow(title: "Depth of field", value: $store.graphics.depthOfField, range: 0...1)
                SliderRow(title: "Anamorphic flares", value: $store.graphics.anamorphicFlare, range: 0...1)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Post

struct PostTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Section("Bloom") {
                Toggle("HDR bloom", isOn: $store.graphics.bloom)
                SliderRow(title: "Intensity", value: $store.graphics.bloomIntensity, range: 0...1.5)
                SliderRow(title: "Threshold", value: $store.graphics.bloomThreshold, range: 0...2)
            }
            Section("Tone & colour") {
                Picker("Tonemapper", selection: $store.graphics.tonemapper) {
                    ForEach(Tonemapper.allCases) { Text($0.label).tag($0) }
                }
                SliderRow(title: "Exposure", value: $store.graphics.exposure, range: -2...2, format: "%+.2f EV")
                SliderRow(title: "Contrast", value: $store.graphics.contrast, range: 0.7...1.5)
                SliderRow(title: "Saturation", value: $store.graphics.saturation, range: 0...2)
                SliderRow(title: "Temperature", value: $store.graphics.temperature, range: -1...1)
            }
            Section("Lens") {
                SliderRow(title: "Vignette", value: $store.graphics.vignette, range: 0...1)
                SliderRow(title: "Film grain", value: $store.graphics.filmGrain, range: 0...0.2, format: "%.3f")
                SliderRow(title: "Chromatic aberration", value: $store.graphics.chromaticAberration, range: 0...1)
                SliderRow(title: "Sharpen", value: $store.graphics.sharpen, range: 0...1)
            }
            Section("CRT") {
                Toggle("CRT simulation", isOn: $store.graphics.crt)
                SliderRow(title: "Scanlines & mask", value: $store.graphics.scanlines, range: 0...1)
                SliderRow(title: "Curvature", value: $store.graphics.crtCurvature, range: 0...0.3)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controls

final class CaptureState: ObservableObject {
    @Published var capturing: String?
    var monitor: Any?
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        capturing = nil
    }
}

struct ControlsTab: View {
    @ObservedObject var store: SettingsStore
    let input: InputManager
    @StateObject private var cap = CaptureState()

    var body: some View {
        Form {
            Section {
                ForEach(NESButton.allCases) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(b.label).font(.headline)
                        HStack {
                            Image(systemName: "keyboard").foregroundStyle(.secondary).frame(width: 22)
                            ForEach(store.input.keyCodes(b), id: \.self) { code in
                                chip(InputManager.keyName(code)) { removeKey(code, from: b) }
                            }
                            Spacer()
                            captureButton(id: "key:\(b.rawValue)", title: "Add key") { startKeyCapture(b) }
                        }
                        HStack {
                            Image(systemName: "gamecontroller").foregroundStyle(.secondary).frame(width: 22)
                            ForEach(store.input.padElements(b)) { el in
                                chip(el.label) { removePad(el, from: b) }
                            }
                            Spacer()
                            captureButton(id: "pad:\(b.rawValue)", title: "Add button") { startPadCapture(b) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("NES controller")
            } footer: {
                Text("Click a binding to remove it. Esc cancels capture. Controllers: \(input.connectedControllers.isEmpty ? "none connected" : input.connectedControllers.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Analog stick & fast forward") {
                SliderRow(title: "Stick dead zone", value: $store.input.stickDeadzone, range: 0.1...0.9)
                SliderRow(title: "Fast forward speed", value: $store.input.fastForwardSpeed, range: 1.5...8, format: "%.1f×")
                HStack {
                    Text("Fast forward (hold)")
                    Spacer()
                    Text("\(InputManager.keyName(store.input.fastForwardKey)) / \(store.input.fastForwardPad.label)").foregroundStyle(.secondary)
                }
            }
            Section("Hotkeys") {
                Group {
                    hotkey("F1 (hold)", "Compare with original graphics")
                    hotkey("F2", "Cycle graphics presets")
                    hotkey("F3", "Performance stats")
                    hotkey("F5 / F8", "Quick save / quick load")
                    hotkey("⌥1 … ⌥9", "Select save-state slot")
                    hotkey("⌘1 … ⌘6", "Apply preset")
                    hotkey("⌃⌘F", "Full screen")
                    hotkey("⌘P / ⌘R", "Pause / reset")
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { cap.stop(); input.padCapture = nil }
    }

    private func hotkey(_ k: String, _ d: String) -> some View {
        HStack { Text(k).monospaced().frame(width: 110, alignment: .leading); Text(d).foregroundStyle(.secondary) }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "xmark.circle.fill").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func captureButton(id: String, title: String, action: @escaping () -> Void) -> some View {
        Button(cap.capturing == id ? "Press…" : title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(cap.capturing == id ? .orange : .accentColor)
    }

    private func startKeyCapture(_ b: NESButton) {
        cap.stop()
        input.padCapture = nil
        cap.capturing = "key:\(b.rawValue)"
        let store = self.store, cap = self.cap
        cap.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            if e.type == .flagsChanged {
                // only accept modifier presses (not releases)
                let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if f.isEmpty { return nil }
            }
            if e.keyCode != 53 {
                var list = store.input.keys[b.rawValue] ?? []
                if !list.contains(e.keyCode) { list.append(e.keyCode) }
                store.input.keys[b.rawValue] = list
            }
            cap.stop()
            return nil
        }
    }

    private func startPadCapture(_ b: NESButton) {
        cap.stop()
        cap.capturing = "pad:\(b.rawValue)"
        let store = self.store, cap = self.cap
        // Esc cancels
        cap.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if e.keyCode == 53 { cap.stop(); return nil }
            return e
        }
        input.padCapture = { el in
            var list = store.input.pad[b.rawValue] ?? []
            if !list.contains(el) { list.append(el) }
            store.input.pad[b.rawValue] = list
            cap.stop()
        }
    }

    private func removeKey(_ code: UInt16, from b: NESButton) {
        store.input.keys[b.rawValue] = (store.input.keys[b.rawValue] ?? []).filter { $0 != code }
    }

    private func removePad(_ el: PadElement, from b: NESButton) {
        store.input.pad[b.rawValue] = (store.input.pad[b.rawValue] ?? []).filter { $0 != el }
    }
}

// MARK: - System

struct SystemTab: View {
    @ObservedObject var store: SettingsStore
    let core: EmulatorCore

    var body: some View {
        Form {
            Section {
                Picker("Sound engine", selection: $store.system.audioMode) {
                    ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Music style", selection: $store.system.musicStyle) {
                    ForEach(MusicStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(store.system.audioMode != .remastered)
                SliderRow(title: "Volume", value: $store.system.volume, range: 0...1.2)
                SliderRow(title: "Reverb", value: $store.system.reverb, range: 0...1)
                    .disabled(store.system.audioMode == .original)
                SliderRow(title: "Stereo width", value: $store.system.stereoWidth, range: 0...2)
                    .disabled(store.system.audioMode == .original)
                SliderRow(title: "Bass boost", value: $store.system.bassBoost, range: 0...1)
                    .disabled(store.system.audioMode != .remastered)
                SliderRow(title: "Original chip blend", value: $store.system.chipBlend, range: 0...1)
                    .disabled(store.system.audioMode == .original)
            } header: {
                Text("Sound & music")
            } footer: {
                Text("Remastered 2026 re-plays the game's own music and sound data live on synthesized instruments (lead brass/synth, string ensemble, bass, percussion), with hall reverb and mastering. Switch engines at any time to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                Picker("Game speed", selection: $store.system.timing) {
                    ForEach(TimingMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Pause when in background", isOn: $store.system.pauseInBackground)
            }
            Section {
                Toggle("Run statically recompiled native code", isOn: $store.system.nativeCode)
                    .disabled(!core.recompMatches)
                LabeledContent("Generated code") {
                    Text(nes_recomp_available() != 0 ? String(format: "built for PRG CRC %08X", nes_recomp_rom_crc()) : "not generated")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Loaded ROM") {
                    Text(core.isLoaded ? String(format: "PRG CRC %08X — %@", core.romCRC, core.recompMatches ? "match" : "mismatch → interpreter") : "none")
                        .foregroundStyle(core.recompMatches ? Color.green : Color.orange)
                }
            } header: {
                Text("Recompiler")
            } footer: {
                Text("Turning native code off runs the reference 6502 interpreter instead (for comparison/debugging). Any address the interpreter has to run is logged; rebuild with ./build.sh to fold it into the native code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Button("Open save & state folder") { NSWorkspace.shared.open(EmulatorCore.supportDirectory) }
                Button("Reset all settings to defaults") {
                    store.graphics = GraphicsSettings()
                    store.input = InputSettings()
                    store.system = SystemSettings()
                }
            }
        }
        .formStyle(.grouped)
    }
}
