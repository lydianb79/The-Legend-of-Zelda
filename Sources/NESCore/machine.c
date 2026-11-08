// machine.c — bus, MMC1 mapper, controllers, run loop, save states.
#include "nes_internal.h"
#include <stdlib.h>
#include <stdio.h>

uint64_t ppu_next_line_cycle(NES *n);

static uint32_t crc32_buf(const uint8_t *d, size_t len) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        c ^= d[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1)));
    }
    return ~c;
}

// ---------------------------------------------------------------- MMC1
static void mmc1_update(NES *n) {
    uint8_t old0 = n->prg_bank[0];
    n->mirroring = n->m_ctrl & 3;
    uint8_t last = (uint8_t)(n->prg_banks - 1);
    uint8_t b = n->m_prg & 0x0F;
    switch ((n->m_ctrl >> 2) & 3) {
        case 0: case 1: n->prg_bank[0] = b & 0x0E; n->prg_bank[1] = (b & 0x0E) | 1; break;
        case 2: n->prg_bank[0] = 0; n->prg_bank[1] = b; break;
        default: n->prg_bank[0] = b; n->prg_bank[1] = last; break;
    }
    for (int i = 0; i < 2; i++) {
        n->prg_bank[i] %= n->prg_banks;
        n->prg_off[i] = (uint32_t)n->prg_bank[i] * 0x4000u;
    }
    if (n->m_ctrl & 0x10) { n->chr_off[0] = (uint32_t)(n->m_chr0 & 1) * 0x1000u; n->chr_off[1] = (uint32_t)(n->m_chr1 & 1) * 0x1000u; }
    else { n->chr_off[0] = 0; n->chr_off[1] = 0x1000; }
    if (n->prg_bank[0] != old0) n->next_event = 0; // leave the current recompiled block
}

static void mmc1_write(NES *n, uint16_t a, uint8_t v) {
    if (v & 0x80) { n->m_shift = 0; n->m_count = 0; n->m_ctrl |= 0x0C; mmc1_update(n); return; }
    n->m_shift |= (uint8_t)((v & 1) << n->m_count);
    if (++n->m_count == 5) {
        switch ((a >> 13) & 3) {
            case 0: n->m_ctrl = n->m_shift; break;
            case 1: n->m_chr0 = n->m_shift; break;
            case 2: n->m_chr1 = n->m_shift; break;
            case 3: n->m_prg = n->m_shift; break;
        }
        n->m_shift = 0; n->m_count = 0;
        mmc1_update(n);
    }
}

// ---------------------------------------------------------------- bus
uint8_t nes_dmc_read(NES *n, uint16_t a) {
    if (a >= 0x8000) return rd_prg(n, a);
    return 0;
}

uint8_t nes_read_io(NES *n, uint16_t a) {
    if (a < 0x4000) { ppu_sync(n); return ppu_read_reg(n, a); }
    if (a == 0x4015) { apu_sync(n); return apu_read_status(n); }
    if (a == 0x4016 || a == 0x4017) {
        int p = a & 1;
        if (n->strobe) return (uint8_t)(0x40 | (n->pad[p] & 1));
        uint8_t r = n->pad_shift[p] & 1;
        n->pad_shift[p] = (uint8_t)((n->pad_shift[p] >> 1) | 0x80);
        return (uint8_t)(0x40 | r);
    }
    return (uint8_t)(a >> 8); // open bus
}

void nes_write(NES *n, uint16_t a, uint8_t v) {
    if (a < 0x2000) { n->ram[a & 0x7FF] = v; return; }
    if (a < 0x4000) { ppu_sync(n); ppu_write_reg(n, a, v); return; }
    if (a >= 0x8000) { mmc1_write(n, a, v); return; }
    if (a >= 0x6000) { n->prgram[a & 0x1FFF] = v; return; }
    if (a == 0x4014) {
        ppu_sync(n);
        uint16_t base = (uint16_t)(v << 8);
        for (int i = 0; i < 256; i++) n->ppu.oam[(uint8_t)(n->ppu.oamaddr + i)] = nes_read(n, (uint16_t)(base + i));
        n->cyc += 513 + (n->cyc & 1);
        return;
    }
    if (a == 0x4016) {
        uint8_t s = v & 1;
        if (n->strobe && !s) { n->pad_shift[0] = n->pad[0]; n->pad_shift[1] = n->pad[1]; }
        n->strobe = s;
        if (s) { n->pad_shift[0] = n->pad[0]; n->pad_shift[1] = n->pad[1]; }
        return;
    }
    if (a <= 0x4017) { apu_sync(n); apu_write(n, a, v); return; }
}

