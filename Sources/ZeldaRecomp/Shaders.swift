// Metal shading language source, compiled at launch with MTLDevice.makeLibrary(source:).
//
// Pipeline (per frame):
//   1. fs_scale   NES layer data (256x240, palette indices + layer flags) -> internal-res albedo + G-buffer,
//                 using an edge-directed, anti-aliased pixel-art upscaler that works on exact palette indices.
//   2. mipmaps    albedo / G-buffer mip chains drive soft shadows, relief normals and AO.
//   3. fs_light   relief normals, sun + hemispheric ambient, cast shadows from raised scenery, sprite drop
//                 shadows, contact AO, dynamic point lights (flames, Link's lantern), emissives, animated water.
//   4. bloom      HDR threshold + 13-tap downsample chain + tent upsample.
//   5. fs_final   aspect fit, ambient fill, chromatic aberration, sharpening, tonemapping (Neutral/AgX/ACES or
//                 EDR highlight roll-off), grading, vignette, film grain, optional CRT.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4 v[24]; };
struct Light { float4 posRad; float4 color; };   // posRad: x,y (NES px), z height, w radius; color: rgb, intensity

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs_full(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

constexpr sampler linClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);

static inline float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

static inline float fbm(float2 p) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) { sum += amp * vnoise(p); p = p * 2.03 + float2(17.1, 9.2); amp *= 0.5; }
    return sum;
}

// ---------------------------------------------------------------------------------------------
// 1. Upscale + G-buffer
// ---------------------------------------------------------------------------------------------
struct ScaleOut { half4 albedo [[color(0)]]; half4 gbuf [[color(1)]]; };

struct Px { float3 col; float raised; float sprite; float emis; float water; float ui; };

static inline uint4 tx(texture2d<uint, access::read> t, int2 c) {
    c = clamp(c, int2(0, 0), int2(255, 239));
    return t.read(uint2(c));
}

static inline bool isWaterIdx(uint4 d, constant float4* info) {
    bool spOpaque = (d.z & 0x80u) != 0u;
    bool bgOpaque = (d.y & 0x80u) != 0u;
    return !spOpaque && bgOpaque && info[d.y & 63u].y > 0.5;
}

static inline Px decodePx(uint4 d, int2 c, texture2d<uint, access::read> idx,
                          constant float4* pal, constant float4* info, constant Uniforms& u) {
    Px p;
    uint fin = d.x & 63u;
    p.col = pal[fin].rgb;
    bool spOpaque = (d.z & 0x80u) != 0u;
    bool spBehind = (d.z & 0x40u) != 0u;
    bool bgOpaque = (d.y & 0x80u) != 0u;
    bool spVisible = spOpaque && (!spBehind || !bgOpaque);
    uint bgc = d.y & 63u;
    uint floor0 = uint(u.v[16].w), floor1 = uint(u.v[17].x);
    p.sprite = spVisible ? 1.0 : 0.0;
    p.raised = (bgc != floor0 && bgc != floor1) ? 1.0 : 0.0;
    uint spal = (d.w >> 5) & 3u;
    p.emis = spVisible ? (u.v[15][spal] * info[d.z & 63u].x) : info[bgc].z;
    float hud = u.v[1].z;
    p.ui = (float(c.y) < hud || u.v[16].x > 0.5) ? 1.0 : 0.0;
    p.water = 0.0;
    if (u.v[7].z > 0.5 && p.ui < 0.5 && isWaterIdx(d, info)) {
        // require a water neighbourhood so isolated blue details are not animated
        int n = int(isWaterIdx(tx(idx, c + int2(1, 0)), info)) + int(isWaterIdx(tx(idx, c - int2(1, 0)), info)) +
                int(isWaterIdx(tx(idx, c + int2(0, 1)), info)) + int(isWaterIdx(tx(idx, c - int2(0, 1)), info));
        p.water = n >= 3 ? 1.0 : 0.0;
    }
    if (p.ui > 0.5) { p.raised = 0.0; p.emis = 0.0; }
    return p;
}

