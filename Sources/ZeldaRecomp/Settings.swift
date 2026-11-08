import Foundation
import Combine

// MARK: - Graphics

enum Upscaler: Int, Codable, CaseIterable, Identifiable {
    case nearest, smoothEdges, soft
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .nearest: return "Pixel Perfect"
        case .smoothEdges: return "Smooth Edges (AA)"
        case .soft: return "Soft"
        }
    }
}

enum Tonemapper: Int, Codable, CaseIterable, Identifiable {
    case none, neutral, agx, aces
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: return "Off (clamp)"
        case .neutral: return "Neutral"
        case .agx: return "AgX Filmic"
        case .aces: return "ACES"
        }
    }
}

enum AspectMode: Int, Codable, CaseIterable, Identifiable {
    case pixelAspect, square, integer, stretch
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .pixelAspect: return "Original TV (8:7 pixels)"
        case .square: return "Square pixels"
        case .integer: return "Integer scale"
        case .stretch: return "Stretch to window"
        }
    }
}

enum PaletteChoice: Int, Codable, CaseIterable, Identifiable {
    case classic, vivid, soft
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classic 2C02"
        case .vivid: return "Vivid"
        case .soft: return "Soft Pastel"
        }
    }
}

enum GraphicsPreset: String, CaseIterable, Identifiable {
    case original = "Original", crisp = "Crisp HD", remastered = "Remastered 2026", ultra = "Ultra 2026", cinematic = "Cinematic", crt = "Retro CRT"
    var id: String { rawValue }
}

struct GraphicsSettings: Codable, Equatable {
    // Image
    var upscaler: Upscaler = .smoothEdges
    var internalScale: Int = 4
    var aspect: AspectMode = .pixelAspect
    var palette: PaletteChoice = .classic
    var ambientFill: Bool = true
    var hdrOutput: Bool = true
    // Lighting
    var lighting: Bool = true
    var sunAngle: Float = 225          // degrees, screen space (0 = right, 90 = down)
    var sunElevation: Float = 42       // degrees
    var sunIntensity: Float = 0.75
    var ambient: Float = 0.48
    var reliefDepth: Float = 1.0
    var objectHeight: Float = 7.0      // NES pixels: how "tall" trees, rocks and walls are
    var spriteVolume: Float = 0.7
    var ambientOcclusion: Float = 0.55
    var shadows: Bool = true
    var shadowStrength: Float = 0.42
    var shadowSoftness: Float = 1.0
    var dynamicLights: Bool = true
    var lightIntensity: Float = 1.0
    var indoorDarkness: Float = 0.55
    var emissiveStrength: Float = 2.2
    var water: Bool = true
    // Post
    var bloom: Bool = true
    var bloomIntensity: Float = 0.35
    var bloomThreshold: Float = 0.8
    var exposure: Float = 0.05         // EV
    var tonemapper: Tonemapper = .neutral
    var contrast: Float = 1.06
    var saturation: Float = 1.15
    var temperature: Float = 0.04
    var vignette: Float = 0.22
    var filmGrain: Float = 0.03
    var chromaticAberration: Float = 0.1
    var sharpen: Float = 0.2
    var crt: Bool = false
    var scanlines: Float = 0.4
    var crtCurvature: Float = 0.08
    // Ultra 2026 effects (0 = off)
    var giBounce: Float = 0            // indirect bounce light / colour bleeding
    var cloudShadows: Float = 0        // drifting cloud shadows on the overworld
    var windSway: Float = 0            // wind moving through foliage
    var lightShafts: Float = 0         // volumetric sun shafts and light haze around flames
    var particles: Float = 0           // embers, dust motes and fireflies
    var waterReflections: Float = 0    // screen-space reflections on water
    var depthOfField: Float = 0        // tilt-shift style focus falloff at the screen edges
    var anamorphicFlare: Float = 0     // horizontal lens streaks on bright lights
    var ultraShadows: Bool = false     // twice the shadow ray samples
    // Display
    var vsync: Bool = true
    var showStats: Bool = false

