// ppu.c — dot-stepped 2C02/2C07 PPU with layer-separated output for the
// enhanced Metal renderer (background and sprite layers are kept apart so the
// GPU can light them, cast sprite shadows, etc.).
#include "nes_internal.h"

void ppu_reset(NES *n) {
    PPU *p = &n->ppu;
    uint8_t oam[256]; memcpy(oam, p->oam, 256);
    memset(p, 0, sizeof(*p));
    memcpy(p->oam, oam, 256);
    p->scanline = 0; p->dot = 0;
    p->s0_line = p->last_s0_line = -1;
    static const uint8_t boot_pal[32] = {
        0x09,0x01,0x00,0x01,0x00,0x02,0x02,0x0D,0x08,0x10,0x08,0x24,0x00,0x00,0x04,0x2C,
        0x09,0x01,0x34,0x03,0x00,0x04,0x00,0x14,0x08,0x3A,0x00,0x02,0x00,0x20,0x2C,0x08 };
    memcpy(p->pal, boot_pal, 32);
}

NES_INLINE uint16_t nt_index(NES *n, uint16_t a) {
    switch (n->mirroring) {
        case 0: return a & 0x3FF;
        case 1: return 0x400 | (a & 0x3FF);
        case 2: return a & 0x7FF;
        default: return ((a >> 1) & 0x400) | (a & 0x3FF);
    }
}

NES_INLINE uint8_t chr_read(NES *n, uint16_t a) {
    return n->chr[(n->chr_off[(a >> 12) & 1] + (a & 0xFFF)) & 0x1FFF];
}

NES_INLINE uint8_t pal_index(uint16_t a) {
    a &= 0x1F;
    if ((a & 0x13) == 0x10) a &= 0x0F;
    return (uint8_t)a;
}

static uint8_t ppu_mem_read(NES *n, uint16_t a) {
    a &= 0x3FFF;
    if (a < 0x2000) return chr_read(n, a);
    if (a < 0x3F00) return n->ppu.vram[nt_index(n, a)];
    return n->ppu.pal[pal_index(a)];
}

static void ppu_mem_write(NES *n, uint16_t a, uint8_t v) {
    a &= 0x3FFF;
    if (a < 0x2000) { n->chr[(n->chr_off[(a >> 12) & 1] + (a & 0xFFF)) & 0x1FFF] = v; return; }
    if (a < 0x3F00) { n->ppu.vram[nt_index(n, a)] = v; return; }
    n->ppu.pal[pal_index(a)] = v & 0x3F;
}

static void update_nmi(NES *n) {
    uint8_t line = (n->ppu.status & 0x80) && (n->ppu.ctrl & 0x80);
    if (line && !n->nmi_line_prev) { n->nmi_pending = 1; n->next_event = 0; }
    n->nmi_line_prev = line;
}

uint8_t ppu_read_reg(NES *n, uint16_t a) {
    PPU *p = &n->ppu;
    uint8_t r = p->openbus;
    switch (a & 7) {
        case 2:
            r = (uint8_t)((p->status & 0xE0) | (p->openbus & 0x1F));
            p->status &= 0x7F; p->w = 0;
            update_nmi(n);
            break;
        case 4: r = p->oam[p->oamaddr]; break;
        case 7: {
            uint16_t addr = p->v & 0x3FFF;
            if (addr >= 0x3F00) { r = (uint8_t)((p->openbus & 0xC0) | ppu_mem_read(n, addr)); p->readbuf = ppu_mem_read(n, addr - 0x1000); }
            else { r = p->readbuf; p->readbuf = ppu_mem_read(n, addr); }
            p->v = (uint16_t)((p->v + ((p->ctrl & 0x04) ? 32 : 1)) & 0x7FFF);
            break;
        }
        default: break;
    }
    p->openbus = r;
    return r;
}

void ppu_write_reg(NES *n, uint16_t a, uint8_t v) {
    PPU *p = &n->ppu;
    p->openbus = v;
    switch (a & 7) {
        case 0: p->ctrl = v; p->t = (uint16_t)((p->t & 0xF3FF) | ((v & 3) << 10)); update_nmi(n); break;
        case 1: p->mask = v; break;
        case 3: p->oamaddr = v; break;
        case 4: p->oam[p->oamaddr++] = v; break;
        case 5:
            if (!p->w) { p->t = (uint16_t)((p->t & 0xFFE0) | (v >> 3)); p->x = v & 7; p->w = 1; }
            else { p->t = (uint16_t)((p->t & 0x8C1F) | ((v & 0xF8) << 2) | ((v & 7) << 12)); p->w = 0; }
            break;
        case 6:
            if (!p->w) { p->t = (uint16_t)((p->t & 0x00FF) | ((v & 0x3F) << 8)); p->w = 1; }
            else { p->t = (uint16_t)((p->t & 0xFF00) | v); p->v = p->t; p->w = 0; }
            break;
        case 7:
            ppu_mem_write(n, p->v, v);
            p->v = (uint16_t)((p->v + ((p->ctrl & 0x04) ? 32 : 1)) & 0x7FFF);
            break;
    }
}

