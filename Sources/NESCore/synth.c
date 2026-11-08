// synth.c — "Remastered" audio engine.
//
// The game's sound driver keeps running unmodified on the emulated APU. Each output sample we read
// the live channel state (pitch, volume, duty, note triggers) and re-render it:
//   * ORIGINAL       the 2A03 mix (unchanged)
//   * ENHANCED CHIP  band-limited (PolyBLEP) chip voices, stereo placement, room reverb, bus compression
//   * REMASTERED     modern instruments driven by the game's music data: detuned-saw brass/lead,
//                    stereo string ensemble, warm bass with sub, synthesized percussion bodies,
//                    hall reverb, stereo width and mastering (compressor + soft limiter).
// Two instrument styles: Orchestral and Synthwave. Nothing is sampled from the game; it is all synthesis.
#include "nes_internal.h"
#include <math.h>
#include <stdlib.h>

#define TWO_PI 6.28318530718f
int synth_solo = -1;   // debugging: render a single voice

typedef struct { float ic1, ic2; } SVF;

static inline void svf_run(SVF *s, float v0, float cutoff, float q, float sr, float *lp, float *bp, float *hp) {
    if (cutoff > sr * 0.45f) cutoff = sr * 0.45f;
    if (cutoff < 10.0f) cutoff = 10.0f;
    float g = tanf(3.14159265f * cutoff / sr), k = 1.0f / q;
    float a1 = 1.0f / (1.0f + g * (g + k)), a2 = g * a1, a3 = g * a2;
    float v3 = v0 - s->ic2;
    float v1 = a1 * s->ic1 + a2 * v3;
    float v2 = s->ic2 + a2 * s->ic1 + a3 * v3;
    s->ic1 = 2.0f * v1 - s->ic1;
    s->ic2 = 2.0f * v2 - s->ic2;
    if (lp) *lp = v2;
    if (bp) *bp = v1;
    if (hp) *hp = v0 - k * v1 - v2;
}

static inline float polyblep(float t, float dt) {
    if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
    if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
    return 0.0f;
}
static inline float osc_saw(float ph, float dt) { return 2.0f * ph - 1.0f - polyblep(ph, dt); }
static inline float osc_pulse(float ph, float dt, float w) {
    float p2 = ph + 1.0f - w; if (p2 >= 1.0f) p2 -= 1.0f;
    return (ph < w ? 1.0f : -1.0f) + polyblep(ph, dt) - polyblep(p2, dt);
}
static inline float wrap1(float x) { return x - floorf(x); }
static inline float cents(float c) { return powf(2.0f, c / 1200.0f); }

typedef struct {
    float ph[6];
    float amp, freq, fenv, t_on, vib_ph;
    SVF f1, f2, f3;
    float body_ph, body_amp, body_f, body_decay, body_fend;
    uint16_t lfsr; float noise_ph, noise_val;
    float dc;
} Voice;

// Freeverb (Jezar, public domain) — stereo
#define NCOMB 8
#define NAP 4
typedef struct { float *buf; int size, idx; float store; } Comb;
typedef struct { float *buf; int size, idx; } AllPass;

struct Synth {
    int mode, style;
    float sr;
    float reverb, width, chip_blend, master, bass_boost;
    Voice v[5];
    Comb combL[NCOMB], combR[NCOMB];
    AllPass apL[NAP], apR[NAP];
    float *mem;
    float comp_env;
    float predelay[4096]; int pd_idx;
    float hpL, hpR, hpLin, hpRin;
};

static const int COMB_T[NCOMB] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
static const int AP_T[NAP] = {556, 441, 341, 225};

Synth *synth_create(void) {
    Synth *s = (Synth *)calloc(1, sizeof(Synth));
    // allocate for up to 192 kHz
    int total = 0;
    for (int i = 0; i < NCOMB; i++) total += 2 * (int)((COMB_T[i] + 23) * 4.4f + 8);
    for (int i = 0; i < NAP; i++) total += 2 * (int)((AP_T[i] + 23) * 4.4f + 8);
    s->mem = (float *)calloc((size_t)total, sizeof(float));
    s->sr = 48000; s->mode = 0; s->style = 0;
    s->reverb = 0.35f; s->width = 1.0f; s->chip_blend = 0.0f; s->master = 1.0f; s->bass_boost = 0.3f;
    for (int i = 0; i < 5; i++) s->v[i].lfsr = 1;
    return s;
}

