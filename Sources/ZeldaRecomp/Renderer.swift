import MetalKit
import QuartzCore
import simd

/// Per-frame hints derived from the game state (Zelda-specific RAM knowledge lives here).
struct SceneHints {
    var hudLines: Float = 0
    var flatUI = false
    var indoor = false
    var overworld = false
    var floor0 = 255
    var floor1 = 255
    var spritePalEmissive = SIMD4<Float>(repeating: 0)
    var lights: [(SIMD4<Float>, SIMD4<Float>)] = []
}

enum ZeldaRAM {
    static let level = 0x10      // 0 = overworld, 1-9 = dungeons
    static let mode = 0x12       // game mode: 0 title, 1 file select, 5 play, 0x0B cave, 0x0E register...
    static let linkX = 0x70
    static let linkY = 0x84
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let core: EmulatorCore
    private let store: SettingsStore
    private let input: InputManager

    private var scalePSO: MTLRenderPipelineState!
    private var lightPSO: MTLRenderPipelineState!
    private var downPSO: MTLRenderPipelineState!
    private var upPSO: MTLRenderPipelineState!
    private var finalSDR: MTLRenderPipelineState!
    private var finalHDR: MTLRenderPipelineState!

    private let idxTex: MTLTexture
    private var albedoTex: MTLTexture?
    private var gbufTex: MTLTexture?
    private var hdrTex: MTLTexture?
    private var bloomTex: [MTLTexture] = []
    private var allocatedScale = 0

    private var frame = FrameData()
    private var hints = SceneHints()
    private var palette: [SIMD4<Float>] = []
    private var paletteChoice: PaletteChoice?
    private let start = CACurrentMediaTime()
    private var drawCount: UInt64 = 0
    private var lastStats = CACurrentMediaTime()
    private var drawFPS: Double = 0
    private var drawFrames = 0

    var compareOriginal = false
    static var lastError: String?
    var statsHandler: ((String) -> Void)?