// ---------------------------------------------------------------- rendering
NES_INLINE void inc_x(PPU *p) {
    if ((p->v & 0x1F) == 31) { p->v &= (uint16_t)~0x1F; p->v ^= 0x400; } else p->v++;
}
NES_INLINE void inc_y(PPU *p) {
    if ((p->v & 0x7000) != 0x7000) { p->v += 0x1000; return; }
    p->v &= (uint16_t)~0x7000;
    int y = (p->v & 0x3E0) >> 5;
    if (y == 29) { y = 0; p->v ^= 0x800; } else if (y == 31) y = 0; else y++;
    p->v = (uint16_t)((p->v & ~0x3E0) | (y << 5));
}
NES_INLINE void load_bg(PPU *p) {
    p->bg_lo = (uint16_t)((p->bg_lo & 0xFF00) | p->pt_lo_latch);
    p->bg_hi = (uint16_t)((p->bg_hi & 0xFF00) | p->pt_hi_latch);
    p->at_lo = (uint16_t)((p->at_lo & 0xFF00) | ((p->at_latch & 1) ? 0xFF : 0));
    p->at_hi = (uint16_t)((p->at_hi & 0xFF00) | ((p->at_latch & 2) ? 0xFF : 0));
}

static void eval_sprites(NES *n, int line) {
    PPU *p = &n->ppu;
    int h = (p->ctrl & 0x20) ? 16 : 8;
    p->spr_count = 0; p->spr_zero_in_line = 0;
    for (int i = 0; i < 64; i++) {
        int diff = line - p->oam[i * 4];
        if (diff < 0 || diff >= h) continue;
        if (p->spr_count == 8) { p->status |= 0x20; break; }
        uint8_t tile = p->oam[i * 4 + 1], attr = p->oam[i * 4 + 2];
        int row = (attr & 0x80) ? (h - 1 - diff) : diff;
        uint16_t addr;
        if (h == 16) addr = (uint16_t)(((tile & 1) << 12) | ((tile & 0xFE) << 4) | ((row & 8) << 1) | (row & 7));
        else addr = (uint16_t)(((p->ctrl & 0x08) << 9) | (tile << 4) | row);
        uint8_t lo = chr_read(n, addr), hi = chr_read(n, (uint16_t)(addr + 8));
        if (attr & 0x40) { // horizontal flip: reverse bits
            lo = (uint8_t)(((lo * 0x0802LU & 0x22110LU) | (lo * 0x8020LU & 0x88440LU)) * 0x10101LU >> 16);
            hi = (uint8_t)(((hi * 0x0802LU & 0x22110LU) | (hi * 0x8020LU & 0x88440LU)) * 0x10101LU >> 16);
        }
        int k = p->spr_count++;
        p->spr_x[k] = p->oam[i * 4 + 3]; p->spr_attr[k] = attr; p->spr_lo[k] = lo; p->spr_hi[k] = hi;
        if (i == 0) p->spr_zero_in_line = 1;
    }
}

