// nescore.h — public C API of the Zelda recomp runtime.
// The runtime hosts statically recompiled 6502 code (generated from the
// user's own ROM by Tools/recompile.py) plus an interpreter fallback.
#ifndef NESCORE_H
#define NESCORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NES NES;

enum {
    NES_BTN_A = 0x01, NES_BTN_B = 0x02, NES_BTN_SELECT = 0x04, NES_BTN_START = 0x08,
    NES_BTN_UP = 0x10, NES_BTN_DOWN = 0x20, NES_BTN_LEFT = 0x40, NES_BTN_RIGHT = 0x80
};

enum { NES_REGION_NTSC = 0, NES_REGION_PAL = 1 };

#define NES_W 256
#define NES_H 240

/// Create a machine from an iNES / NES 2.0 image. Returns NULL on unsupported ROMs.
/// `err` (optional) receives a static error string.
NES *nes_create(const uint8_t *rom, size_t size, const char **err);
void nes_destroy(NES *n);
void nes_reset(NES *n, int hard);

/// Region timing. Default comes from the ROM header. Changing it resets timing only.
void nes_set_region(NES *n, int region);
int  nes_get_region(const NES *n);
double nes_frame_rate(const NES *n);

/// Emulate exactly one video frame (until the start of the next vblank).
void nes_run_frame(NES *n);

void nes_set_buttons(NES *n, int port, uint8_t mask);

/// Per-pixel packed layer data, 256x240 uint32 (little endian bytes):
///  byte0: final composited palette index (0-63)
///  byte1: background colour index | 0x80 if BG pixel opaque
///  byte2: sprite colour index | 0x80 if sprite opaque | 0x40 if sprite behind BG
///  byte3: PPUMASK emphasis bits (bits 0-2) | 0x08 grayscale | 0x10 sprite-0 pixel | sprite palette (0-3) << 5
const uint32_t *nes_framebuffer(const NES *n);

/// Audio: interleaved stereo float frames (L,R) at the configured rate generated since last call.
/// `dst` must hold 2*max_frames floats. Returns the number of frames written.
void   nes_set_sample_rate(NES *n, int rate);
size_t nes_read_audio(NES *n, float *dst, size_t max_frames);

/// Audio engine: mode 0 = original 2A03, 1 = enhanced chip (band-limited, stereo, reverb),
/// 2 = remastered (modern instruments driven by the game's music). style 0 = orchestral, 1 = synthwave.
void nes_set_audio_mode(NES *n, int mode, int style, float reverb, float width, float chip_blend, float bass_boost);

/// Battery-backed PRG RAM (8 KiB).
int      nes_has_battery(const NES *n);
uint8_t *nes_prg_ram(NES *n);
size_t   nes_prg_ram_size(void);

/// Raw CPU RAM (2 KiB) and OAM (256 bytes) for renderer hints (lights etc.).
const uint8_t *nes_cpu_ram(const NES *n);
const uint8_t *nes_oam(const NES *n);
const uint8_t *nes_palette_ram(const NES *n);   // 32 bytes
/// Scanline where sprite-0 hit occurred in the last frame (status-bar split), -1 if none.
int nes_split_line(const NES *n);

/// Save states.
size_t nes_state_size(void);
void   nes_save_state(const NES *n, void *dst);
int    nes_load_state(NES *n, const void *src, size_t size);

/// Recompilation info / statistics.
int      nes_recomp_available(void);           // 1 if generated code is linked
uint32_t nes_recomp_rom_crc(void);              // CRC32 of PRG the code was built from
uint32_t nes_rom_crc(const NES *n);
void     nes_set_force_interpreter(NES *n, int on);
uint64_t nes_stat_recomp_instructions(const NES *n);   // recompiled block executions
uint64_t nes_stat_interp_instructions(const NES *n);
/// Writes "bank window addr" lines for every address the interpreter had to run
/// from ROM (feed back into Tools/recompile.py --coverage to grow coverage).
size_t nes_dump_misses(const NES *n, char *dst, size_t cap);

/// Lock-free SPSC audio ring buffer (emulation thread -> CoreAudio callback).
typedef struct ZRRing ZRRing;
ZRRing  *zr_ring_create(uint32_t capacity);
void     zr_ring_destroy(ZRRing *q);
uint32_t zr_ring_available(ZRRing *q);
uint32_t zr_ring_write(ZRRing *q, const float *src, uint32_t n);
uint32_t zr_ring_read(ZRRing *q, float *dst, uint32_t n, float gain);
/// Reads interleaved stereo frames and de-interleaves into two buffers.
uint32_t zr_ring_read_stereo(ZRRing *q, float *left, float *right, uint32_t frames, float gain);
void     zr_ring_clear(ZRRing *q);

#ifdef __cplusplus
}
#endif
#endif