void synth_destroy(Synth *s) { if (s) { free(s->mem); free(s); } }

static void synth_setup_reverb(Synth *s, float sr) {
    float sc = sr / 44100.0f;
    float *p = s->mem;
    for (int i = 0; i < NCOMB; i++) {
        s->combL[i].size = (int)(COMB_T[i] * sc); s->combL[i].buf = p; p += (int)((COMB_T[i] + 23) * 4.4f + 8);
        s->combR[i].size = (int)((COMB_T[i] + 23) * sc); s->combR[i].buf = p; p += (int)((COMB_T[i] + 23) * 4.4f + 8);
        s->combL[i].idx = s->combR[i].idx = 0;
    }
    for (int i = 0; i < NAP; i++) {
        s->apL[i].size = (int)(AP_T[i] * sc); s->apL[i].buf = p; p += (int)((AP_T[i] + 23) * 4.4f + 8);
        s->apR[i].size = (int)((AP_T[i] + 23) * sc); s->apR[i].buf = p; p += (int)((AP_T[i] + 23) * 4.4f + 8);
        s->apL[i].idx = s->apR[i].idx = 0;
    }
}

void synth_configure(Synth *s, int mode, int style, float reverb, float width, float chip_blend, float bass_boost) {
    s->mode = mode; s->style = style;
    s->reverb = reverb; s->width = width; s->chip_blend = chip_blend; s->bass_boost = bass_boost;
}

static inline float comb_run(Comb *c, float in, float fb, float d1, float d2) {
    float out = c->buf[c->idx];
    c->store = out * d2 + c->store * d1;
    c->buf[c->idx] = in + c->store * fb;
    if (++c->idx >= c->size) c->idx = 0;
    return out;
}
static inline float ap_run(AllPass *a, float in) {
    float b = a->buf[a->idx];
    a->buf[a->idx] = in + b * 0.5f;
    if (++a->idx >= a->size) a->idx = 0;
    return b - in;
}

static void reverb_run(Synth *s, float in, float room, float damp, float *oL, float *oR) {
    float fb = room * 0.28f + 0.7f, d1 = damp * 0.4f, d2 = 1.0f - d1;
    float x = in * 0.015f, l = 0, r = 0;
    for (int i = 0; i < NCOMB; i++) { l += comb_run(&s->combL[i], x, fb, d1, d2); r += comb_run(&s->combR[i], x, fb, d1, d2); }
    for (int i = 0; i < NAP; i++) { l = ap_run(&s->apL[i], l); r = ap_run(&s->apR[i], r); }
    *oL = l; *oR = r;
}

static inline float smooth(float cur, float target, float a_up, float a_down) {
    return cur + (target - cur) * (target > cur ? a_up : a_down);
}
static inline float coef(float ms, float sr) { return 1.0f - expf(-1.0f / (ms * 0.001f * sr)); }

// --------------------------------------------------------------------------------------------
// voices
// --------------------------------------------------------------------------------------------
typedef struct { float freq, vol; int on, trig; float duty; } ChanState;