static inline Px mixPx(Px a, Px b, float t) {
    Px r;
    r.col = mix(a.col, b.col, t);
    r.raised = mix(a.raised, b.raised, t);
    r.sprite = mix(a.sprite, b.sprite, t);
    r.emis = mix(a.emis, b.emis, t);
    r.water = mix(a.water, b.water, t);
    r.ui = mix(a.ui, b.ui, t);
    return r;
}

fragment ScaleOut fs_scale(VOut in [[stage_in]],
                           texture2d<uint, access::read> idx [[texture(0)]],
                           constant float4* pal [[buffer(0)]],
                           constant float4* info [[buffer(1)]],
                           constant Uniforms& u [[buffer(2)]]) {
    float2 src = in.uv * float2(256.0, 240.0);
    // Ultra: wind moving through foliage (only resamples inside foliage, outlines stay put)
    float wind = u.v[18].z * u.v[20].y;
    if (wind > 0.0) {
        uint4 d0 = tx(idx, int2(floor(src)));
        if (info[d0.y & 63u].w > 0.5 && (d0.z & 0x80u) == 0u && src.y >= u.v[1].z) {
            float t = u.v[1].x;
            float sway = sin(t * 1.7 + src.y * 0.09 + src.x * 0.035) * 0.6 + sin(t * 2.9 + src.x * 0.13 + src.y * 0.05) * 0.4;
            float gust = 0.55 + 0.45 * sin(t * 0.37 + src.x * 0.012);
            float2 s2 = src + float2(sway * gust * 0.9 * wind, sway * 0.15 * wind);
            uint4 d2 = tx(idx, int2(floor(s2)));
            if (info[d2.y & 63u].w > 0.5 && (d2.z & 0x80u) == 0u) src = s2;
        }
    }
    int2 P = int2(floor(src));
    float2 f = src - float2(P);
    int mode = int(u.v[1].w);
    uint4 dP = tx(idx, P);
    Px res = decodePx(dP, P, idx, pal, info, u);

    // corner geometry (computed unconditionally so derivatives stay well-defined)
    bool left = f.x < 0.5, top = f.y < 0.5;
    float2 cdist = float2(left ? f.x : 1.0 - f.x, top ? f.y : 1.0 - f.y);
    float d = cdist.x + cdist.y;
    float aa = max(fwidth(d), 0.002) * 0.75;
    float2 fw = max(fwidth(src), float2(0.002));

    if (mode == 1) {
        // Edge-directed smoothing on exact palette indices (EPX/Scale2x rule, continuous + anti-aliased):
        // the corner triangle takes the neighbour colour when two orthogonal neighbours agree.
        int2 dv = int2(0, top ? -1 : 1), dh = int2(left ? -1 : 1, 0);
        uint4 V = tx(idx, P + dv), H = tx(idx, P + dh), Vo = tx(idx, P - dv), Ho = tx(idx, P - dh);
        uint cV = V.x & 63u, cH = H.x & 63u, cVo = Vo.x & 63u, cHo = Ho.x & 63u, cP = dP.x & 63u;
        if (cV == cH && cV != cP && cV != cVo && cH != cHo) {
            float w = 1.0 - smoothstep(0.5 - aa, 0.5 + aa, d);
            res = mixPx(res, decodePx(V, P + dv, idx, pal, info, u), w);
        }
    } else if (mode == 2) {
        // soft: smoothstep-weighted bilinear between source texels
        float2 s = src - 0.5;
        int2 b = int2(floor(s));
        float2 t = smoothstep(0.15, 0.85, s - float2(b));
        Px p00 = decodePx(tx(idx, b), b, idx, pal, info, u);
        Px p10 = decodePx(tx(idx, b + int2(1, 0)), b + int2(1, 0), idx, pal, info, u);
        Px p01 = decodePx(tx(idx, b + int2(0, 1)), b + int2(0, 1), idx, pal, info, u);
        Px p11 = decodePx(tx(idx, b + int2(1, 1)), b + int2(1, 1), idx, pal, info, u);
        res = mixPx(mixPx(p00, p10, t.x), mixPx(p01, p11, t.x), t.y);
    } else {
        // pixel perfect, with a 1-output-pixel anti-aliased seam for non-integer sampling
        float2 e = smoothstep(float2(1.0) - fw, float2(1.0), f);
        if (e.x > 0.0) res = mixPx(res, decodePx(tx(idx, P + int2(1, 0)), P + int2(1, 0), idx, pal, info, u), e.x);
        if (e.y > 0.0) res = mixPx(res, decodePx(tx(idx, P + int2(0, 1)), P + int2(0, 1), idx, pal, info, u), e.y);
    }

    ScaleOut o;
    o.albedo = half4(half3(res.col), half(res.raised));
    o.gbuf = half4(half(res.sprite), half(res.emis), half(res.water), half(res.ui));
    return o;
}