// ---------------------------------------------------------------- run loop
static void interrupt(NES *n, uint16_t vec) {
    PUSH(n->pc >> 8); PUSH(n->pc & 0xFF); PUSH(GETP(0));
    n->fi = 1;
    n->pc = (uint16_t)(nes_read(n, vec) | (nes_read(n, (uint16_t)(vec + 1)) << 8));
    CYC(7);
}

void nes_service(NES *n) {
    ppu_sync(n);
    apu_sync(n);
    n->next_event = ppu_next_line_cycle(n);
    if (n->next_event <= n->cyc) n->next_event = n->cyc + 1;
}

static void record_miss(NES *n, uint16_t pc) {
    if (pc >= 0x6000 && pc < 0x8000) { n->miss_ram[(pc & 0x1FFF) >> 3] |= (uint8_t)(1 << (pc & 7)); return; }
    if (pc < 0x8000) return;
    int w = (pc >> 14) & 1;
    uint32_t bit = ((uint32_t)(n->prg_bank[w] & 15) * 2u + (uint32_t)w) * 16384u + (pc & 0x3FFF);
    n->miss_bits[bit >> 3] |= (uint8_t)(1 << (bit & 7));
}

void nes_run_frame(NES *n) {
    uint32_t f = n->ppu.frame;
    while (n->ppu.frame == f) {
        if (n->cyc >= n->next_event) { nes_service(n); if (n->ppu.frame != f) break; }
        if (n->nmi_pending) { n->nmi_pending = 0; interrupt(n, 0xFFFA); }
        else if (n->irq_line && !n->fi) interrupt(n, 0xFFFE);
#ifdef NES_TRACE
        if (n->ppu.frame >= 15 && n->ppu.frame <= 17) fprintf(stderr, "%04X a=%02X x=%02X y=%02X s=%02X P=%02X cyc=%llu\n", n->pc, n->a, n->x, n->y, n->s, GETP(0), (unsigned long long)n->cyc);
#endif
        recomp_fn fn = n->force_interp ? NULL : recomp_lookup(n, n->pc);
        if (fn) {
            fn(n); n->stat_recomp++;
            if (UNLIKELY(n->stale)) { n->stale = 0; record_miss(n, n->pc); cpu_interp_step(n); n->stat_interp++; }
        }
        else { record_miss(n, n->pc); cpu_interp_step(n); n->stat_interp++; }
    }
    apu_sync(n);
}

// ---------------------------------------------------------------- setup
static void apply_region(NES *n) {
    if (n->region == NES_REGION_PAL) { n->cpu_div = 16; n->ppu_div = 5; n->lines = 312; n->frame_rate = 26601712.0 / (312.0 * 341.0 * 5.0); }
    else { n->cpu_div = 12; n->ppu_div = 4; n->lines = 262; n->frame_rate = 21477272.0 / (262.0 * 341.0 * 4.0 - 2.0); }
    n->vbl_line = 241;
    if (n->ppu.scanline >= n->lines) n->ppu.scanline = 0;
    // keep PPU master clock consistent with the CPU clock under the new dividers
    n->ppu.master = n->cyc * (uint64_t)n->cpu_div;
    n->apu.sample_step = (n->region == NES_REGION_PAL ? 26601712.0 / 16.0 : 21477272.0 / 12.0) / (double)n->sample_rate;
    n->next_event = 0;
}

