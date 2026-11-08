// Headless test harness: runs the core with a scripted input and dumps frames.
// usage: harness rom.nes frames script.txt outdir [interp|recomp] [dumpevery]
#include "../Sources/NESCore/include/nescore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage\n"); return 1; }
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *rom = malloc(sz); fread(rom, 1, sz, f); fclose(f);
    const char *err = 0; NES *n = nes_create(rom, sz, &err);
    if (!n) { fprintf(stderr, "err %s\n", err); return 1; }
    int frames = atoi(argv[2]);
    int mode_interp = argc > 5 && strcmp(argv[5], "interp") == 0;
    int every = argc > 6 ? atoi(argv[6]) : 60;
    nes_set_force_interpreter(n, mode_interp);
    { extern int synth_solo; if (getenv("SOLO")) synth_solo = atoi(getenv("SOLO")); }
    if (getenv("AUDIO_MODE")) nes_set_audio_mode(n, atoi(getenv("AUDIO_MODE")), getenv("AUDIO_STYLE") ? atoi(getenv("AUDIO_STYLE")) : 0, 0.35f, 1.0f, 0.0f, 0.3f);
    // script: lines "start_frame end_frame mask"
    int sf[4096], ef[4096], mk[4096], ns = 0;
    FILE *s = fopen(argv[3], "r");
    if (s) { while (ns < 4096 && fscanf(s, "%d %d %i", &sf[ns], &ef[ns], &mk[ns]) == 3) ns++; fclose(s); }
    char path[512];
    snprintf(path, sizeof path, "%s/ramtrace.bin", argv[4]);
    FILE *rt = fopen(path, "wb");
    float abuf[16384]; size_t total_audio = 0;
    snprintf(path, sizeof path, "%s/audio.f32", argv[4]);
    FILE *af = fopen(path, "wb");
    clock_t t0 = clock();
    for (int fr = 0; fr < frames; fr++) {
        uint8_t m = 0;
        for (int i = 0; i < ns; i++) if (fr >= sf[i] && fr <= ef[i]) m |= (uint8_t)mk[i];
        nes_set_buttons(n, 0, m);
        nes_run_frame(n);
        fwrite(nes_cpu_ram(n), 1, 2048, rt);
        size_t k = nes_read_audio(n, abuf, 8192); total_audio += k; fwrite(abuf, 4, 2 * k, af);
        if (every > 0 && (fr % every == 0 || fr == frames - 1)) {
            snprintf(path, sizeof path, "%s/f%05d.raw", argv[4], fr);
            FILE *o = fopen(path, "wb"); fwrite(nes_framebuffer(n), 4, 256 * 240, o); fclose(o);
        }
    }
    fclose(rt); fclose(af);
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("frames=%d time=%.2fs (%.0f fps) recomp_blocks=%llu interp_instr=%llu audio=%zu crc=%08X\n", frames, secs, frames / secs,
           (unsigned long long)nes_stat_recomp_instructions(n), (unsigned long long)nes_stat_interp_instructions(n), total_audio, nes_rom_crc(n));
    static char miss[1 << 20];
    size_t w = nes_dump_misses(n, miss, sizeof miss);
    snprintf(path, sizeof path, "%s/misses.txt", argv[4]);
    FILE *mf = fopen(path, "w"); fwrite(miss, 1, w, mf); fclose(mf);
    return 0;
}
