// nes_internal.h — machine state and shared 6502 operation macros.
// Both the interpreter (cpu.c) and the generated recompiled code include this
// so they share exactly the same instruction semantics and timing.
#ifndef NES_INTERNAL_H
#define NES_INTERNAL_H

#include "include/nescore.h"
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define NES_INLINE static inline __attribute__((always_inline))
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define NES_INLINE static inline
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#endif

typedef struct {
    // registers
    uint8_t ctrl, mask, status, oamaddr;
    uint16_t v, t; uint8_t x, w;
    uint8_t readbuf, openbus;
    // timing
    int scanline, dot;            // scanline: 0..lines-1 (prerender = lines-1)
    uint32_t frame;
    int16_t s0_line, last_s0_line;  // scanline of sprite-0 hit this frame / last completed frame (-1 none)
    uint64_t master;              // master clocks consumed by PPU
    // background pipeline
    uint16_t bg_lo, bg_hi, at_lo, at_hi;
    uint8_t nt_latch, at_latch, pt_lo_latch, pt_hi_latch;
    // sprites for current line
    uint8_t spr_count;
    uint8_t spr_x[8], spr_attr[8], spr_lo[8], spr_hi[8];
    uint8_t spr_zero_in_line;
    // memory
    uint8_t oam[256];
    uint8_t vram[2048];
    uint8_t pal[32];
} PPU;

typedef struct {
    // pulse 1/2
    struct { uint8_t enabled, duty, seq, len, halt, const_vol, vol, env_start, env_div, env_decay,
             sw_en, sw_period, sw_neg, sw_shift, sw_reload, sw_div; uint16_t timer, period; } pu[2];
    struct { uint8_t enabled, len, halt, lin_reload_val, lin, lin_reload, seq; uint16_t timer, period; } tri;
    struct { uint8_t enabled, len, halt, const_vol, vol, env_start, env_div, env_decay, mode, pidx;
             uint16_t timer, period, lfsr; } noi;
    struct { uint8_t enabled, irq_en, loop, out, rate_idx, bits_left, shift, buf, buf_full, silence, irq;
             uint16_t timer, addr, cur_addr, len, remaining; } dmc;
    uint8_t frame_mode, frame_irq_inhibit, frame_irq;
    uint32_t frame_cycle;
    uint64_t cyc;                 // APU synced up to this CPU cycle
    // resampling
    double sample_acc, sample_step; float sum; uint32_t sum_n;
    float hp1_prev_in, hp1_prev_out, hp2_prev_in, hp2_prev_out, lp_prev;
} APU;

#define AUDIO_BUF 32768   /* interleaved stereo floats */
typedef struct Synth Synth;

struct NES {
    // ---------------- serialisable state (save states) ----------------
    uint8_t a, x, y, s;
    uint8_t fc, fz, fn, fv, fi, fd;    // fz: value whose zero-ness is Z; fn: bit7 is N
    uint16_t pc;
    uint64_t cyc, next_event;
    uint8_t nmi_pending, nmi_line_prev, irq_line;
    uint8_t ram[2048];
    uint8_t prgram[8192];
    uint8_t chr[8192];
    // MMC1
    uint8_t m_shift, m_count, m_ctrl, m_chr0, m_chr1, m_prg;
    uint32_t prg_off[2];      // byte offsets into PRG for $8000 / $C000 windows
    uint8_t prg_bank[2];      // 16K bank index mapped at each window
    uint32_t chr_off[2];
    uint8_t mirroring;        // 0 one-lo,1 one-hi,2 vertical,3 horizontal
    // input
    uint8_t pad[2], pad_shift[2], strobe;
    PPU ppu;
    APU apu;
    int region;
    uint8_t state_end_marker;
    // ---------------- non-serialised ----------------
    const uint8_t *prg; uint32_t prg_size; uint8_t prg_banks; uint8_t has_battery;
    uint8_t *rom_copy;
    uint32_t rom_crc;
    int cpu_div, ppu_div, lines, vbl_line;  // master clock dividers / frame geometry
    double frame_rate;
    int sample_rate;
    uint32_t fb[NES_W * NES_H];
    float audio[AUDIO_BUF]; uint32_t audio_w, audio_r;
    Synth *synth;              // remastered audio engine (synth.c)
    uint8_t synth_trig[4];     // note-on flags per channel (pulse1, pulse2, triangle, noise)
    uint8_t force_interp;
    uint64_t stat_recomp, stat_interp;
    uint8_t miss_bits[16 * 2 * 16384 / 8];   // [bank][window][addr] bitmap of interpreted ROM code
    uint8_t miss_ram[8192 / 8];               // interpreted PRG-RAM code
    uint8_t stale;                            // set by a RAM-overlay block whose source bytes changed
};

// ---------------- bus ----------------
uint8_t nes_read_io(NES *n, uint16_t a);
void nes_write(NES *n, uint16_t a, uint8_t v);
void ppu_sync(NES *n);
void apu_sync(NES *n);
void apu_write(NES *n, uint16_t a, uint8_t v);
uint8_t apu_read_status(NES *n);
void apu_reset(NES *n);
void ppu_reset(NES *n);
void ppu_write_reg(NES *n, uint16_t a, uint8_t v);
uint8_t ppu_read_reg(NES *n, uint16_t a);
void nes_service(NES *n);
void cpu_interp_step(NES *n);
uint8_t nes_dmc_read(NES *n, uint16_t a);
Synth *synth_create(void);
void synth_destroy(Synth *s);
void synth_configure(Synth *s, int mode, int style, float reverb, float width, float chip_blend, float bass_boost);
void synth_render(NES *n, float orig, float *outL, float *outR);