NES *nes_create(const uint8_t *rom, size_t size, const char **err) {
    static const char *e_hdr = "Not an iNES ROM", *e_map = "Unsupported mapper (only MMC1 / mapper 1 supported)", *e_size = "ROM truncated";
    if (size < 16 || memcmp(rom, "NES\x1A", 4) != 0) { if (err) *err = e_hdr; return NULL; }
    int mapper = (rom[6] >> 4) | (rom[7] & 0xF0);
    int nes2 = (rom[7] & 0x0C) == 0x08;
    if (nes2) mapper |= (rom[8] & 0x0F) << 8;
    if (mapper != 1) { if (err) *err = e_map; return NULL; }
    size_t prg = (size_t)rom[4] * 16384, chr = (size_t)rom[5] * 8192;
    size_t off = 16 + ((rom[6] & 4) ? 512 : 0);
    if (size < off + prg + chr || prg == 0) { if (err) *err = e_size; return NULL; }

    NES *n = (NES *)calloc(1, sizeof(NES));
    n->rom_copy = (uint8_t *)malloc(prg);
    memcpy(n->rom_copy, rom + off, prg);
    n->prg = n->rom_copy; n->prg_size = (uint32_t)prg; n->prg_banks = (uint8_t)rom[4];
    if (chr) memcpy(n->chr, rom + off + prg, chr > 8192 ? 8192 : chr);
    n->has_battery = (rom[6] & 2) != 0;
    n->rom_crc = crc32_buf(n->prg, prg);
    n->sample_rate = 48000;
    n->synth = synth_create();
    int pal = nes2 ? (rom[12] & 3) == 1 : (rom[9] & 1);
    n->region = pal ? NES_REGION_PAL : NES_REGION_NTSC;
    apply_region(n);
    nes_reset(n, 1);
    return n;
}

void nes_destroy(NES *n) { if (!n) return; synth_destroy(n->synth); free(n->rom_copy); free(n); }

void nes_reset(NES *n, int hard) {
    if (hard) {
        memset(n->ram, 0, sizeof(n->ram));
        memset(n->ppu.oam, 0xFF, sizeof(n->ppu.oam));
        memset(n->ppu.vram, 0, sizeof(n->ppu.vram));
        n->a = n->x = n->y = 0; n->s = 0;
        n->cyc = 0;
    }
    n->m_shift = 0; n->m_count = 0; n->m_ctrl = 0x0C; n->m_prg = 0; n->m_chr0 = 0; n->m_chr1 = 0;
    mmc1_update(n);
    ppu_reset(n);
    n->ppu.master = n->cyc * (uint64_t)n->cpu_div;
    apu_reset(n);
    n->apu.cyc = n->cyc;
    n->s = (uint8_t)(n->s - 3);
    n->fi = 1; n->fd = 0; n->fc = 0; n->fv = 0; n->fn = 0; n->fz = 1;
    n->pc = (uint16_t)(nes_read(n, 0xFFFC) | (nes_read(n, 0xFFFD) << 8));
    n->cyc += 7;
    n->nmi_pending = 0; n->nmi_line_prev = 0; n->irq_line = 0;
    n->next_event = 0;
    n->audio_r = n->audio_w = 0;
}

void nes_set_region(NES *n, int region) { if (n->region != region) { n->region = region; apply_region(n); } }
int nes_get_region(const NES *n) { return n->region; }
double nes_frame_rate(const NES *n) { return n->frame_rate; }

void nes_set_buttons(NES *n, int port, uint8_t mask) {
    if (port < 0 || port > 1) return;
    // disallow opposing directions (the game misbehaves with L+R / U+D)
    if ((mask & (NES_BTN_LEFT | NES_BTN_RIGHT)) == (NES_BTN_LEFT | NES_BTN_RIGHT)) mask &= (uint8_t)~(NES_BTN_LEFT | NES_BTN_RIGHT);
    if ((mask & (NES_BTN_UP | NES_BTN_DOWN)) == (NES_BTN_UP | NES_BTN_DOWN)) mask &= (uint8_t)~(NES_BTN_UP | NES_BTN_DOWN);
    n->pad[port] = mask;
}

const uint32_t *nes_framebuffer(const NES *n) { return n->fb; }