static void output_pixel(NES *n, int x, int y) {
    PPU *p = &n->ppu;
    uint8_t bgpx = 0, bgpal = 0;
    if ((p->mask & 0x08) && (x >= 8 || (p->mask & 0x02))) {
        uint16_t bit = (uint16_t)(0x8000 >> p->x);
        bgpx = (uint8_t)(((p->bg_lo & bit) ? 1 : 0) | ((p->bg_hi & bit) ? 2 : 0));
        bgpal = (uint8_t)(((p->at_lo & bit) ? 1 : 0) | ((p->at_hi & bit) ? 2 : 0));
    }
    uint8_t sppx = 0, sppal = 0, spbehind = 0, spzero = 0;
    if ((p->mask & 0x10) && (x >= 8 || (p->mask & 0x04))) {
        for (int k = 0; k < p->spr_count; k++) {
            int d = x - p->spr_x[k];
            if (d < 0 || d > 7) continue;
            uint8_t px = (uint8_t)(((p->spr_lo[k] >> (7 - d)) & 1) | (((p->spr_hi[k] >> (7 - d)) & 1) << 1));
            if (!px) continue;
            sppx = px; sppal = (uint8_t)((p->spr_attr[k] & 3) + 4); spbehind = (p->spr_attr[k] >> 5) & 1;
            spzero = (k == 0 && p->spr_zero_in_line);
            break;
        }
    }
    if (spzero && bgpx && x != 255 && !(p->status & 0x40)) { p->status |= 0x40; p->s0_line = (int16_t)y; }

    uint8_t gray = (p->mask & 0x01) ? 0x30 : 0x3F;
    uint8_t backdrop = p->pal[0] & gray;
    uint8_t bgc = bgpx ? (p->pal[(bgpal << 2) | bgpx] & gray) : backdrop;
    uint8_t spc = sppx ? (p->pal[(sppal << 2) | sppx] & gray) : 0;
    uint8_t fin;
    if (!bgpx && !sppx) fin = backdrop;
    else if (!bgpx) fin = spc;
    else if (!sppx) fin = bgc;
    else fin = spbehind ? bgc : spc;

    uint32_t b1 = (uint32_t)(bgc | (bgpx ? 0x80 : 0));
    uint32_t b2 = (uint32_t)(spc | (sppx ? 0x80 : 0) | (spbehind ? 0x40 : 0));
    uint32_t b3 = (uint32_t)(((p->mask >> 5) & 7) | ((p->mask & 1) << 3) | (spzero ? 0x10 : 0) | (sppx ? ((sppal - 4) << 5) : 0));
    n->fb[y * NES_W + x] = fin | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

static void ppu_dot(NES *n) {
    PPU *p = &n->ppu;
    int line = p->scanline, dot = p->dot;
    int pre = (line == n->lines - 1);
    int vis = line < 240;
    int ren = (p->mask & 0x18) != 0;

    if (vis || pre) {
        if (pre && dot == 1) { p->status &= 0x1F; update_nmi(n); }
        if (ren) {
            if ((dot >= 2 && dot < 258) || (dot >= 321 && dot < 338)) {
                p->bg_lo <<= 1; p->bg_hi <<= 1; p->at_lo <<= 1; p->at_hi <<= 1;
                switch ((dot - 1) & 7) {
                    case 0: load_bg(p); p->nt_latch = ppu_mem_read(n, (uint16_t)(0x2000 | (p->v & 0x0FFF))); break;
                    case 2: {
                        uint8_t at = ppu_mem_read(n, (uint16_t)(0x23C0 | (p->v & 0x0C00) | ((p->v >> 4) & 0x38) | ((p->v >> 2) & 0x07)));
                        if (p->v & 0x40) at >>= 4;
                        if (p->v & 0x02) at >>= 2;
                        p->at_latch = at & 3; break;
                    }
                    case 4: p->pt_lo_latch = chr_read(n, (uint16_t)(((p->ctrl & 0x10) << 8) + p->nt_latch * 16 + ((p->v >> 12) & 7))); break;
                    case 6: p->pt_hi_latch = chr_read(n, (uint16_t)(((p->ctrl & 0x10) << 8) + p->nt_latch * 16 + ((p->v >> 12) & 7) + 8)); break;
                    case 7: inc_x(p); break;
                }
            }
            if (dot == 256) inc_y(p);
            if (dot == 257) { load_bg(p); p->v = (uint16_t)((p->v & ~0x041F) | (p->t & 0x041F)); }
            if (pre && dot >= 280 && dot <= 304) p->v = (uint16_t)((p->v & ~0x7BE0) | (p->t & 0x7BE0));
        }
        if (dot == 257) {
            if (vis && ren) eval_sprites(n, line);
            else p->spr_count = 0;
        }
        if (vis && dot >= 1 && dot <= 256) output_pixel(n, dot - 1, line);
    }

    if (line == n->vbl_line && dot == 1) {
        p->status |= 0x80;
        p->frame++;
        p->last_s0_line = p->s0_line; p->s0_line = -1;
        n->next_event = 0;   // end of frame: make recompiled blocks yield to the frame loop
        update_nmi(n);
    }

    // advance
    p->dot++;
    if (pre && dot == 339 && n->region == NES_REGION_NTSC && (p->frame & 1) && ren) p->dot = 341; // odd-frame skip
    if (p->dot > 340) {
        p->dot = 0;
        p->scanline++;
        if (p->scanline >= n->lines) p->scanline = 0;
    }
}

void ppu_sync(NES *n) {
    uint64_t target = n->cyc * (uint64_t)n->cpu_div;
    PPU *p = &n->ppu;
    while (p->master + (uint64_t)n->ppu_div <= target) {
        ppu_dot(n);
        p->master += (uint64_t)n->ppu_div;
    }
}

// Cycles until the PPU reaches the start of the next scanline.
uint64_t ppu_next_line_cycle(NES *n) {
    PPU *p = &n->ppu;
    // next occurrence of dot 2 (just after vblank/flag changes at dot 1)
    int dots = (p->dot < 2) ? (2 - p->dot) : (341 - p->dot + 2);
    uint64_t m = p->master + (uint64_t)dots * (uint64_t)n->ppu_div;
    return (m + (uint64_t)n->cpu_div - 1) / (uint64_t)n->cpu_div;
}
