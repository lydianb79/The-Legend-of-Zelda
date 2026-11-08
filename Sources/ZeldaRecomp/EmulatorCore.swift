import Foundation
import QuartzCore
import NESCore

/// Everything the renderer needs from one emulated frame.
struct FrameData {
    var pixels = [UInt32](repeating: 0, count: 256 * 240)
    var ram = [UInt8](repeating: 0, count: 2048)
    var oam = [UInt8](repeating: 0, count: 256)
    var palette = [UInt8](repeating: 0, count: 32)
    var splitLine: Int = -1
    var number: UInt64 = 0
}

/// Owns the NES runtime and drives it on a dedicated high-priority thread.
final class EmulatorCore {
    private var nes: OpaquePointer?
    private let lock = NSLock()           // guards `nes`
    private let frameLock = NSLock()      // guards `published`
    private var published = FrameData()
    private var thread: Thread?
    private var stopFlag = false

    // shared state (written by main thread, read by emulation thread)
    private let inputLock = NSLock()
    private var _buttons: UInt8 = 0
    var buttons: UInt8 {
        get { inputLock.lock(); defer { inputLock.unlock() }; return _buttons }
        set { inputLock.lock(); _buttons = newValue; inputLock.unlock() }
    }
    @Atomic var paused = false
    @Atomic var fastForward = false
    @Atomic var fastForwardSpeed: Double = 3.0

    let audioRing: OpaquePointer
    var audioSampleRate: Double = 48000
    private(set) var romCRC: UInt32 = 0
    private(set) var romPath: URL?
    private(set) var recompMatches = false
    private(set) var stats = Stats()
    private var lastBatterySave = Data()
    private var lastBatteryCheck = CACurrentMediaTime()

    struct Stats {
        var emuFPS: Double = 0
        var nativeBlocks: UInt64 = 0
        var interpreted: UInt64 = 0
        var frameTimeMs: Double = 0
    }

    init() {
        audioRing = zr_ring_create(1 << 15)
    }

    deinit {
        stop()
        zr_ring_destroy(audioRing)
    }

    // MARK: loading