static float voice_lead(Synth *s, Voice *v, ChanState c, float *pan_spread) {
    float sr = s->sr;
    if (c.trig) { v->fenv = 1.0f; v->t_on = 0; v->vib_ph = 0; }
    float target = c.on ? c.vol : 0.0f;
    v->amp = smooth(v->amp, target, coef(s->style ? 2.0f : 6.0f, sr), coef(s->style ? 60.0f : 90.0f, sr));
    if (c.on && c.freq > 20) v->freq = c.freq;
    if (v->amp < 1e-5f || v->freq <= 0) return 0;
    v->t_on += 1.0f / sr;
    v->fenv *= expf(-1.0f / ((s->style ? 0.18f : 0.32f) * sr));
    // delayed vibrato
    float vd = fminf(1.0f, fmaxf(0.0f, (v->t_on - 0.28f) * 2.5f));
    v->vib_ph = wrap1(v->vib_ph + 5.3f / sr);
    float f = v->freq * (1.0f + vd * 0.0045f * sinf(TWO_PI * v->vib_ph));
    static const float det_orch[3] = {-6.0f, 0.0f, 6.5f};
    static const float det_synth[5] = {-17.0f, -7.0f, 0.0f, 7.5f, 16.5f};
    int nv = s->style ? 5 : 3;
    float sum = 0;
    for (int i = 0; i < nv; i++) {
        float fi = f * cents(s->style ? det_synth[i] : det_orch[i]);
        float dt = fi / sr;
        v->ph[i] = wrap1(v->ph[i] + dt);
        sum += osc_saw(v->ph[i], dt);
    }
    sum /= (float)nv;
    // keep a little of the NES duty character
    float dt0 = f / sr;
    v->ph[5] = wrap1(v->ph[5] + dt0);
    sum = sum * 0.8f + osc_pulse(v->ph[5], dt0, c.duty) * 0.2f;
    float cutoff = s->style ? f * (3.0f + 14.0f * v->fenv) + 900.0f : f * (2.2f + 7.0f * v->fenv) + 400.0f;
    float lp;
    svf_run(&v->f1, sum, cutoff, s->style ? 1.1f : 0.75f, sr, &lp, 0, 0);
    *pan_spread = s->style ? 0.35f : 0.15f;
    return lp * v->amp;
}

static float voice_strings(Synth *s, Voice *v, ChanState c, float *side) {
    float sr = s->sr;
    if (c.trig) { v->fenv = 1.0f; v->t_on = 0; }
    float target = c.on ? c.vol : 0.0f;
    if (s->style) v->amp = smooth(v->amp, target, coef(1.5f, sr), coef(45.0f, sr));      // synth pluck
    else v->amp = smooth(v->amp, target, coef(28.0f, sr), coef(160.0f, sr));           // bowed strings
    if (c.on && c.freq > 20) v->freq = c.freq;
    if (v->amp < 1e-5f || v->freq <= 0) { *side = 0; return 0; }
    v->t_on += 1.0f / sr;
    v->fenv *= expf(-1.0f / ((s->style ? 0.12f : 0.6f) * sr));
    v->vib_ph = wrap1(v->vib_ph + 4.7f / sr);
    float f = v->freq * (1.0f + 0.003f * sinf(TWO_PI * v->vib_ph) * fminf(1.0f, v->t_on * 2.0f));
    static const float det[4] = {-11.0f, -3.5f, 4.0f, 12.0f};
    float l = 0, r = 0;
    for (int i = 0; i < 4; i++) {
        float fi = f * cents(det[i]), dt = fi / sr;
        v->ph[i] = wrap1(v->ph[i] + dt);
        float o = s->style ? osc_pulse(v->ph[i], dt, c.duty < 0.2f ? 0.25f : c.duty) : osc_saw(v->ph[i], dt);
        if (i & 1) r += o; else l += o;
    }
    float cut = s->style ? f * (1.5f + 10.0f * v->fenv) + 300.0f : fminf(f * 3.2f + 600.0f, 5200.0f);
    float m = (l + r) * 0.25f, sd = (l - r) * 0.25f, lp, lps;
    svf_run(&v->f1, m, cut, 0.7f, sr, &lp, 0, 0);
    svf_run(&v->f2, sd, cut, 0.7f, sr, &lps, 0, 0);
    *side = lps * v->amp * 1.2f;
    return lp * v->amp;
}