    static func preset(_ p: GraphicsPreset) -> GraphicsSettings {
        var g = GraphicsSettings()
        switch p {
        case .remastered:
            break
        case .ultra:
            g.internalScale = 6
            g.giBounce = 0.55; g.cloudShadows = 0.6; g.windSway = 0.5; g.lightShafts = 0.55; g.particles = 0.6
            g.waterReflections = 0.6; g.depthOfField = 0.3; g.anamorphicFlare = 0.35; g.ultraShadows = true
            g.reliefDepth = 1.2; g.shadowStrength = 0.5; g.shadowSoftness = 1.2; g.ambientOcclusion = 0.65
            g.bloomIntensity = 0.42; g.emissiveStrength = 2.6; g.indoorDarkness = 0.62; g.lightIntensity = 1.2
            g.saturation = 1.18; g.contrast = 1.08; g.vignette = 0.26; g.filmGrain = 0.035; g.sharpen = 0.25
        case .original:
            g.upscaler = .nearest; g.lighting = false; g.shadows = false; g.dynamicLights = false; g.water = false
            g.bloom = false; g.tonemapper = .none; g.exposure = 0; g.contrast = 1; g.saturation = 1; g.temperature = 0
            g.vignette = 0; g.filmGrain = 0; g.chromaticAberration = 0; g.sharpen = 0; g.crt = false; g.ambientFill = false
            g.emissiveStrength = 0
        case .crisp:
            g.lighting = false; g.shadows = false; g.dynamicLights = false; g.water = true
            g.bloom = true; g.bloomIntensity = 0.15; g.tonemapper = .none; g.exposure = 0; g.contrast = 1.03; g.saturation = 1.08
            g.temperature = 0; g.vignette = 0.08; g.filmGrain = 0; g.chromaticAberration = 0; g.sharpen = 0.3
            g.emissiveStrength = 0.8
        case .cinematic:
            g.tonemapper = .agx; g.exposure = 0.35; g.bloomIntensity = 0.55; g.bloomThreshold = 0.7
            g.vignette = 0.4; g.filmGrain = 0.06; g.chromaticAberration = 0.25; g.temperature = 0.1
            g.contrast = 1.12; g.saturation = 1.2; g.indoorDarkness = 0.72; g.shadowStrength = 0.55
            g.sunIntensity = 0.85; g.ambient = 0.42; g.emissiveStrength = 3.0
        case .crt:
            g.upscaler = .nearest; g.lighting = false; g.shadows = false; g.dynamicLights = false; g.water = false
            g.bloom = true; g.bloomIntensity = 0.3; g.bloomThreshold = 0.6; g.tonemapper = .none; g.exposure = 0.25
            g.contrast = 1.05; g.saturation = 1.1; g.temperature = 0; g.vignette = 0.3; g.filmGrain = 0.02
            g.chromaticAberration = 0.2; g.sharpen = 0; g.crt = true; g.ambientFill = false; g.emissiveStrength = 0
        }
        return g
    }
}

// MARK: - Input

enum NESButton: String, CaseIterable, Codable, Identifiable {
    case up, down, left, right, a, b, select, start
    var id: String { rawValue }
    var mask: UInt8 {
        switch self {
        case .a: return 0x01
        case .b: return 0x02
        case .select: return 0x04
        case .start: return 0x08
        case .up: return 0x10
        case .down: return 0x20
        case .left: return 0x40
        case .right: return 0x80
        }
    }
    var label: String {
        switch self {
        case .up: return "D-Pad Up"
        case .down: return "D-Pad Down"
        case .left: return "D-Pad Left"
        case .right: return "D-Pad Right"
        case .a: return "A (Sword)"
        case .b: return "B (Item)"
        case .select: return "Select"
        case .start: return "Start (Menu)"
        }
    }
}

enum PadElement: String, CaseIterable, Codable, Identifiable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case stickUp, stickDown, stickLeft, stickRight
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case menu, options
    case none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .stickUp: return "Left Stick ↑"
        case .stickDown: return "Left Stick ↓"
        case .stickLeft: return "Left Stick ←"
        case .stickRight: return "Left Stick →"
        case .buttonA: return "A / Cross (south)"
        case .buttonB: return "B / Circle (east)"
        case .buttonX: return "X / Square (west)"
        case .buttonY: return "Y / Triangle (north)"
        case .leftShoulder: return "L1 / LB"
        case .rightShoulder: return "R1 / RB"
        case .leftTrigger: return "L2 / LT"
        case .rightTrigger: return "R2 / RT"
        case .menu: return "Menu / Options"
        case .options: return "View / Share"
        case .none: return "—"
        }
    }
}