    init?(view: MTKView, core: EmulatorCore, store: SettingsStore, input: InputManager) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        self.core = core; self.store = store; self.input = input
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: 256, height: 240, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = dev.hasUnifiedMemory ? .shared : .managed
        guard let t = dev.makeTexture(descriptor: d) else { return nil }
        idxTex = t
        super.init()
        do { try buildPipelines() } catch {
            Renderer.lastError = "\(error)"
            NSLog("ZeldaRecomp shader compile error: \(error)")
            return nil
        }
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let vs = lib.makeFunction(name: "vs_full")
        func pso(_ fs: String, _ formats: [MTLPixelFormat], additive: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vs
            d.fragmentFunction = lib.makeFunction(name: fs)
            for (i, f) in formats.enumerated() {
                d.colorAttachments[i].pixelFormat = f
                if additive {
                    d.colorAttachments[i].isBlendingEnabled = true
                    d.colorAttachments[i].rgbBlendOperation = .add
                    d.colorAttachments[i].alphaBlendOperation = .add
                    d.colorAttachments[i].sourceRGBBlendFactor = .one
                    d.colorAttachments[i].destinationRGBBlendFactor = .one
                    d.colorAttachments[i].sourceAlphaBlendFactor = .one
                    d.colorAttachments[i].destinationAlphaBlendFactor = .one
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        scalePSO = try pso("fs_scale", [.rgba16Float, .rgba8Unorm])
        lightPSO = try pso("fs_light", [.rgba16Float])
        downPSO = try pso("fs_bloom_down", [.rgba16Float])
        upPSO = try pso("fs_bloom_up", [.rgba16Float], additive: true)
        finalSDR = try pso("fs_final", [.bgra8Unorm_srgb])
        finalHDR = try pso("fs_final", [.rgba16Float])
    }

    private func allocate(scale: Int) {
        guard scale != allocatedScale else { return }
        allocatedScale = scale
        let w = 256 * scale, h = 240 * scale
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, mips: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: mips)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        albedoTex = tex(.rgba16Float, w, h, mips: true)
        gbufTex = tex(.rgba8Unorm, w, h, mips: true)
        hdrTex = tex(.rgba16Float, w, h, mips: true)
        bloomTex = []
        var bw = w / 2, bh = h / 2
        while bloomTex.count < 7 && bw >= 8 && bh >= 8 {
            if let t = tex(.rgba16Float, bw, bh, mips: false) { bloomTex.append(t) }
            bw /= 2; bh /= 2
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        input.poll()
        core.buttons = input.buttons()
        core.fastForward = input.fastForwardHeld
        core.fastForwardSpeed = Double(store.input.fastForwardSpeed)

        var g = compareOriginal ? GraphicsSettings.preset(.original) : store.graphics
        if compareOriginal { g.aspect = store.graphics.aspect; g.internalScale = store.graphics.internalScale }

        // output format (SDR sRGB or EDR extended linear)
        let screen = view.window?.screen
        let edrCapable = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.0
        let wantHDR = g.hdrOutput && edrCapable
        let fmt: MTLPixelFormat = wantHDR ? .rgba16Float : .bgra8Unorm_srgb
        if view.colorPixelFormat != fmt {
            view.colorPixelFormat = fmt
            if let layer = view.layer as? CAMetalLayer {
                layer.wantsExtendedDynamicRangeContent = wantHDR
                layer.colorspace = CGColorSpace(name: wantHDR ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
            }
        }
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = g.vsync

        if core.latestFrame(into: &frame) {
            frame.pixels.withUnsafeBytes { raw in
                idxTex.replace(region: MTLRegionMake2D(0, 0, 256, 240), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 256 * 4)
            }
            hints = analyze(frame)
        }
        if paletteChoice != g.palette {
            palette = NESPalette.linear(g.palette)
            paletteChoice = g.palette
        }
        let scale = max(1, min(8, g.internalScale))
        allocate(scale: scale)

        guard let albedo = albedoTex, let gbuf = gbufTex, let hdr = hdrTex, bloomTex.count >= 2,
              let cmd = queue.makeCommandBuffer() else { return }
        let time = Float(CACurrentMediaTime() - start)
        var U = makeUniforms(g, view: view, time: time, scale: scale, hdr: wantHDR, headroom: Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1))
        var lights = [SIMD4<Float>](repeating: .zero, count: 32)
        for (i, l) in hints.lights.prefix(16).enumerated() { lights[i * 2] = l.0; lights[i * 2 + 1] = l.1 }
        var info = NESPalette.materialInfo
        var pal = palette

        // 1. scale + G-buffer
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = albedo
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[1].texture = gbuf
        rp.colorAttachments[1].loadAction = .dontCare
        rp.colorAttachments[1].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: rp) {
            e.setRenderPipelineState(scalePSO)
            e.setFragmentTexture(idxTex, index: 0)
            e.setFragmentBytes(&pal, length: MemoryLayout<SIMD4<Float>>.stride * 64, index: 0)
            e.setFragmentBytes(&info, length: MemoryLayout<SIMD4<Float>>.stride * 64, index: 1)
            e.setFragmentBytes(&U, length: MemoryLayout<SIMD4<Float>>.stride * U.count, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        // 2. mip chains
        if let b = cmd.makeBlitCommandEncoder() {
            b.generateMipmaps(for: albedo)
            b.generateMipmaps(for: gbuf)
            b.endEncoding()
        }
        // 3. lighting
        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = hdr
        lp.colorAttachments[0].loadAction = .dontCare
        lp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: lp) {
            e.setRenderPipelineState(lightPSO)
            e.setFragmentTexture(albedo, index: 0)
            e.setFragmentTexture(gbuf, index: 1)
            e.setFragmentBytes(&U, length: MemoryLayout<SIMD4<Float>>.stride * U.count, index: 0)
            e.setFragmentBytes(&lights, length: MemoryLayout<SIMD4<Float>>.stride * lights.count, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if let b = cmd.makeBlitCommandEncoder() { b.generateMipmaps(for: hdr); b.endEncoding() }
        // 4. bloom (also used as the blurred ambient fill)
        var src: MTLTexture = hdr
        for (i, dst) in bloomTex.enumerated() {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = dst
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            if let e = cmd.makeRenderCommandEncoder(descriptor: p) {
                e.setRenderPipelineState(downPSO)
                e.setFragmentTexture(src, index: 0)
                var prm = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), i == 0 ? g.bloomThreshold : -1, 0.35)
                e.setFragmentBytes(&prm, length: 16, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
            src = dst
        }
        // keep the smallest level un-accumulated for the ambient fill, then upsample additively
        if bloomTex.count >= 3 {
            for i in stride(from: bloomTex.count - 2, through: 0, by: -1) {
                let p = MTLRenderPassDescriptor()
                p.colorAttachments[0].texture = bloomTex[i]
                p.colorAttachments[0].loadAction = .load
                p.colorAttachments[0].storeAction = .store
                if let e = cmd.makeRenderCommandEncoder(descriptor: p) {
                    e.setRenderPipelineState(upPSO)
                    e.setFragmentTexture(bloomTex[i + 1], index: 0)
                    var prm = SIMD4<Float>(1 / Float(bloomTex[i + 1].width), 1 / Float(bloomTex[i + 1].height), 1.0, 0)
                    e.setFragmentBytes(&prm, length: 16, index: 0)
                    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    e.endEncoding()
                }
            }
        }
        // 5. final
        if let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable {
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let e = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                e.setRenderPipelineState(wantHDR ? finalHDR : finalSDR)
                e.setFragmentTexture(hdr, index: 0)
                e.setFragmentTexture(bloomTex[0], index: 1)
                e.setFragmentTexture(bloomTex[bloomTex.count - 1], index: 2)
                e.setFragmentTexture(bloomTex[min(1, bloomTex.count - 1)], index: 3)
                e.setFragmentBytes(&U, length: MemoryLayout<SIMD4<Float>>.stride * U.count, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
            cmd.present(drawable)
        }
        cmd.commit()
        drawCount += 1
        updateStats(g)
    }

    private func updateStats(_ g: GraphicsSettings) {
        drawFrames += 1
        let now = CACurrentMediaTime()
        guard now - lastStats >= 0.5 else { return }
        drawFPS = Double(drawFrames) / (now - lastStats)
        drawFrames = 0; lastStats = now
        guard g.showStats, let h = statsHandler else { statsHandler?(""); return }
        let s = core.stats
        let total = Double(s.nativeBlocks) + Double(s.interpreted)
        let native = total > 0 ? 100.0 * Double(s.nativeBlocks) / total : 0
        let mode = core.recompMatches ? (store.system.nativeCode ? "native recomp" : "interpreter (forced)") : "interpreter (ROM ≠ recomp)"
        h(String(format: "Display %.0f fps · Game %.1f fps (%.2f ms/frame) · %@ · %.1f%% native dispatch · %dx internal%@",
                 drawFPS, s.emuFPS, s.frameTimeMs, mode, native, g.internalScale, hints.indoor ? " · indoor" : ""))
    }

    // MARK: uniforms

    private func makeUniforms(_ g: GraphicsSettings, view: MTKView, time: Float, scale: Int, hdr: Bool, headroom: Float) -> [SIMD4<Float>] {
        var v = [SIMD4<Float>](repeating: .zero, count: 24)
        let W = Float(view.drawableSize.width), H = Float(view.drawableSize.height)
        v[0] = SIMD4(256, 240, Float(256 * scale), Float(240 * scale))
        v[1] = SIMD4(time, Float(drawCount % 100_000), hints.hudLines, Float(g.upscaler.rawValue))

        let a = g.sunAngle * .pi / 180, el = g.sunElevation * .pi / 180
        let L = SIMD3<Float>(cosf(el) * cosf(a), cosf(el) * sinf(a), sinf(el))
        var sunI = g.sunIntensity, amb = g.ambient
        var sunCol = SIMD3<Float>(1.0, 0.95, 0.86)
        var sky = SIMD3<Float>(0.86, 0.94, 1.12), ground = SIMD3<Float>(1.12, 1.0, 0.86)
        if hints.indoor {
            sunI *= 0.3
            amb *= max(0.08, 1 - g.indoorDarkness)
            sunCol = SIMD3(0.9, 0.92, 1.0)
            sky = SIMD3(0.92, 0.95, 1.05); ground = SIMD3(1.05, 0.98, 0.92)
        }
        if hints.flatUI { sunI = 0; amb = 1 }
        v[2] = SIMD4(L.x, L.y, L.z, g.lighting ? sunI : 0)
        v[3] = SIMD4(sunCol.x, sunCol.y, sunCol.z, amb)
        v[4] = SIMD4(sky.x, sky.y, sky.z, g.reliefDepth)
        v[5] = SIMD4(ground.x, ground.y, ground.z, g.spriteVolume)
        v[6] = SIMD4(g.ambientOcclusion, g.shadowStrength, g.shadowSoftness, 3.0)
        v[7] = SIMD4(g.lighting ? 1 : 0, (g.lighting && g.shadows) ? 1 : 0, (g.water && hints.overworld) ? 1 : 0, hints.indoor ? 1 : 0)
        let nLights = (g.lighting && g.dynamicLights) ? min(16, hints.lights.count) : 0
        v[8] = SIMD4(g.lightIntensity, Float(nLights), g.emissiveStrength, log2f(Float(scale)))
        let expo = powf(2, g.exposure) * (hdr ? 0.85 : 1.0)
        v[9] = SIMD4(g.bloom ? g.bloomIntensity : 0, g.bloomThreshold, expo, Float(g.tonemapper.rawValue))
        v[10] = SIMD4(g.contrast, g.saturation, g.temperature, g.vignette)
        v[11] = SIMD4(g.filmGrain, g.chromaticAberration, g.sharpen, g.crt ? 1 : 0)
        v[12] = SIMD4(g.scanlines, hdr ? 1 : 0, max(1, headroom), g.ambientFill ? 1 : 0)
        v[13] = contentRect(W, H, g.aspect)
        v[14] = SIMD4(W, H, 1 / max(W, 1), 1 / max(H, 1))
        v[15] = (g.lighting && g.dynamicLights) ? hints.spritePalEmissive : (g.emissiveStrength > 0 ? hints.spritePalEmissive * 0.4 : .zero)
        v[16] = SIMD4(hints.flatUI ? 1 : 0, g.objectHeight, 0, Float(hints.floor0))
        v[17] = SIMD4(Float(hints.floor1), g.crtCurvature, 0, 0)
        let ultraOK = g.lighting
        v[18] = SIMD4(ultraOK ? g.giBounce : 0, ultraOK ? g.cloudShadows : 0, ultraOK ? g.windSway : 0, ultraOK ? g.lightShafts : 0)
        v[19] = SIMD4(ultraOK ? g.particles : 0, g.depthOfField, ultraOK ? g.waterReflections : 0, g.anamorphicFlare)
        v[20] = SIMD4(g.ultraShadows ? 14 : 7, hints.overworld ? 1 : 0, 0, 0)
        return v
    }

    private func contentRect(_ W: Float, _ H: Float, _ mode: AspectMode) -> SIMD4<Float> {
        var w: Float, h: Float
        switch mode {
        case .stretch:
            return SIMD4(0, 0, W, H)
        case .integer:
            let k = floorf(min(W / 256, H / 240))
            if k >= 1 { w = 256 * k; h = 240 * k } else { let s = min(W / 256, H / 240); w = 256 * s; h = 240 * s }
        case .square, .pixelAspect:
            let ar: Float = mode == .square ? 256.0 / 240.0 : (256.0 * 8.0 / 7.0) / 240.0
            if W / H > ar { h = H; w = H * ar } else { w = W; h = W / ar }
        }
        return SIMD4((W - w) * 0.5, (H - h) * 0.5, w, h)
    }

    // MARK: scene analysis

    private func analyze(_ f: FrameData) -> SceneHints {
        var h = SceneHints()
        let mode = Int(f.ram[ZeldaRAM.mode]), level = Int(f.ram[ZeldaRAM.level])
        let menu = mode == 1 || mode == 0x0E || mode == 0x0F
        let gameplay = !menu && mode >= 2
        h.flatUI = menu
        h.hudLines = gameplay ? 64 : 0
        if gameplay, f.splitLine > 0 { h.hudLines = max(h.hudLines, Float(f.splitLine + 1)) }
        h.indoor = gameplay && (level != 0 || mode == 0x0B)
        h.overworld = gameplay && level == 0 && mode != 0x0B

        // ground colour: most common background colour in the middle of the playfield
        var hist = [Int](repeating: 0, count: 64)
        let y0 = gameplay ? 96 : 40, y1 = 224
        var total = 0
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: 32, to: 224, by: 3) {
                hist[Int((f.pixels[y * 256 + x] >> 8) & 0x3F)] += 1
                total += 1
            }
        }
        let sorted = hist.enumerated().sorted { $0.element > $1.element }
        h.floor0 = sorted[0].element > 0 ? sorted[0].offset : 255
        if level != 0 && gameplay && total > 0 && Double(sorted[1].element) / Double(total) > 0.18 { h.floor1 = sorted[1].offset }

        // flame palettes: red + orange/white, no foliage greens
        let greens: Set<UInt8> = [0x09, 0x0A, 0x19, 0x1A, 0x29, 0x2A, 0x2B, 0x1B]
        var fire = [Bool](repeating: false, count: 4)
        for p in 0..<4 {
            let cols = (1...3).map { f.palette[0x10 + p * 4 + $0] & 0x3F }
            let hasRed = cols.contains(0x16) || cols.contains(0x06)
            let hasHot = cols.contains(0x27) || cols.contains(0x37) || cols.contains(0x30) || cols.contains(0x28)
            fire[p] = hasRed && hasHot && !cols.contains(where: { greens.contains($0) })
            h.spritePalEmissive[p] = (fire[p] && h.indoor) ? 1 : 0
        }

        guard gameplay else { return h }
        let t = Float(CACurrentMediaTime() - start)
        if h.indoor {
            var clusters: [(SIMD2<Float>, Int)] = []
            for i in 0..<64 {
                let y = Int(f.oam[i * 4]), x = Int(f.oam[i * 4 + 3]), attr = Int(f.oam[i * 4 + 2])
                guard y < 232, fire[attr & 3] else { continue }
                let pos = SIMD2<Float>(Float(x) + 4, Float(y) + 9)
                if let k = clusters.firstIndex(where: { simd_distance($0.0, pos) < 14 }) {
                    let c = clusters[k]
                    clusters[k] = ((c.0 * Float(c.1) + pos) / Float(c.1 + 1), c.1 + 1)
                } else if clusters.count < 12 {
                    clusters.append((pos, 1))
                }
            }
            for (i, c) in clusters.enumerated() {
                let fi = Float(i)
                let flicker = 1 + 0.10 * sinf(t * 13 + fi * 2.1) + 0.06 * sinf(t * 29.7 + fi * 5.3) + 0.04 * sinf(t * 7.3 + fi)
                h.lights.append((SIMD4(c.0.x, c.0.y, 14, 84), SIMD4(1.0, 0.56, 0.22, 1.7 * flicker)))
            }
            // Link carries a soft lantern glow in caves and dungeons
            let lx = Float(f.ram[ZeldaRAM.linkX]) + 8, ly = Float(f.ram[ZeldaRAM.linkY]) + 8
            if ly > 64 && ly < 240 {
                h.lights.append((SIMD4(lx, ly, 22, 72), SIMD4(1.0, 0.86, 0.66, 0.65)))
            }
        }
        return h
    }
}