static float voice_bass(Synth *s, Voice *v, ChanState c) {
    float sr = s->sr;
    if (c.trig) { v->fenv = 1.0f; }
    float target = c.on ? 1.0f : 0.0f;
    v->amp = smooth(v->amp, target, coef(2.5f, sr), coef(35.0f, sr));
    if (c.on && c.freq > 15) v->freq = c.freq;
    if (v->amp < 1e-5f || v->freq <= 0) return 0;
    v->fenv *= expf(-1.0f / (0.2f * sr));
    float f = v->freq, dt = f / sr;
    v->ph[0] = wrap1(v->ph[0] + dt);
    v->ph[1] = wrap1(v->ph[1] + dt * 0.5f);
    float out;
    if (s->style) {
        float saw = osc_saw(v->ph[0], dt), lp;
        svf_run(&v->f1, saw, 220.0f + f * 1.5f + 2600.0f * v->fenv, 1.8f, sr, &lp, 0, 0);
        out = tanhf(lp * 1.6f) * 0.8f + sinf(TWO_PI * v->ph[1]) * 0.35f * (f > 70 ? 1.0f : 0.0f);
    } else {
        float x = sinf(TWO_PI * v->ph[0]) + 0.28f * sinf(2.0f * TWO_PI * v->ph[0]) + 0.08f * sinf(3.0f * TWO_PI * v->ph[0]);
        float lp;
        svf_run(&v->f1, tanhf(x * 1.3f), 1400.0f, 0.7f, sr, &lp, 0, 0);
        out = lp * 0.85f + sinf(TWO_PI * v->ph[1]) * 0.3f * (f > 70 ? 1.0f : 0.0f);
    }
    return out * v->amp;
}

static float voice_noise(Synth *s, Voice *v, ChanState c, int pidx, int mode, float noise_rate) {
    float sr = s->sr;
    float target = c.on ? c.vol : 0.0f;
    v->amp = smooth(v->amp, target, coef(0.7f, sr), coef(12.0f, sr));
    if (c.trig && c.vol > 0.05f) {
        // percussion "body": low indices are hats, mid snares, high toms/kicks/explosions
        if (pidx >= 9) { v->body_f = s->style ? 150.0f : 120.0f; v->body_fend = 42.0f; v->body_decay = 0.16f; v->body_amp = c.vol * (s->style ? 1.1f : 0.8f); }
        else if (pidx >= 4) { v->body_f = s->style ? 230.0f : 190.0f; v->body_fend = 150.0f; v->body_decay = 0.07f; v->body_amp = c.vol * 0.45f; }
        else v->body_amp = 0;
        v->body_ph = 0;
    }
    // noise generator clocked at the APU's noise rate (keeps the game's timbre choices)
    v->noise_ph += noise_rate / sr;
    while (v->noise_ph >= 1.0f) {
        v->noise_ph -= 1.0f;
        uint16_t fb = (uint16_t)((v->lfsr & 1) ^ ((v->lfsr >> (mode ? 6 : 1)) & 1));
        v->lfsr = (uint16_t)((v->lfsr >> 1) | (fb << 14));
        v->noise_val = (v->lfsr & 1) ? -1.0f : 1.0f;
    }
    float out = 0;
    if (v->amp > 1e-5f) {
        float lp, hp;
        svf_run(&v->f1, v->noise_val, fminf(noise_rate * 0.5f + 800.0f, 15000.0f), 0.7f, sr, &lp, 0, 0);
        svf_run(&v->f2, lp, s->style ? 260.0f : 140.0f, 0.7f, sr, 0, 0, &hp);
        out = hp * v->amp * 0.85f;
    }
    if (v->body_amp > 1e-4f) {
        float f = v->body_fend + (v->body_f - v->body_fend) * expf(-v->body_ph * 18.0f);
        v->body_ph += 1.0f / sr;
        v->ph[0] = wrap1(v->ph[0] + f / sr);
        out += sinf(TWO_PI * v->ph[0]) * v->body_amp;
        v->body_amp *= expf(-1.0f / (v->body_decay * sr));
    }
    return out;
}

// band-limited chip voices for ENHANCED CHIP
static float chip_pulse(Synth *s, Voice *v, ChanState c) {
    float sr = s->sr;
    v->amp = smooth(v->amp, c.on ? c.vol : 0.0f, coef(0.6f, sr), coef(3.0f, sr));
    if (c.on && c.freq > 20) v->freq = c.freq;
    if (v->amp < 1e-5f || v->freq <= 0) return 0;
    float dt = v->freq / sr;
    v->ph[0] = wrap1(v->ph[0] + dt);
    return osc_pulse(v->ph[0], dt, c.duty) * v->amp * 0.5f;
}
static float chip_tri(Synth *s, Voice *v, ChanState c) {
    float sr = s->sr;
    v->amp = smooth(v->amp, c.on ? 1.0f : 0.0f, coef(0.8f, sr), coef(4.0f, sr));
    if (c.on && c.freq > 15) v->freq = c.freq;
    if (v->amp < 1e-5f || v->freq <= 0) return 0;
    v->ph[0] = wrap1(v->ph[0] + v->freq / sr);
    float t = v->ph[0];
    float tri = 4.0f * fabsf(t - 0.5f) - 1.0f;
    // gentle 4-bit stepping like the hardware, softened
    tri = floorf(tri * 7.5f + 0.5f) / 7.5f;
    float lp;
    svf_run(&v->f1, tri, 9000.0f, 0.7f, sr, &lp, 0, 0);
    return lp * v->amp * 0.6f;
}

