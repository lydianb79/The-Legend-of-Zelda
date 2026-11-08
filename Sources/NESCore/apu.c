// apu.c — 2A03/2A07 audio: 2 pulse, triangle, noise, DMC, frame counter,
// non-linear mixer and band-limited box resampling to the host rate.
#include "nes_internal.h"
#include <math.h>

static const uint8_t LEN[32] = {10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30};
static const uint8_t DUTY[4][8] = {{0,1,0,0,0,0,0,0},{0,1,1,0,0,0,0,0},{0,1,1,1,1,0,0,0},{1,0,0,1,1,1,1,1}};
static const uint8_t TRI[32] = {15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
static const uint16_t NOISE_NTSC[16] = {4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068};
static const uint16_t NOISE_PAL[16]  = {4,8,14,30,60,88,118,148,188,236,354,472,708,944,1890,3778};
static const uint16_t DMC_NTSC[16] = {428,380,340,320,286,254,226,214,190,160,142,128,106,84,72,54};
static const uint16_t DMC_PAL[16]  = {398,354,316,298,276,236,210,198,176,148,132,118,98,78,66,50};
static const uint32_t FSTEP_NTSC[5] = {7457, 14913, 22371, 29829, 37281};
static const uint32_t FSTEP_PAL[5]  = {8313, 16627, 24939, 33253, 41565};

static double cpu_hz(NES *n) { return n->region == NES_REGION_PAL ? 26601712.0 / 16.0 : 21477272.0 / 12.0; }

void apu_reset(NES *n) {
    APU *a = &n->apu;
    uint64_t c = a->cyc;
    memset(a, 0, sizeof(*a));
    a->cyc = c;
    a->noi.lfsr = 1;
    a->dmc.bits_left = 8; a->dmc.silence = 1;
    a->dmc.timer = DMC_NTSC[0];
    a->sample_step = cpu_hz(n) / (double)(n->sample_rate ? n->sample_rate : 48000);
}

static uint16_t sweep_target(APU *a, int i) {
    uint16_t ch = a->pu[i].period >> a->pu[i].sw_shift;
    if (a->pu[i].sw_neg) return (uint16_t)(a->pu[i].period - ch - (i == 0 ? 1 : 0));
    return (uint16_t)(a->pu[i].period + ch);
}

static void quarter(APU *a) {
    for (int i = 0; i < 2; i++) {
        if (a->pu[i].env_start) { a->pu[i].env_start = 0; a->pu[i].env_decay = 15; a->pu[i].env_div = a->pu[i].vol; }
        else if (a->pu[i].env_div == 0) { a->pu[i].env_div = a->pu[i].vol;
            if (a->pu[i].env_decay) a->pu[i].env_decay--; else if (a->pu[i].halt) a->pu[i].env_decay = 15; }
        else a->pu[i].env_div--;
    }
    if (a->noi.env_start) { a->noi.env_start = 0; a->noi.env_decay = 15; a->noi.env_div = a->noi.vol; }
    else if (a->noi.env_div == 0) { a->noi.env_div = a->noi.vol;
        if (a->noi.env_decay) a->noi.env_decay--; else if (a->noi.halt) a->noi.env_decay = 15; }
    else a->noi.env_div--;
    if (a->tri.lin_reload) a->tri.lin = a->tri.lin_reload_val; else if (a->tri.lin) a->tri.lin--;
    if (!a->tri.halt) a->tri.lin_reload = 0;
}

static void half(APU *a) {
    for (int i = 0; i < 2; i++) {
        if (!a->pu[i].halt && a->pu[i].len) a->pu[i].len--;
        uint16_t tgt = sweep_target(a, i);
        if (a->pu[i].sw_div == 0 && a->pu[i].sw_en && a->pu[i].sw_shift && a->pu[i].period >= 8 && tgt <= 0x7FF)
            a->pu[i].period = tgt;
        if (a->pu[i].sw_div == 0 || a->pu[i].sw_reload) { a->pu[i].sw_div = a->pu[i].sw_period; a->pu[i].sw_reload = 0; }
        else a->pu[i].sw_div--;
    }
    if (!a->tri.halt && a->tri.len) a->tri.len--;
    if (!a->noi.halt && a->noi.len) a->noi.len--;
}

static void dmc_fetch(NES *n) {
    APU *a = &n->apu;
    if (!a->dmc.buf_full && a->dmc.remaining) {
        a->dmc.buf = nes_dmc_read(n, a->dmc.cur_addr);
        a->dmc.buf_full = 1;
        a->dmc.cur_addr = a->dmc.cur_addr == 0xFFFF ? 0x8000 : (uint16_t)(a->dmc.cur_addr + 1);
        if (--a->dmc.remaining == 0) {
            if (a->dmc.loop) { a->dmc.cur_addr = a->dmc.addr; a->dmc.remaining = a->dmc.len; }
            else if (a->dmc.irq_en) a->dmc.irq = 1;
        }
    }
}

static inline float mix(APU *a) {
    int p[2];
    for (int i = 0; i < 2; i++) {
        int on = a->pu[i].len && a->pu[i].period >= 8 && sweep_target(a, i) <= 0x7FF && DUTY[a->pu[i].duty][a->pu[i].seq];
        p[i] = on ? (a->pu[i].const_vol ? a->pu[i].vol : a->pu[i].env_decay) : 0;
    }
    int t = TRI[a->tri.seq];
    if (a->tri.period < 2) t = 7; // ultrasonic: avoid pops
    int nz = (a->noi.len && !(a->noi.lfsr & 1)) ? (a->noi.const_vol ? a->noi.vol : a->noi.env_decay) : 0;
    int d = a->dmc.out;
    float po = (p[0] + p[1]) ? 95.88f / (8128.0f / (float)(p[0] + p[1]) + 100.0f) : 0.0f;
    float tn = (float)t / 8227.0f + (float)nz / 12241.0f + (float)d / 22638.0f;
    float to = tn > 0 ? 159.79f / (1.0f / tn + 100.0f) : 0.0f;
    return po + to;
}

static void push_sample(NES *n, float s) {
    APU *a = &n->apu;
    float rate = (float)(n->sample_rate ? n->sample_rate : 48000);
    // DC-blocking high-pass (~37 Hz) and gentle low-pass (~14 kHz)
    float rc_hp = 1.0f / (2.0f * 3.14159265f * 37.0f), dt = 1.0f / rate;
    float ahp = rc_hp / (rc_hp + dt);
    float hp = ahp * (a->hp1_prev_out + s - a->hp1_prev_in);
    a->hp1_prev_in = s; a->hp1_prev_out = hp;
    float rc_lp = 1.0f / (2.0f * 3.14159265f * 14000.0f);
    float alp = dt / (rc_lp + dt);
    a->lp_prev += alp * (hp - a->lp_prev);
    float L, R;
    synth_render(n, a->lp_prev * 1.6f, &L, &R);
    uint32_t next = (n->audio_w + 2) % AUDIO_BUF;
    if (next == n->audio_r) return; // overflow: drop
    n->audio[n->audio_w] = L;
    n->audio[n->audio_w + 1] = R;
    n->audio_w = next;
}

static void frame_tick(NES *n) {
    APU *a = &n->apu;
    const uint32_t *st = n->region == NES_REGION_PAL ? FSTEP_PAL : FSTEP_NTSC;
    a->frame_cycle++;
    uint32_t c = a->frame_cycle;
    if (c == st[0]) quarter(a);
    else if (c == st[1]) { quarter(a); half(a); }
    else if (c == st[2]) quarter(a);
    else if (!a->frame_mode && c == st[3]) {
        quarter(a); half(a);
        if (!a->frame_irq_inhibit) a->frame_irq = 1;
    } else if (!a->frame_mode && c >= st[3] + 1) {
        if (!a->frame_irq_inhibit) a->frame_irq = 1;
        a->frame_cycle = 0;
    } else if (a->frame_mode && c == st[4]) { quarter(a); half(a); }
    else if (a->frame_mode && c > st[4]) a->frame_cycle = 0;
}

static void apu_cycle(NES *n) {
    APU *a = &n->apu;
    frame_tick(n);
    // pulse + noise clocked on APU cycles (every other CPU cycle) for pulses
    if (a->cyc & 1) {
        for (int i = 0; i < 2; i++) {
            if (a->pu[i].timer == 0) { a->pu[i].timer = a->pu[i].period; a->pu[i].seq = (a->pu[i].seq + 7) & 7; }
            else a->pu[i].timer--;
        }
    }
    // triangle: every CPU cycle
    if (a->tri.timer == 0) { a->tri.timer = a->tri.period; if (a->tri.len && a->tri.lin) a->tri.seq = (a->tri.seq + 1) & 31; }
    else a->tri.timer--;
    // noise: period table in CPU cycles
    if (a->noi.timer == 0) {
        a->noi.timer = a->noi.period;
        uint16_t fb = (uint16_t)((a->noi.lfsr & 1) ^ ((a->noi.lfsr >> (a->noi.mode ? 6 : 1)) & 1));
        a->noi.lfsr = (uint16_t)((a->noi.lfsr >> 1) | (fb << 14));
    } else a->noi.timer--;
    // DMC
    if (a->dmc.timer == 0) {
        const uint16_t *rt = n->region == NES_REGION_PAL ? DMC_PAL : DMC_NTSC;
        a->dmc.timer = (uint16_t)(rt[a->dmc.rate_idx] - 1);
        if (!a->dmc.silence) {
            if (a->dmc.shift & 1) { if (a->dmc.out <= 125) a->dmc.out += 2; }
            else { if (a->dmc.out >= 2) a->dmc.out -= 2; }
        }
        a->dmc.shift >>= 1;
        if (--a->dmc.bits_left == 0) {
            a->dmc.bits_left = 8;
            if (a->dmc.buf_full) { a->dmc.shift = a->dmc.buf; a->dmc.buf_full = 0; a->dmc.silence = 0; dmc_fetch(n); }
            else a->dmc.silence = 1;
        }
    } else a->dmc.timer--;

    a->sum += mix(a); a->sum_n++;
    a->sample_acc += 1.0;
    if (a->sample_acc >= a->sample_step) {
        a->sample_acc -= a->sample_step;
        push_sample(n, a->sum / (float)a->sum_n);
        a->sum = 0; a->sum_n = 0;
    }
    a->cyc++;
}

void apu_sync(NES *n) {
    while (n->apu.cyc < n->cyc) apu_cycle(n);
    n->irq_line = n->apu.frame_irq || n->apu.dmc.irq;
}

void apu_write(NES *n, uint16_t addr, uint8_t v) {
    APU *a = &n->apu;
    switch (addr) {
        case 0x4000: case 0x4004: { int i = (addr >> 2) & 1;
            a->pu[i].duty = v >> 6; a->pu[i].halt = (v >> 5) & 1; a->pu[i].const_vol = (v >> 4) & 1; a->pu[i].vol = v & 15; break; }
        case 0x4001: case 0x4005: { int i = (addr >> 2) & 1;
            a->pu[i].sw_en = v >> 7; a->pu[i].sw_period = (v >> 4) & 7; a->pu[i].sw_neg = (v >> 3) & 1; a->pu[i].sw_shift = v & 7; a->pu[i].sw_reload = 1; break; }
        case 0x4002: case 0x4006: { int i = (addr >> 2) & 1; a->pu[i].period = (uint16_t)((a->pu[i].period & 0x700) | v); break; }
        case 0x4003: case 0x4007: { int i = (addr >> 2) & 1;
            a->pu[i].period = (uint16_t)((a->pu[i].period & 0xFF) | ((v & 7) << 8));
            if (a->pu[i].enabled) a->pu[i].len = LEN[v >> 3];
            a->pu[i].seq = 0; a->pu[i].env_start = 1; n->synth_trig[i] = 1; break; }
        case 0x4008: a->tri.halt = v >> 7; a->tri.lin_reload_val = v & 0x7F; break;
        case 0x400A: a->tri.period = (uint16_t)((a->tri.period & 0x700) | v); break;
        case 0x400B: a->tri.period = (uint16_t)((a->tri.period & 0xFF) | ((v & 7) << 8));
                     if (a->tri.enabled) a->tri.len = LEN[v >> 3];
                     a->tri.lin_reload = 1; n->synth_trig[2] = 1; break;
        case 0x400C: a->noi.halt = (v >> 5) & 1; a->noi.const_vol = (v >> 4) & 1; a->noi.vol = v & 15; break;
        case 0x400E: a->noi.mode = v >> 7; a->noi.pidx = v & 15; a->noi.period = (n->region == NES_REGION_PAL ? NOISE_PAL : NOISE_NTSC)[v & 15]; break;
        case 0x400F: if (a->noi.enabled) a->noi.len = LEN[v >> 3]; a->noi.env_start = 1; n->synth_trig[3] = 1; break;
        case 0x4010: a->dmc.irq_en = v >> 7; a->dmc.loop = (v >> 6) & 1; a->dmc.rate_idx = v & 15; if (!a->dmc.irq_en) a->dmc.irq = 0; break;
        case 0x4011: a->dmc.out = v & 0x7F; break;
        case 0x4012: a->dmc.addr = (uint16_t)(0xC000 + v * 64); break;
        case 0x4013: a->dmc.len = (uint16_t)(v * 16 + 1); break;
        case 0x4015:
            a->pu[0].enabled = v & 1; if (!(v & 1)) a->pu[0].len = 0;
            a->pu[1].enabled = (v >> 1) & 1; if (!(v & 2)) a->pu[1].len = 0;
            a->tri.enabled = (v >> 2) & 1; if (!(v & 4)) a->tri.len = 0;
            a->noi.enabled = (v >> 3) & 1; if (!(v & 8)) a->noi.len = 0;
            a->dmc.irq = 0;
            if (v & 0x10) { if (!a->dmc.remaining) { a->dmc.cur_addr = a->dmc.addr; a->dmc.remaining = a->dmc.len; dmc_fetch(n); } }
            else a->dmc.remaining = 0;
            break;
        case 0x4017:
            a->frame_mode = v >> 7; a->frame_irq_inhibit = (v >> 6) & 1;
            if (a->frame_irq_inhibit) a->frame_irq = 0;
            a->frame_cycle = 0;
            if (a->frame_mode) { quarter(a); half(a); }
            break;
    }
    n->irq_line = a->frame_irq || a->dmc.irq;
}

uint8_t apu_read_status(NES *n) {
    APU *a = &n->apu;
    uint8_t r = (uint8_t)((a->pu[0].len ? 1 : 0) | (a->pu[1].len ? 2 : 0) | (a->tri.len ? 4 : 0) | (a->noi.len ? 8 : 0) |
                          (a->dmc.remaining ? 0x10 : 0) | (a->frame_irq ? 0x40 : 0) | (a->dmc.irq ? 0x80 : 0));
    a->frame_irq = 0;
    n->irq_line = a->dmc.irq;
    return r;
}
