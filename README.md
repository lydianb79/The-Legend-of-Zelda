# The Legend of Zelda — Native macOS Recomp (Metal)

A **static recompilation** of the NES game *The Legend of Zelda* into native code for macOS, with a
Metal renderer that remasters the image in real time: anti-aliased upscaling, relief lighting with
sun and sky, soft cast shadows from trees, rocks and walls, character drop shadows, ambient
occlusion, flickering point lights from flames plus Link's lantern in caves and dungeons, animated water,
HDR bloom, filmic tonemapping, EDR output on XDR displays, and fully configurable inputs.

**No game data is included.** You need your own ROM dump. The build recompiles *your* ROM locally.

## Build

Requirements: macOS 13+, Xcode or the Command Line Tools (`xcode-select --install`), Apple silicon or Intel.

```bash
cd ZeldaRecomp
./build.sh                                   # finds the .nes next to this folder
# or
./build.sh "/path/to/Legend of Zelda, The (Europe).nes"
open "build/Zelda Recomp.app"
```

`build.sh` runs three steps:

1. `Tools/recompile.py` disassembles the 6502 code of your ROM (recursive descent from the reset/NMI
   vectors, MMC1 bank tracking, the game's jump-table helper, and the code the game copies into
   cartridge RAM) and emits `Sources/NESCore/generated/recomp_gen.c` (~19k instructions, ~2.5k blocks).
2. `swift build -c release` compiles the runtime + generated C + Swift/Metal front-end.
3. Assembles and ad-hoc signs `build/Zelda Recomp.app`.

## How the recomp works

* Every 6502 instruction becomes C using the same macros as the reference interpreter
  (`Sources/NESCore/nes_internal.h`), with addressing modes specialised at compile time
  (zero-page/RAM/ROM accesses become direct array reads).
* Blocks are C functions with an entry switch, so interrupts that return mid-block need no fallback.
* Timing is exact per instruction (page-cross and branch penalties included); the PPU and APU are
  caught up lazily on register access and at every scanline, so the generated code stays fast while
  sprite-0/vblank timing remains accurate.
* Code the game copies into PRG-RAM (`$6C90-$7EFF`) is recompiled as an *overlay* and guarded: if the
  RAM bytes ever differ from the ROM copy, that block falls back to the interpreter automatically.
* Anything not statically discovered runs through the interpreter and is logged; on quit those
  addresses are written to `~/Library/Application Support/ZeldaRecomp/coverage/` and the next
  `./build.sh` folds them into native code.

Verification: `Tests/difftest.py` runs the interpreter and the recompiled build in lockstep and compares
RAM and the full frame buffer every frame. Across ~19,000 frames (attract mode, file select, the
sword cave, overworld combat) the two are bit-identical, with 0 instructions falling back to the interpreter.

## Sound & music

Three engines, switchable live in *Settings → Audio & System*:

* **Original**: the 2A03 mix, untouched.
* **Enhanced Chip**: band-limited (PolyBLEP) chip voices, stereo placement, room reverb and bus compression.
* **Remastered 2026** (default): the game's own sound driver keeps running; every sample, the live channel
  state (pitch, volume, duty, note triggers) drives modern synthesized instruments, either **Orchestral**
  (detuned-saw brass lead with filter envelope and delayed vibrato, a stereo string ensemble, a warm bass
  with a sub octave, synthesized percussion bodies) or **Synthwave** (supersaw lead, plucks, a resonant
  analog bass, punchy drums). Everything then passes through a hall reverb with pre-delay, stereo width
  and mastering (compressor and soft limiter). Sliders cover reverb, width, bass boost and how much of
  the original chip to blend in.

## Ultra 2026 graphics

The **Ultra 2026** preset (⌘4, or *Settings → Ultra 2026*) adds the following on top of Remastered:
6× internal resolution, double shadow samples, global illumination (colour bleeding),
drifting cloud shadows over the overworld, wind moving through the foliage, volumetric sun shafts and
light haze around flames, ember particles rising from fires, dust motes and fireflies, water reflections,
tilt-shift depth of field, and anamorphic lens streaks. Each effect has its own slider.

## Graphics settings (Settings… ⌘,)

| Group | Options |
|---|---|
| Presets | Original · Crisp HD · **Remastered 2026** (default) · **Ultra 2026** · Cinematic · Retro CRT |
| Image | Upscaler (Pixel Perfect / Smooth Edges AA / Soft), internal resolution 2×–8×, aspect (8:7 TV pixels, square, integer, stretch), palette (Classic, Vivid, Soft), ambient fill |
| Display | HDR/EDR output, V-Sync, stats overlay |
| Lighting | sun direction/elevation/intensity, ambient, relief depth, scenery height, sprite volume, AO, animated water |
| Shadows | cast shadows on/off, strength, softness |
| Dynamic lights | flames & lantern, intensity, emissive glow, cave/dungeon darkness |
| Post FX | bloom, tonemapper (Neutral, AgX, ACES, off), exposure, contrast, saturation, temperature, vignette, grain, chromatic aberration, sharpen, CRT scanlines/curvature |

Hold **F1** at any time to see the untouched original image.

## Controls (all rebindable, keyboard + any MFi/Xbox/PlayStation/Switch Pro controller)

| NES | Keyboard | Controller |
|---|---|---|
| D-Pad | Arrow keys / WASD | D-pad / left stick |
| A (sword) | X / K | A / Cross |
| B (item) | Z / J | X / Square |
| Start | Return | Menu |
| Select | Right Shift / Tab | View / Share |
| Fast forward (hold) | ` | R2 / RT |

Hotkeys: F5 quick save · F8 quick load · ⌥1–9 slot · F2 cycle presets · F3 stats · ⌘P pause · ⌘R reset ·
⌃⌘F full screen. Battery saves (your three save files) are stored automatically.

## Timing

This European ROM is PAL (50 Hz). *System → Game speed* can switch to NTSC 60 Hz timing, which matches
60/120 Hz displays perfectly but runs the game 20 % faster.

## Testing (Linux or macOS, no GUI needed)

```bash
export ZELDA_ROM="/path/to/your/zelda.nes"
python3 Tools/recompile.py --rom "$ZELDA_ROM" --out /tmp/gen/recomp_gen.c --coverage Tools/seeds
cc -O2 -shared -fPIC -ISources/NESCore -o /tmp/libnes_interp.so Sources/NESCore/*.c Sources/NESCore/generated/recomp_gen.c -lm
cc -O2 -shared -fPIC -ISources/NESCore -o /tmp/libnes_recomp.so Sources/NESCore/*.c /tmp/gen/recomp_gen.c -lm
mkdir -p out && python3 Tests/difftest.py /tmp/libnes_interp.so /tmp/libnes_recomp.so 6000 11
```

`difftest.py` plays the game with a bot, running the interpreter and the recompiled build in lockstep.
`coverage.py` collects interpreter fallback addresses as new seeds.

## Legal

This repository contains no ROM data, graphics, music or code from the game. `Sources/NESCore/generated/`
holds only a placeholder; the real file is generated locally from your own dump and is git-ignored.
The Legend of Zelda is a trademark of Nintendo; this is an unofficial fan project and is not affiliated
with or endorsed by Nintendo. The app icon is original artwork.

## Layout

```
Tools/recompile.py         6502 -> C static recompiler
Tools/seeds/               coverage seeds + RAM-overlay description (addresses only)
Sources/NESCore/           C runtime: interpreter, PPU, APU, MMC1, scheduler, save states
Sources/ZeldaRecomp/       Swift app: Metal renderer + shaders, settings UI, input, audio
Tests/                     headless harness, Python bot, differential tests
```