    enum LoadError: LocalizedError {
        case unreadable, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The ROM file could not be read."
            case .rejected(let s): return s
            }
        }
    }

    func load(romURL: URL, settings: SystemSettings) throws {
        guard let data = try? Data(contentsOf: romURL) else { throw LoadError.unreadable }
        var errPtr: UnsafePointer<CChar>? = nil
        let created: OpaquePointer? = data.withUnsafeBytes { raw in
            nes_create(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &errPtr)
        }
        guard let n = created else {
            throw LoadError.rejected(errPtr.map { String(cString: $0) } ?? "Unsupported ROM")
        }
        stop()
        lock.lock()
        if let old = nes { nes_destroy(old) }
        nes = n
        romPath = romURL
        romCRC = nes_rom_crc(n)
        recompMatches = nes_recomp_available() != 0 && nes_recomp_rom_crc() == romCRC
        nes_set_sample_rate(n, Int32(audioSampleRate))
        loadBattery(n)
        lock.unlock()
        apply(system: settings)
        start()
    }

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return nes != nil }

    func apply(system: SystemSettings) {
        withNES { n in
            nes_set_force_interpreter(n, (system.nativeCode && self.recompMatches) ? 0 : 1)
            let romRegion = self.headerRegion()
            nes_set_audio_mode(n, Int32(system.audioMode.rawValue), Int32(system.musicStyle.rawValue),
                               system.reverb, system.stereoWidth, system.chipBlend, system.bassBoost)
            switch system.timing {
            case .auto: nes_set_region(n, romRegion)
            case .pal50: nes_set_region(n, Int32(NES_REGION_PAL))
            case .ntsc60: nes_set_region(n, Int32(NES_REGION_NTSC))
            }
        }
    }

    private var cachedHeaderRegion: Int32?
    private func headerRegion() -> Int32 {
        if let r = cachedHeaderRegion { return r }
        var r = Int32(NES_REGION_NTSC)
        if let url = romPath, let d = try? Data(contentsOf: url), d.count >= 16 {
            let nes2 = (d[7] & 0x0C) == 0x08
            let pal = nes2 ? (d[12] & 3) == 1 : (d[9] & 1) == 1
            let name = url.lastPathComponent.lowercased()
            if pal || name.contains("(europe)") || name.contains("(e)") { r = Int32(NES_REGION_PAL) }
        }
        cachedHeaderRegion = r
        return r
    }

    var frameRate: Double {
        lock.lock(); defer { lock.unlock() }
        guard let n = nes else { return 60 }
        return nes_frame_rate(n)
    }

    /// Run `body` with exclusive access to the machine (blocks the emulation thread briefly).
    @discardableResult
    func withNES<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let n = nes else { return nil }
        return body(n)
    }

    // MARK: thread

    func start() {
        guard thread == nil else { return }
        stopFlag = false
        let t = Thread { [weak self] in self?.run() }
        t.name = "ZeldaRecomp.emulation"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 22
        thread = t
        t.start()
    }

    func stop() {
        guard let t = thread else { return }
        stopFlag = true
        while !t.isFinished { usleep(1000) }
        thread = nil
    }

    private func run() {
        var next = CACurrentMediaTime()
        var fpsCounter = 0
        var fpsStart = CACurrentMediaTime()
        var audioScratch = [Float](repeating: 0, count: 16384)
        while !stopFlag {
            if paused {
                usleep(8000)
                next = CACurrentMediaTime()
                continue
            }
            let t0 = CACurrentMediaTime()
            var rate: Double = 60
            lock.lock()
            guard let n = nes else { lock.unlock(); usleep(10000); continue }
            nes_set_buttons(n, 0, buttons)
            nes_run_frame(n)
            rate = nes_frame_rate(n)
            // audio with gentle dynamic rate control to keep latency ~3 frames
            let got = audioScratch.withUnsafeMutableBufferPointer { nes_read_audio(n, $0.baseAddress, 8192) }  // stereo frames
            let ff = fastForward
            if !ff {
                _ = audioScratch.withUnsafeBufferPointer { zr_ring_write(audioRing, $0.baseAddress, UInt32(got * 2)) }
            }
            let fill = Double(zr_ring_available(audioRing)) / 2
            let target = audioSampleRate / rate * 3.0
            let adj = max(-0.005, min(0.005, (target - fill) / target * 0.005))
            nes_set_sample_rate(n, Int32((audioSampleRate * (1.0 + adj)).rounded()))
            publish(n)
            maybeSaveBattery(n)
            lock.unlock()

            let t1 = CACurrentMediaTime()
            fpsCounter += 1
            if t1 - fpsStart >= 1.0 {
                stats.emuFPS = Double(fpsCounter) / (t1 - fpsStart)
                fpsCounter = 0; fpsStart = t1
            }
            stats.frameTimeMs = (t1 - t0) * 1000

            let speed = ff ? fastForwardSpeed : 1.0
            next += 1.0 / (rate * speed)
            let now = CACurrentMediaTime()
            if next > now {
                let wait = next - now
                if wait > 0.002 { usleep(useconds_t((wait - 0.0015) * 1_000_000)) }
                while CACurrentMediaTime() < next { /* short spin for precise pacing */ }
            } else if now - next > 0.1 {
                next = now   // fell behind (debugger, sleep): resync
            }
        }
    }

    private func publish(_ n: OpaquePointer) {
        frameLock.lock()
        published.pixels.withUnsafeMutableBufferPointer { dst in
            _ = memcpy(dst.baseAddress, nes_framebuffer(n), 256 * 240 * 4)
        }
        published.ram.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress, nes_cpu_ram(n), 2048) }
        published.oam.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress, nes_oam(n), 256) }
        published.palette.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress, nes_palette_ram(n), 32) }
        published.splitLine = Int(nes_split_line(n))
        published.number &+= 1
        stats.nativeBlocks = nes_stat_recomp_instructions(n)
        stats.interpreted = nes_stat_interp_instructions(n)
        frameLock.unlock()
    }

    /// Copies the latest frame into `into` if it is newer than `into.number`. Returns true if updated.
    func latestFrame(into: inout FrameData) -> Bool {
        frameLock.lock(); defer { frameLock.unlock() }
        if published.number == into.number { return false }
        into = published
        return true
    }

    // MARK: commands

    func reset(hard: Bool) {
        withNES { nes_reset($0, hard ? 1 : 0) }
        zr_ring_clear(audioRing)
    }

    // MARK: persistence

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ZeldaRecomp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var batteryURL: URL {
        EmulatorCore.supportDirectory.appendingPathComponent(String(format: "battery_%08X.sav", romCRC))
    }

    private func loadBattery(_ n: OpaquePointer) {
        guard nes_has_battery(n) != 0, let d = try? Data(contentsOf: batteryURL), d.count == nes_prg_ram_size() else { return }
        d.withUnsafeBytes { _ = memcpy(nes_prg_ram(n), $0.baseAddress, d.count) }
        lastBatterySave = d
    }

    private func batteryData(_ n: OpaquePointer) -> Data {
        Data(bytes: nes_prg_ram(n), count: nes_prg_ram_size())
    }

    private func maybeSaveBattery(_ n: OpaquePointer) {
        let now = CACurrentMediaTime()
        guard now - lastBatteryCheck > 5, nes_has_battery(n) != 0 else { return }
        lastBatteryCheck = now
        let d = batteryData(n)
        if d != lastBatterySave {
            try? d.write(to: batteryURL, options: .atomic)
            lastBatterySave = d
        }
    }

    func flushBattery() {
        withNES { n in
            guard nes_has_battery(n) != 0 else { return }
            let d = batteryData(n)
            try? d.write(to: batteryURL, options: .atomic)
            lastBatterySave = d
        }
    }

    func stateURL(slot: Int) -> URL {
        EmulatorCore.supportDirectory.appendingPathComponent(String(format: "state_%08X_%d.zrs", romCRC, slot))
    }

    @discardableResult
    func saveState(slot: Int) -> Bool {
        let d: Data? = withNES { n in
            var buf = Data(count: nes_state_size())
            buf.withUnsafeMutableBytes { nes_save_state(n, $0.baseAddress) }
            return buf
        }
        guard let data = d else { return false }
        return (try? data.write(to: stateURL(slot: slot), options: .atomic)) != nil
    }

    @discardableResult
    func loadState(slot: Int) -> Bool {
        guard let d = try? Data(contentsOf: stateURL(slot: slot)) else { return false }
        let ok: Bool? = withNES { n in
            d.withUnsafeBytes { nes_load_state(n, $0.baseAddress, d.count) != 0 }
        }
        zr_ring_clear(audioRing)
        return ok ?? false
    }

    /// Addresses the interpreter had to execute (feed to Tools/recompile.py --coverage).
    func coverageReport() -> String {
        withNES { n -> String in
            var buf = [CChar](repeating: 0, count: 1 << 20)
            let len = buf.withUnsafeMutableBufferPointer { nes_dump_misses(n, $0.baseAddress, $0.count) }
            return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } ?? ""
    }
}

/// Minimal lock-protected property wrapper for flags shared with the emulation thread.
@propertyWrapper
final class Atomic<T> {
    private var value: T
    private let lock = NSLock()
    init(wrappedValue: T) { value = wrappedValue }
    var wrappedValue: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