struct InputSettings: Codable, Equatable {
    /// NESButton.rawValue -> list of macOS virtual key codes
    var keys: [String: [UInt16]] = [
        NESButton.up.rawValue: [126, 13],      // ↑, W
        NESButton.down.rawValue: [125, 1],     // ↓, S
        NESButton.left.rawValue: [123, 0],     // ←, A
        NESButton.right.rawValue: [124, 2],    // →, D
        NESButton.a.rawValue: [7, 40],         // X, K
        NESButton.b.rawValue: [6, 38],         // Z, J
        NESButton.select.rawValue: [60, 48],   // Right Shift, Tab
        NESButton.start.rawValue: [36],        // Return
    ]
    /// NESButton.rawValue -> list of gamepad elements
    var pad: [String: [PadElement]] = [
        NESButton.up.rawValue: [.dpadUp, .stickUp],
        NESButton.down.rawValue: [.dpadDown, .stickDown],
        NESButton.left.rawValue: [.dpadLeft, .stickLeft],
        NESButton.right.rawValue: [.dpadRight, .stickRight],
        NESButton.a.rawValue: [.buttonA],
        NESButton.b.rawValue: [.buttonX],
        NESButton.select.rawValue: [.options],
        NESButton.start.rawValue: [.menu],
    ]
    var stickDeadzone: Float = 0.4
    var fastForwardKey: UInt16 = 50      // ` (grave)
    var fastForwardPad: PadElement = .rightTrigger
    var fastForwardSpeed: Float = 3.0

    func keyCodes(_ b: NESButton) -> [UInt16] { keys[b.rawValue] ?? [] }
    func padElements(_ b: NESButton) -> [PadElement] { pad[b.rawValue] ?? [] }
}

// MARK: - System

enum TimingMode: Int, Codable, CaseIterable, Identifiable {
    case auto, pal50, ntsc60
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .auto: return "Match ROM (PAL 50 Hz for this version)"
        case .pal50: return "PAL 50 Hz (original EU speed)"
        case .ntsc60: return "NTSC 60 Hz (smoother, 20% faster)"
        }
    }
}

enum AudioMode: Int, Codable, CaseIterable, Identifiable {
    case original, enhancedChip, remastered
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: return "Original (2A03 mono)"
        case .enhancedChip: return "Enhanced Chip (stereo, band-limited, reverb)"
        case .remastered: return "Remastered 2026 (modern instruments)"
        }
    }
}

enum MusicStyle: Int, Codable, CaseIterable, Identifiable {
    case orchestral, synthwave
    var id: Int { rawValue }
    var label: String { self == .orchestral ? "Orchestral (brass, strings, warm bass)" : "Synthwave (supersaw, plucks, analog bass)" }
}

struct SystemSettings: Codable, Equatable {
    var volume: Float = 0.8
    var audioMode: AudioMode = .remastered
    var musicStyle: MusicStyle = .orchestral
    var reverb: Float = 0.35
    var stereoWidth: Float = 1.15
    var chipBlend: Float = 0.0
    var bassBoost: Float = 0.25
    var timing: TimingMode = .auto
    var pauseInBackground: Bool = true
    var nativeCode: Bool = true          // false = force the reference interpreter (debugging)
}

// MARK: - Store

final class SettingsStore: ObservableObject {
    @Published var graphics: GraphicsSettings { didSet { save("graphics", graphics) } }
    @Published var input: InputSettings { didSet { save("input", input) } }
    @Published var system: SystemSettings { didSet { save("system", system) } }

    init() {
        graphics = SettingsStore.load("graphics", defaults: GraphicsSettings())
        input = SettingsStore.load("input", defaults: InputSettings())
        system = SettingsStore.load("system", defaults: SystemSettings())
    }

    func apply(preset: GraphicsPreset) {
        var g = GraphicsSettings.preset(preset)
        // keep display preferences (Ultra raises the internal resolution unless the user already runs higher)
        g.internalScale = preset == .ultra ? max(6, graphics.internalScale) : graphics.internalScale
        g.aspect = graphics.aspect
        g.hdrOutput = graphics.hdrOutput
        g.vsync = graphics.vsync
        g.showStats = graphics.showStats
        g.palette = preset == .original ? .classic : graphics.palette
        graphics = g
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: "zr." + key) }
    }

    private static func load<T: Codable>(_ key: String, defaults: T) -> T {
        guard let d = UserDefaults.standard.data(forKey: "zr." + key) else { return defaults }
        if let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        // settings from an older version: overlay the saved keys on top of the current defaults
        guard let defData = try? JSONEncoder().encode(defaults),
              var base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return defaults }
        for (k, v) in saved where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return defaults }
        return (try? JSONDecoder().decode(T.self, from: merged)) ?? defaults
    }
}