NES_INLINE uint8_t rd_prg(NES *n, uint16_t a) {
    return n->prg[n->prg_off[(a >> 14) & 1] + (a & 0x3FFF)];
}

NES_INLINE uint8_t nes_read(NES *n, uint16_t a) {
    if (a < 0x2000) return n->ram[a & 0x7FF];
    if (a >= 0x8000) return rd_prg(n, a);
    if (a >= 0x6000) return n->prgram[a & 0x1FFF];
    return nes_read_io(n, a);
}

// ---------------- recompiled code dispatch ----------------
typedef void (*recomp_fn)(NES *);
recomp_fn recomp_lookup(NES *n, uint16_t pc);
#define RAM_GUARD(off, bytes, len) do { if (UNLIKELY(memcmp(&n->prgram[(off)], (bytes), (len)) != 0)) { n->stale = 1; return; } } while (0)

// ---------------- shared 6502 operation macros ----------------
// Convention: an instruction first adds its cycle count (incl. penalties),
// then performs its memory accesses. I/O syncs therefore see end-of-instruction time.

#define RAM(a)        (n->ram[(a) & 0x7FF])
#define RD(a)         nes_read(n, (uint16_t)(a))
#define WR(a, v)      nes_write(n, (uint16_t)(a), (uint8_t)(v))
#define ZP(a)         (n->ram[(uint8_t)(a)])
#define SETNZ(v)      do { uint8_t _nz_ = (uint8_t)(v); n->fn = _nz_; n->fz = _nz_; } while (0)
#define CYC(k)        (n->cyc += (k))
#define PUSH(v)       do { n->ram[0x100 | n->s] = (uint8_t)(v); n->s--; } while (0)
#define PULL()        (n->s++, n->ram[0x100 | n->s])
#define GETP(b)       (uint8_t)(((n->fn) & 0x80) | (n->fv ? 0x40 : 0) | 0x20 | ((b) ? 0x10 : 0) | \
                       (n->fd ? 0x08 : 0) | (n->fi ? 0x04 : 0) | (n->fz == 0 ? 0x02 : 0) | (n->fc ? 1 : 0))
#define SETP(p)       do { uint8_t _sp_ = (p); n->fn = _sp_ & 0x80; n->fv = (_sp_ >> 6) & 1; n->fd = (_sp_ >> 3) & 1; \
                           n->fi = (_sp_ >> 2) & 1; n->fz = (_sp_ & 2) ? 0 : 1; n->fc = _sp_ & 1; } while (0)

#define OP_LDA(v)  do { n->a = (v); SETNZ(n->a); } while (0)
#define OP_LDX(v)  do { n->x = (v); SETNZ(n->x); } while (0)
#define OP_LDY(v)  do { n->y = (v); SETNZ(n->y); } while (0)
#define OP_ADC(v)  do { uint8_t _v = (v); unsigned _s = (unsigned)n->a + _v + n->fc; \
                        n->fv = ((~(n->a ^ _v) & (n->a ^ _s)) & 0x80) != 0; n->fc = _s > 0xFF; \
                        n->a = (uint8_t)_s; SETNZ(n->a); } while (0)
#define OP_SBC(v)  OP_ADC((uint8_t)~(v))
#define OP_AND(v)  do { n->a &= (v); SETNZ(n->a); } while (0)
#define OP_ORA(v)  do { n->a |= (v); SETNZ(n->a); } while (0)
#define OP_EOR(v)  do { n->a ^= (v); SETNZ(n->a); } while (0)
#define OP_CMPR(r, v) do { uint8_t _v = (v); unsigned _d = (unsigned)(r) - _v; n->fc = (r) >= _v; SETNZ(_d); } while (0)
#define OP_BIT(v)  do { uint8_t _v = (v); n->fn = _v; n->fv = (_v >> 6) & 1; n->fz = n->a & _v; } while (0)
#define F_ASL(v)   ({ uint8_t _v = (v); n->fc = _v >> 7; _v <<= 1; SETNZ(_v); _v; })
#define F_LSR(v)   ({ uint8_t _v = (v); n->fc = _v & 1; _v >>= 1; SETNZ(_v); _v; })
#define F_ROL(v)   ({ uint8_t _v = (v); uint8_t _c = n->fc; n->fc = _v >> 7; _v = (uint8_t)((_v << 1) | _c); SETNZ(_v); _v; })
#define F_ROR(v)   ({ uint8_t _v = (v); uint8_t _c = n->fc; n->fc = _v & 1; _v = (uint8_t)((_v >> 1) | (_c << 7)); SETNZ(_v); _v; })
#define F_INC(v)   ({ uint8_t _v = (uint8_t)((v) + 1); SETNZ(_v); _v; })
#define F_DEC(v)   ({ uint8_t _v = (uint8_t)((v) - 1); SETNZ(_v); _v; })

#define COND_BCC (!n->fc)
#define COND_BCS (n->fc)
#define COND_BNE (n->fz != 0)
#define COND_BEQ (n->fz == 0)
#define COND_BPL (!(n->fn & 0x80))
#define COND_BMI (n->fn & 0x80)
#define COND_BVC (!n->fv)
#define COND_BVS (n->fv)

#define PAGECROSS(base, idx) ((((base) & 0xFF) + (idx)) > 0xFF)

#endif