// ---------------------------------------------------------------------------------------------
// 2. Lighting
// ---------------------------------------------------------------------------------------------
static inline float heightAt(texture2d<half> albedo, texture2d<half> gbuf, float2 uv, float lod, constant Uniforms& u) {
    float4 a = float4(albedo.sample(linClamp, uv, level(lod)));
    float s = float(gbuf.sample(linClamp, uv, level(lod)).x);
    float relief = u.v[4].w;
    return a.w * relief + (lum(a.rgb) - 0.35) * 0.35 * relief + s * u.v[5].w;
}

fragment half4 fs_light(VOut in [[stage_in]],
                        texture2d<half> albedo [[texture(0)]],
                        texture2d<half> gbuf [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]],
                        constant Light* lights [[buffer(1)]]) {
    float2 uv = in.uv;
    float2 nes = uv * float2(256.0, 240.0);
    float2 px = float2(1.0 / 256.0, 1.0 / 240.0);       // one NES pixel in uv
    float lodS = u.v[8].w;                               // mip level that corresponds to 1 NES pixel
    float time = u.v[1].x;

    float4 g = float4(gbuf.sample(linClamp, uv, level(0.0)));
    float4 A = float4(albedo.sample(linClamp, uv, level(0.0)));
    float3 alb = A.rgb;
    float ui = g.w;
    float emisStrength = u.v[8].z;

    if (u.v[7].x < 0.5 || ui > 0.99) {
        float3 c = alb * (1.0 + g.y * emisStrength * (1.0 - ui));
        return half4(half3(c), 1.0h);
    }

    // ---- water: refraction + animated normal ------------------------------------------------
    float water = g.z;
    float2 wn = float2(0.0);
    if (water > 0.01) {
        float2 wp = nes * 0.21;
        wn = float2(sin(wp.x * 1.7 + time * 1.3) + sin(wp.y * 2.3 - time * 0.9 + wp.x * 0.7),
                    cos(wp.y * 1.9 + time * 1.1) + sin(wp.x * 1.1 - wp.y * 1.3 + time * 1.7)) * 0.5;
        float3 refr = float3(albedo.sample(linClamp, uv + wn * px * 0.45 * water, level(0.0)).rgb);
        alb = mix(alb, refr, water);
    }

    // ---- relief normal ------------------------------------------------------------------------
    float lodH = lodS + 0.6;
    float hx = heightAt(albedo, gbuf, uv + float2(px.x, 0), lodH, u) - heightAt(albedo, gbuf, uv - float2(px.x, 0), lodH, u);
    float hy = heightAt(albedo, gbuf, uv + float2(0, px.y), lodH, u) - heightAt(albedo, gbuf, uv - float2(0, px.y), lodH, u);
    float3 N = normalize(float3(-hx * 1.6, -hy * 1.6, 1.0));
    N = normalize(mix(N, normalize(float3(wn * 0.45, 1.0)), water));

    float3 L = normalize(u.v[2].xyz);
    float sunI = u.v[2].w;
    float3 sunCol = u.v[3].rgb;
    float ambientI = u.v[3].w;

    // ---- shadows --------------------------------------------------------------------------------
    float shadow = 1.0;
    if (u.v[7].y > 0.5) {
        float2 dir = normalize(L.xy + float2(1e-5));
        float objH = u.v[16].y;                     // NES px height of raised scenery
        float slope = L.z / max(length(L.xy), 1e-3); // ray rise per NES px towards the light
        float h0 = float(albedo.sample(linClamp, uv, level(lodS)).w) * objH;
        float occ = 0.0;
        int steps = int(u.v[20].x);
        float stepLen = 11.2 / float(max(steps, 1));
        for (int k = 1; k <= 16; k++) {
            if (k > steps) break;
            float dist = float(k) * stepLen;
            float2 q = uv + dir * px * dist;
            float hq = float(albedo.sample(linClamp, q, level(lodS + 0.5 + u.v[6].z * 0.5)).w) * objH;
            float ray = h0 + dist * slope;
            occ = max(occ, saturate((hq - ray) * 0.45));
        }
        // sprites float slightly above ground: soft drop shadow offset away from the light
        float off = u.v[6].w;
        float sp = float(gbuf.sample(linClamp, uv + dir * px * off, level(lodS + 0.8 + u.v[6].z)).x);
        occ = max(occ, sp * (1.0 - g.x) * 0.9);
        shadow = 1.0 - occ * u.v[6].y;
    }

    // ---- ambient occlusion: floor next to raised scenery, crevices ------------------------------
    float near = float(albedo.sample(linClamp, uv, level(lodS + 2.2)).w);
    float ao = 1.0 - u.v[6].x * saturate((near - A.w) * 1.4);
    ao *= 1.0 - u.v[6].x * 0.35 * saturate(heightAt(albedo, gbuf, uv, lodS + 2.5, u) - heightAt(albedo, gbuf, uv, lodS, u));

    // ---- Ultra: drifting cloud shadows (overworld) ----------------------------------------------
    float overworld = u.v[20].y;
    float cloud = 0.0;
    if (u.v[18].y > 0.0 && overworld > 0.5) {
        float c = fbm(nes * 0.011 + float2(time * 0.018, time * 0.007));
        cloud = smoothstep(0.47, 0.72, c) * u.v[18].y;
    }

    // ---- direct + ambient -----------------------------------------------------------------------
    float ndl = saturate(dot(N, L)) / max(L.z, 0.25);
    float hemi = saturate(0.5 - N.y * 0.5);
    float3 amb = mix(u.v[5].rgb, u.v[4].rgb, hemi) * ambientI;
    float3 light = amb * ao * (1.0 - cloud * 0.12) + sunCol * sunI * ndl * shadow * (1.0 - cloud * 0.62);

    // ---- Ultra: indirect bounce (colour bleeding from the surroundings) --------------------------
    if (u.v[18].x > 0.0) {
        float3 bounce = float3(albedo.sample(linClamp, uv, level(lodS + 3.5)).rgb);
        light += bounce * u.v[18].x * (sunI * 0.55 * (1.0 - cloud * 0.5) + ambientI * 0.35) * ao;
    }

    // ---- dynamic point lights -------------------------------------------------------------------
    int nl = int(u.v[8].y);
    float lightI = u.v[8].x;
    float3 haze = float3(0.0);
    for (int i = 0; i < nl; i++) {
        Light Lt = lights[i];
        float2 dd = Lt.posRad.xy - nes;
        float dist = length(dd);
        float r = Lt.posRad.w;
        if (dist < r) {
            float att = 1.0 - dist / r;
            att *= att;
            float3 Lv = normalize(float3(dd, Lt.posRad.z));
            float nd = saturate(dot(N, Lv)) / max(Lv.z, 0.3);
            light += Lt.color.rgb * (Lt.color.w * lightI * att) * (0.35 + 0.65 * nd);
        }
        haze += Lt.color.rgb * Lt.color.w * lightI * exp(-dist / (r * 0.28)) * 0.16;
    }

    float3 col = alb * light;

    // ---- water specular + glints ----------------------------------------------------------------
    if (water > 0.01) {
        float3 H = normalize(L + float3(0, 0, 1));
        float spec = pow(saturate(dot(N, H)), 48.0) * 1.6;
        float2 cell = floor(nes * 0.5 + float2(time * 0.7, time * 0.31));
        float glint = step(0.985, hash12(cell)) * (0.5 + 0.5 * sin(time * 6.0 + hash12(cell + 7.0) * 6.28));
        col += (spec + glint * 0.8) * sunCol * sunI * water * shadow;
        col = mix(col, col * float3(0.88, 0.97, 1.08), water * 0.5);
    }

    // ---- Ultra: water reflections ---------------------------------------------------------------
    if (water > 0.01 && u.v[19].z > 0.0) {
        float2 ruv = uv - float2(0.0, px.y * (9.0 + wn.y * 1.5));
        float rw = float(gbuf.sample(linClamp, ruv, level(0.0)).z);
        float3 rc = float3(albedo.sample(linClamp, ruv + float2(wn.x * px.x * 0.8, 0.0), level(lodS * 0.5)).rgb);
        float fres = 0.38 * u.v[19].z * (1.0 - rw);
        col = mix(col, rc * light * 0.85, fres * water);
    }

    // ---- Ultra: volumetric light (sun shafts outdoors, haze around flames indoors) -------------
    float vol = u.v[18].w;
    if (vol > 0.0) {
        col += haze * vol;
        if (overworld > 0.5 && sunI > 0.0) {
            float2 dir = normalize(L.xy + float2(1e-5));
            float acc = 0.0;
            for (int k = 0; k < 10; k++) {
                float2 q = uv + dir * px * (float(k) * 4.0 + 2.0);
                acc += 1.0 - float(albedo.sample(linClamp, q, level(lodS + 1.0)).w);
            }
            acc /= 10.0;
            float nz = vnoise(nes * 0.045 + dir * time * 0.35 + float2(time * 0.04, 0.0));
            float shafts = pow(acc, 3.0) * (0.45 + 0.55 * nz) * (1.0 - cloud);
            col += sunCol * shafts * 0.14 * sunI * vol;
        }
    }

    // ---- Ultra: particles (embers from flames, motes & fireflies) ------------------------------
    float pAmt = u.v[19].x;
    if (pAmt > 0.0) {
        float3 part = float3(0.0);
        for (int i = 0; i < min(nl, 8); i++) {
            Light Lt = lights[i];
            if (Lt.color.g > 0.7) continue;          // warm flame lights only
            for (int j = 0; j < 6; j++) {
                float seed = float(i * 13 + j);
                float per = 1.6 + hash12(float2(seed, 1.0)) * 1.4;
                float ph = fract(time / per + hash12(float2(seed, 2.0)));
                float2 p = Lt.posRad.xy + float2((hash12(float2(seed, 3.0)) - 0.5) * 10.0 + sin(time * 2.3 + seed) * 2.5 * ph,
                                                 -ph * 30.0 - 2.0);
                float2 dp = nes - p;
                float b = exp(-dot(dp, dp) / 0.45) * (1.0 - ph) * (1.0 - ph);
                part += float3(1.0, 0.45, 0.12) * b * 4.0;
            }
        }
        float2 cell = floor(nes / 20.0);
        bool indoorScene = u.v[7].w > 0.5;
        for (int oy = -1; oy <= 1; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
                float2 c = cell + float2(ox, oy);
                float h = hash12(c * 1.37 + 3.1);
                if (h < (indoorScene ? 0.7 : 0.55)) continue;
                float2 base = (c + float2(0.2, 0.2) + float2(hash12(c + 11.0), hash12(c + 23.0)) * 0.6) * 20.0;
                float2 p = base + float2(sin(time * 0.6 + h * 40.0) * 5.0, cos(time * 0.47 + h * 20.0) * 4.0 - sin(time * 0.3 + h) * 2.0);
                float2 dp = nes - p;
                float tw = 0.5 + 0.5 * sin(time * 2.0 + h * 60.0);
                float3 tint = indoorScene ? float3(0.9, 0.85, 0.7) * 0.5 : float3(1.0, 0.95, 0.7);
                part += tint * exp(-dot(dp, dp) / 0.35) * tw * 0.9;
            }
        }
        col += part * pAmt * (1.0 - g.x);
    }

    // ---- subtle rim light on sprites so characters pop ------------------------------------------
    float rim = saturate(dot(normalize(N.xy + float2(1e-4)), normalize(L.xy + float2(1e-5)))) * g.x * (1.0 - N.z) * 0.6;
    col += alb * rim * sunCol * sunI;

    // ---- emissive -------------------------------------------------------------------------------
    col += alb * g.y * emisStrength;

    // UI blending at the HUD edge
    col = mix(col, alb, ui);
    return half4(half3(col), 1.0h);
}