// --------------------------------------------------------------------------------------------
void synth_render(NES *n, float orig, float *outL, float *outR) {
    Synth *s = n->synth;
    if (!s || s->mode == 0) { *outL = *outR = orig; return; }
    APU *a = &n->apu;
    float sr = (float)(n->sample_rate ? n->sample_rate : 48000);
    if (fabsf(sr - s->sr) > 2000.0f || s->combL[0].buf == NULL) { s->sr = sr; synth_setup_reverb(s, sr); }
    s->sr = sr;
    float cpu = n->region == NES_REGION_PAL ? 26601712.0f / 16.0f : 21477272.0f / 12.0f;
    static const float DUTYW[4] = {0.125f, 0.25f, 0.5f, 0.75f};

    ChanState pc[2];
    for (int i = 0; i < 2; i++) {
        uint16_t per = a->pu[i].period;
        uint16_t ch = per >> a->pu[i].sw_shift;
        uint16_t tgt = a->pu[i].sw_neg ? (uint16_t)(per - ch - (i == 0)) : (uint16_t)(per + ch);
        pc[i].on = a->pu[i].len && per >= 8 && tgt <= 0x7FF;
        pc[i].freq = cpu / (16.0f * (per + 1));
        pc[i].vol = powf((a->pu[i].const_vol ? a->pu[i].vol : a->pu[i].env_decay) / 15.0f, 0.8f);
        if (pc[i].vol <= 0) pc[i].on = 0;
        pc[i].duty = DUTYW[a->pu[i].duty & 3];
        pc[i].trig = n->synth_trig[i]; n->synth_trig[i] = 0;
    }
    ChanState tc;
    tc.on = a->tri.len && a->tri.lin && a->tri.period >= 2;
    tc.freq = cpu / (32.0f * (a->tri.period + 1));
    tc.vol = 1; tc.duty = 0.5f;
    tc.trig = n->synth_trig[2]; n->synth_trig[2] = 0;
    ChanState nc;
    nc.on = a->noi.len != 0;
    nc.vol = (a->noi.const_vol ? a->noi.vol : a->noi.env_decay) / 15.0f;
    nc.freq = 0; nc.duty = 0.5f;
    nc.trig = n->synth_trig[3]; n->synth_trig[3] = 0;
    float noise_rate = cpu / (float)(a->noi.period ? a->noi.period : 4);
    // DMC as a sample stream (DC-blocked)
    float dmc = (float)a->dmc.out / 64.0f;
    Voice *dv = &s->v[4];
    dv->dc += (dmc - dv->dc) * 0.0015f;
    float dmcx = dmc - dv->dc, dmcl;
    svf_run(&dv->f1, dmcx, 7000.0f, 0.7f, sr, &dmcl, 0, 0);

    float L = 0, R = 0, rvb_in = 0;
    if (s->mode == 1) {
        // ENHANCED CHIP
        float p1 = chip_pulse(s, &s->v[0], pc[0]);
        float p2 = chip_pulse(s, &s->v[1], pc[1]);
        float t = chip_tri(s, &s->v[2], tc);
        float nz = 0;
        {
            Voice *v = &s->v[3];
            v->amp = smooth(v->amp, nc.on ? nc.vol : 0.0f, coef(0.5f, sr), coef(3.0f, sr));
            v->noise_ph += noise_rate / sr;
            while (v->noise_ph >= 1.0f) {
                v->noise_ph -= 1.0f;
                uint16_t fb = (uint16_t)((v->lfsr & 1) ^ ((v->lfsr >> (a->noi.mode ? 6 : 1)) & 1));
                v->lfsr = (uint16_t)((v->lfsr >> 1) | (fb << 14));
                v->noise_val = (v->lfsr & 1) ? -1.0f : 1.0f;
            }
            float lp; svf_run(&v->f1, v->noise_val, 14000.0f, 0.7f, sr, &lp, 0, 0);
            nz = lp * v->amp * 0.32f;
        }
        L = p1 * 0.85f + p2 * 0.45f + t * 0.9f + nz * 0.85f + dmcl * 0.6f;
        R = p1 * 0.45f + p2 * 0.85f + t * 0.9f + nz * 0.95f + dmcl * 0.6f;
        rvb_in = (p1 + p2) * 0.4f + nz * 0.2f + dmcl * 0.2f;
        L *= 0.55f; R *= 0.55f; rvb_in *= 0.55f;
    } else {
        // REMASTERED
        float spread, side;
        float lead = voice_lead(s, &s->v[0], pc[0], &spread);
        float str = voice_strings(s, &s->v[1], pc[1], &side);
        float bass = voice_bass(s, &s->v[2], tc) * (1.0f + s->bass_boost);
        float perc = voice_noise(s, &s->v[3], nc, a->noi.pidx, a->noi.mode, noise_rate);
        (void)spread;
        if (synth_solo >= 0) { int so = synth_solo; if (so != 0) lead = 0; if (so != 1) { str = 0; side = 0; } if (so != 2) bass = 0; if (so != 3) perc = 0; if (so != 4) dmcl = 0; }
        lead *= 3.1f; str *= 3.3f; side *= 3.3f; bass *= 0.42f; perc *= 0.85f;
        L = lead * 0.62f + str * 0.44f + side + bass * 0.62f + perc * 0.5f + dmcl * 0.5f;
        R = lead * 0.48f + str * 0.58f - side + bass * 0.62f + perc * 0.56f + dmcl * 0.5f;
        rvb_in = lead * 0.5f + str * 0.65f + perc * 0.25f + bass * 0.06f + dmcl * 0.3f;
        L *= 0.42f; R *= 0.42f; rvb_in *= 0.42f;
    }

    // reverb (hall for remastered, room for chip)
    float rl, rr;
    float room = s->mode == 2 ? 0.86f : 0.62f, damp = s->mode == 2 ? 0.35f : 0.5f;
    s->predelay[s->pd_idx] = rvb_in;
    int pd = (int)(sr * (s->mode == 2 ? 0.028f : 0.012f)); if (pd > 4095) pd = 4095;
    float delayed = s->predelay[(s->pd_idx - pd + 4096) & 4095];
    s->pd_idx = (s->pd_idx + 1) & 4095;
    reverb_run(s, delayed, room, damp, &rl, &rr);
    float wet = s->reverb * 1.6f;
    L += rl * wet; R += rr * wet;

    // stereo width (M/S)
    float m = (L + R) * 0.5f, sd = (L - R) * 0.5f * s->width;
    L = m + sd; R = m - sd;

    // blend of the untouched chip mix (for character)
    L = L * (1.0f - s->chip_blend) + orig * s->chip_blend;
    R = R * (1.0f - s->chip_blend) + orig * s->chip_blend;

    // DC/rumble high-pass at 25 Hz
    float ahp = 1.0f / (1.0f + TWO_PI * 25.0f / sr);
    float hl = ahp * (s->hpL + L - s->hpLin); s->hpLin = L; s->hpL = hl;
    float hr = ahp * (s->hpR + R - s->hpRin); s->hpRin = R; s->hpR = hr;
    L = hl; R = hr;

    // bus compressor (peak follower) + soft limiter
    float peak = fmaxf(fabsf(L), fabsf(R));
    s->comp_env = smooth(s->comp_env, peak, coef(4.0f, sr), coef(140.0f, sr));
    float thr = 0.35f, gain = 1.0f;
    if (s->comp_env > thr) gain = powf(thr / s->comp_env, 1.0f - 1.0f / 3.0f);
    gain *= 1.35f;  // make-up
    L = tanhf(L * gain);
    R = tanhf(R * gain);
    *outL = L * 0.9f;
    *outR = R * 0.9f;
}