void nes_set_sample_rate(NES *n, int rate) {
    if (rate < 8000) rate = 8000;
    n->sample_rate = rate;
    n->apu.sample_step = (n->region == NES_REGION_PAL ? 26601712.0 / 16.0 : 21477272.0 / 12.0) / (double)rate;
}

size_t nes_read_audio(NES *n, float *dst, size_t max_frames) {
    size_t k = 0;
    while (k < max_frames && n->audio_r != n->audio_w) {
        dst[2 * k] = n->audio[n->audio_r];
        dst[2 * k + 1] = n->audio[n->audio_r + 1];
        n->audio_r = (n->audio_r + 2) % AUDIO_BUF;
        k++;
    }
    return k;
}

void nes_set_audio_mode(NES *n, int mode, int style, float reverb, float width, float chip_blend, float bass_boost) {
    if (n->synth) synth_configure(n->synth, mode, style, reverb, width, chip_blend, bass_boost);
}

int nes_has_battery(const NES *n) { return n->has_battery; }
uint8_t *nes_prg_ram(NES *n) { return n->prgram; }
size_t nes_prg_ram_size(void) { return 8192; }
const uint8_t *nes_cpu_ram(const NES *n) { return n->ram; }
const uint8_t *nes_oam(const NES *n) { return n->ppu.oam; }
const uint8_t *nes_palette_ram(const NES *n) { return n->ppu.pal; }
int nes_split_line(const NES *n) { return n->ppu.last_s0_line; }

#define STATE_MAGIC 0x5A4C4452u /* 'ZLDR' */
#define STATE_VERSION 2u
size_t nes_state_size(void) { return 8 + offsetof(NES, state_end_marker); }
void nes_save_state(const NES *n, void *dst) {
    uint32_t hdr[2] = { STATE_MAGIC, STATE_VERSION };
    memcpy(dst, hdr, 8);
    memcpy((uint8_t *)dst + 8, n, offsetof(NES, state_end_marker));
}
int nes_load_state(NES *n, const void *src, size_t size) {
    uint32_t hdr[2];
    if (size != nes_state_size()) return 0;
    memcpy(hdr, src, 8);
    if (hdr[0] != STATE_MAGIC || hdr[1] != STATE_VERSION) return 0;
    int region = n->region;
    memcpy(n, (const uint8_t *)src + 8, offsetof(NES, state_end_marker));
    n->audio_r = n->audio_w = 0;
    if (n->region != region) apply_region(n);
    n->next_event = 0;
    return 1;
}

uint32_t nes_rom_crc(const NES *n) { return n->rom_crc; }
void nes_set_force_interpreter(NES *n, int on) { n->force_interp = (uint8_t)(on != 0); }
uint64_t nes_stat_recomp_instructions(const NES *n) { return n->stat_recomp; }
uint64_t nes_stat_interp_instructions(const NES *n) { return n->stat_interp; }

size_t nes_dump_misses(const NES *n, char *dst, size_t cap) {
    size_t w = 0;
    for (uint32_t bit = 0; bit < 16u * 2u * 16384u; bit++) {
        if (!(n->miss_bits[bit >> 3] & (1 << (bit & 7)))) continue;
        uint32_t bank = bit / (2u * 16384u), win = (bit / 16384u) & 1u, off = bit & 0x3FFFu;
        char line[32];
        int k = snprintf(line, sizeof line, "%u %u %04X\n", bank, win, 0x8000u + win * 0x4000u + off);
        if (w + (size_t)k >= cap) break;
        memcpy(dst + w, line, (size_t)k); w += (size_t)k;
    }
    for (uint32_t a = 0; a < 8192; a++) {
        if (!(n->miss_ram[a >> 3] & (1 << (a & 7)))) continue;
        char line[32];
        int k = snprintf(line, sizeof line, "0 2 %04X\n", 0x6000u + a);
        if (w + (size_t)k >= cap) break;
        memcpy(dst + w, line, (size_t)k); w += (size_t)k;
    }
    if (w < cap) dst[w] = 0;
    return w;
}