// ---------------------------------------------------------------------------------------------
// 3. Bloom
// ---------------------------------------------------------------------------------------------
// p: xy = 1/src size, z = threshold (<0: no threshold), w = knee
fragment half4 fs_bloom_down(VOut in [[stage_in]], texture2d<half> src [[texture(0)]], constant float4& p [[buffer(0)]]) {
    float2 uv = in.uv, t = p.xy;
    float3 a = float3(src.sample(linClamp, uv + t * float2(-2, -2)).rgb);
    float3 b = float3(src.sample(linClamp, uv + t * float2( 0, -2)).rgb);
    float3 c = float3(src.sample(linClamp, uv + t * float2( 2, -2)).rgb);
    float3 d = float3(src.sample(linClamp, uv + t * float2(-2,  0)).rgb);
    float3 e = float3(src.sample(linClamp, uv).rgb);
    float3 f = float3(src.sample(linClamp, uv + t * float2( 2,  0)).rgb);
    float3 g = float3(src.sample(linClamp, uv + t * float2(-2,  2)).rgb);
    float3 h = float3(src.sample(linClamp, uv + t * float2( 0,  2)).rgb);
    float3 i = float3(src.sample(linClamp, uv + t * float2( 2,  2)).rgb);
    float3 j = float3(src.sample(linClamp, uv + t * float2(-1, -1)).rgb);
    float3 k = float3(src.sample(linClamp, uv + t * float2( 1, -1)).rgb);
    float3 l = float3(src.sample(linClamp, uv + t * float2(-1,  1)).rgb);
    float3 m = float3(src.sample(linClamp, uv + t * float2( 1,  1)).rgb);
    float3 c0 = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    if (p.z >= 0.0) {
        float br = max(c0.r, max(c0.g, c0.b));
        float soft = clamp(br - p.z + p.w, 0.0, 2.0 * p.w);
        soft = soft * soft / (4.0 * p.w + 1e-4);
        float contrib = max(soft, br - p.z) / max(br, 1e-4);
        c0 *= contrib;
    }
    return half4(half3(c0), 1.0h);
}

