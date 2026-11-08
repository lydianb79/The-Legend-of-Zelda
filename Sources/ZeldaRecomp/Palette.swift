import simd

/// NES master palettes (64 entries) and per-colour material hints for the renderer.
enum NESPalette {
    static let classic: [UInt32] = [
        0x666666, 0x002A88, 0x1412A7, 0x3B00A4, 0x5C007E, 0x6E0040, 0x6C0600, 0x561D00,
        0x333500, 0x0B4800, 0x005200, 0x004F08, 0x00404D, 0x000000, 0x000000, 0x000000,
        0xADADAD, 0x155FD9, 0x4240FF, 0x7527FE, 0xA01ACC, 0xB71E7B, 0xB53120, 0x994E00,
        0x6B6D00, 0x388700, 0x0C9300, 0x008F32, 0x007C8D, 0x000000, 0x000000, 0x000000,
        0xFFFEFF, 0x64B0FF, 0x9290FF, 0xC676FF, 0xF36AFF, 0xFE6ECC, 0xFE8170, 0xEA9E22,
        0xBCBE00, 0x88D800, 0x5CE430, 0x45E082, 0x48CDDE, 0x4F4F4F, 0x000000, 0x000000,
        0xFFFEFF, 0xC0DFFF, 0xD3D2FF, 0xE8C8FF, 0xFBC2FF, 0xFEC4EA, 0xFECCC5, 0xF7D8A5,
        0xE4E594, 0xCFEF96, 0xBDF4AB, 0xB3F3CC, 0xB5EBF2, 0xB8B8B8, 0x000000, 0x000000,
    ]

    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Linear-light RGB palette for the chosen variant.
    static func linear(_ choice: PaletteChoice) -> [SIMD4<Float>] {
        classic.map { rgb in
            var c = SIMD3<Float>(Float((rgb >> 16) & 255), Float((rgb >> 8) & 255), Float(rgb & 255)) / 255
            switch choice {
            case .classic: break
            case .vivid:
                // richer saturation & a touch more depth, done in gamma space like a TV "colour" knob
                let l = simd_dot(c, SIMD3<Float>(0.299, 0.587, 0.114))
                c = simd_clamp(SIMD3<Float>(repeating: l) + (c - l) * 1.28, .zero, .one)
                c = simd_clamp((c - 0.5) * 1.06 + 0.5, .zero, .one)
            case .soft:
                let l = simd_dot(c, SIMD3<Float>(0.299, 0.587, 0.114))
                c = SIMD3<Float>(repeating: l) + (c - l) * 0.82
                c = c * 0.92 + 0.05
            }
            return SIMD4<Float>(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z), 1)
        }
    }

    /// Per colour index: x = sprite emissive weight (flames), y = water colour, z = background emissive, w = foliage.
    static let materialInfo: [SIMD4<Float>] = {
        var info = [SIMD4<Float>](repeating: .zero, count: 64)
        let fire: [Int: Float] = [0x06: 1.0, 0x16: 1.0, 0x26: 0.9, 0x36: 0.5, 0x27: 0.8, 0x37: 0.6, 0x17: 0.4,
                                  0x28: 0.8, 0x38: 0.6, 0x30: 0.7, 0x20: 0.7]
        for (k, v) in fire { info[k].x = v }
        for k in [0x01, 0x02, 0x11, 0x12, 0x21, 0x22, 0x31, 0x32, 0x1C, 0x2C] { info[k].y = 1 }
        for k in [0x09, 0x0A, 0x0B, 0x19, 0x1A, 0x1B, 0x29, 0x2A] { info[k].w = 1 }
        return info
    }()
}