// p: xy = 1/src size, z = radius scale
fragment half4 fs_bloom_up(VOut in [[stage_in]], texture2d<half> src [[texture(0)]], constant float4& p [[buffer(0)]]) {
    float2 uv = in.uv, t = p.xy * p.z;
    float3 c = float3(src.sample(linClamp, uv).rgb) * 4.0;
    c += float3(src.sample(linClamp, uv + t * float2(-1, 0)).rgb) * 2.0;
    c += float3(src.sample(linClamp, uv + t * float2( 1, 0)).rgb) * 2.0;
    c += float3(src.sample(linClamp, uv + t * float2(0, -1)).rgb) * 2.0;
    c += float3(src.sample(linClamp, uv + t * float2(0,  1)).rgb) * 2.0;
    c += float3(src.sample(linClamp, uv + t * float2(-1, -1)).rgb);
    c += float3(src.sample(linClamp, uv + t * float2( 1, -1)).rgb);
    c += float3(src.sample(linClamp, uv + t * float2(-1,  1)).rgb);
    c += float3(src.sample(linClamp, uv + t * float2( 1,  1)).rgb);
    return half4(half3(c / 16.0), 1.0h);
}

// ---------------------------------------------------------------------------------------------
// 4. Final composite
// ---------------------------------------------------------------------------------------------
static inline float3 tonemapACES(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

static inline float3 agxContrast(float3 x) {
    float3 x2 = x * x, x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

static inline float3 tonemapAgX(float3 c) {
    const float3x3 m = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 mi = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                 float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                 float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float minEv = -12.47393, maxEv = 4.026069;
    c = m * max(c, float3(1e-10));
    c = clamp(log2(c), float3(minEv), float3(maxEv));
    c = (c - minEv) / (maxEv - minEv);
    c = agxContrast(c);
    c = mi * c;
    return pow(max(c, float3(0.0)), float3(2.2));
}

static inline float3 tonemapNeutral(float3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;
    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression) return color;
    const float dd = 1.0 - startCompression;
    float newPeak = 1.0 - dd * dd / (peak + dd - startCompression);
    color *= newPeak / peak;
    float gg = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, float3(newPeak), gg);
}

// Extended-dynamic-range roll-off: identity below the knee, smooth approach to the display headroom.
static inline float3 edrRolloff(float3 c, float headroom) {
    float knee = 0.8;
    float m = max(c.r, max(c.g, c.b));
    if (m <= knee) return c;
    float range = max(headroom - knee, 0.01);
    float mo = knee + range * (1.0 - exp(-(m - knee) / range));
    return c * (mo / m);
}

static inline float2 crtWarp(float2 uv, float k) {
    float2 c = uv * 2.0 - 1.0;
    c *= 1.0 + k * dot(c, c) * float2(0.25, 0.35);
    return c * 0.5 + 0.5;
}

fragment float4 fs_final(VOut in [[stage_in]],
                         texture2d<half> hdr [[texture(0)]],
                         texture2d<half> bloom [[texture(1)]],
                         texture2d<half> ambientTex [[texture(2)]],
                         texture2d<half> flareTex [[texture(3)]],
                         constant Uniforms& u [[buffer(0)]]) {
    float2 pix = in.pos.xy;
    float4 rect = u.v[13];
    float2 cuv = (pix - rect.xy) / rect.zw;
    bool crt = u.v[11].w > 0.5;
    if (crt) cuv = crtWarp(cuv, u.v[17].y);
    bool inside = all(cuv >= float2(0.0)) && all(cuv <= float2(1.0));
    float time = u.v[1].x;
    float3 col;

    if (!inside) {
        if (u.v[12].w > 0.5) {
            // ambient fill: heavily blurred, dimmed extension of the picture
            float2 suv = pix * u.v[14].zw;
            float2 fuv = (suv - 0.5) * 0.7 + 0.5;
            col = float3(ambientTex.sample(linClamp, fuv).rgb) * 0.32;
            float2 q = suv - 0.5;
            col *= 1.0 - dot(q, q) * 1.2;
        } else {
            col = float3(0.0);
        }
    } else {
        float2 texel = 1.0 / float2(hdr.get_width(), hdr.get_height());
        float ca = u.v[11].y;
        float2 off = (cuv - 0.5) * ca * 0.006;
        col.r = float(hdr.sample(linClamp, cuv + off).r);
        col.g = float(hdr.sample(linClamp, cuv).g);
        col.b = float(hdr.sample(linClamp, cuv - off).b);
        // contrast-adaptive-ish sharpening
        float sharp = u.v[11].z;
        if (sharp > 0.0) {
            float2 so = max(texel, 1.0 / max(rect.zw, float2(1.0)));
            float3 n = float3(hdr.sample(linClamp, cuv + float2(so.x, 0)).rgb) + float3(hdr.sample(linClamp, cuv - float2(so.x, 0)).rgb) +
                       float3(hdr.sample(linClamp, cuv + float2(0, so.y)).rgb) + float3(hdr.sample(linClamp, cuv - float2(0, so.y)).rgb);
            float3 detail = col - n * 0.25;
            float adapt = 1.0 - saturate(length(detail) * 2.0);
            col = max(col + detail * sharp * adapt * 1.5, float3(0.0));
        }
        // Ultra: tilt-shift depth of field (playfield only, HUD stays sharp)
        float dof = u.v[19].y;
        float hudF = u.v[1].z / 240.0;
        if (dof > 0.0 && cuv.y > hudF) {
            float center = hudF + (1.0 - hudF) * 0.55;
            float blur = smoothstep(0.16, 0.5, abs(cuv.y - center)) * dof;
            float3 b = float3(hdr.sample(linClamp, cuv, level(1.0 + blur * 3.0)).rgb);
            col = mix(col, b, saturate(blur * 1.6));
        }
        col += float3(bloom.sample(linClamp, cuv).rgb) * u.v[9].x;
        // Ultra: anamorphic lens streaks
        if (u.v[19].w > 0.0) {
            float3 st = float3(0.0); float ws = 0.0;
            for (int i = -6; i <= 6; i++) {
                float w = exp(-abs(float(i)) * 0.35);
                st += float3(flareTex.sample(linClamp, cuv + float2(float(i) * 0.018, 0.0)).rgb) * w;
                ws += w;
            }
            col += st / ws * float3(0.45, 0.65, 1.25) * u.v[19].w * 0.6;
        }
    }

    col *= u.v[9].z;   // exposure

    bool hdrOn = u.v[12].y > 0.5;
    int tm = int(u.v[9].w);
    // grading in linear light before the curve
    float t = u.v[10].z;
    col *= float3(1.0 + t * 0.12, 1.0 + t * 0.02, 1.0 - t * 0.12);
    float l = lum(col);
    col = max(mix(float3(l), col, u.v[10].y), float3(0.0));
    // contrast around mid grey in log space
    float k = u.v[10].x;
    col = 0.18 * pow(max(col / 0.18, float3(1e-5)), float3(k));

    if (hdrOn) {
        col = edrRolloff(col, max(u.v[12].z, 1.0));
    } else if (tm == 1) {
        col = tonemapNeutral(col);
    } else if (tm == 2) {
        col = tonemapAgX(col);
    } else if (tm == 3) {
        col = tonemapACES(col * 1.25);
    } else {
        col = saturate(col);
    }

    if (inside) {
        // vignette
        float2 q = cuv - 0.5;
        float vig = 1.0 - u.v[10].w * smoothstep(0.2, 0.85, length(q * float2(1.0, 1.1)) * 1.25);
        col *= vig;
        // CRT scanlines + aperture grille
        if (crt) {
            float line = cuv.y * 240.0;
            float s = 0.5 + 0.5 * cos(6.2831853 * line);
            col *= mix(1.0, 0.55 + 0.45 * s, u.v[12].x);
            int m = int(pix.x) % 3;
            float3 mask = m == 0 ? float3(1.0, 0.82, 0.82) : (m == 1 ? float3(0.82, 1.0, 0.82) : float3(0.82, 0.82, 1.0));
            col *= mix(float3(1.0), mask, u.v[12].x * 0.8);
            col *= 1.0 + u.v[12].x * 0.35;
        }
    }

    // film grain (luminance weighted, animated) + dither against banding
    float grain = u.v[11].x;
    float nse = hash12(pix + fract(time * 17.0) * 913.0) - 0.5;
    float lw = 1.0 - abs(lum(col) * 2.0 - 1.0);
    col += nse * (grain * (0.35 + 0.65 * lw) + 1.0 / 255.0);
    col = max(col, float3(0.0));
    return float4(col, 1.0);
}
"""#
