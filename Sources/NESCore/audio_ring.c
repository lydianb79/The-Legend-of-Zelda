// audio_ring.c — single-producer / single-consumer float ring buffer used to
// hand samples from the emulation thread to the CoreAudio render callback.
#include "include/nescore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct ZRRing {
    float *buf;
    uint32_t cap;               // power of two
    _Atomic uint32_t w, r;
    float last, lastR;
};

ZRRing *zr_ring_create(uint32_t capacity) {
    uint32_t cap = 1;
    while (cap < capacity) cap <<= 1;
    ZRRing *q = (ZRRing *)calloc(1, sizeof(ZRRing));
    q->buf = (float *)calloc(cap, sizeof(float));
    q->cap = cap;
    return q;
}

void zr_ring_destroy(ZRRing *q) { if (q) { free(q->buf); free(q); } }

uint32_t zr_ring_available(ZRRing *q) {
    return atomic_load_explicit(&q->w, memory_order_acquire) - atomic_load_explicit(&q->r, memory_order_acquire);
}

uint32_t zr_ring_write(ZRRing *q, const float *src, uint32_t n) {
    uint32_t w = atomic_load_explicit(&q->w, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&q->r, memory_order_acquire);
    uint32_t space = q->cap - (w - r);
    if (n > space) n = space & ~1u;   /* keep stereo frames intact */
    for (uint32_t i = 0; i < n; i++) q->buf[(w + i) & (q->cap - 1)] = src[i];
    atomic_store_explicit(&q->w, w + n, memory_order_release);
    return n;
}

uint32_t zr_ring_read(ZRRing *q, float *dst, uint32_t n, float gain) {
    uint32_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&q->w, memory_order_acquire);
    uint32_t avail = w - r, k = n < avail ? n : avail;
    for (uint32_t i = 0; i < k; i++) dst[i] = q->buf[(r + i) & (q->cap - 1)] * gain;
    atomic_store_explicit(&q->r, r + k, memory_order_release);
    if (k) q->last = dst[k - 1];
    // underrun: fade the last sample towards zero instead of clicking
    float v = q->last;
    for (uint32_t i = k; i < n; i++) { v *= 0.995f; dst[i] = v; }
    q->last = v;
    return k;
}

void zr_ring_clear(ZRRing *q) {
    atomic_store_explicit(&q->r, atomic_load_explicit(&q->w, memory_order_acquire), memory_order_release);
}

uint32_t zr_ring_read_stereo(ZRRing *q, float *left, float *right, uint32_t frames, float gain) {
    uint32_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&q->w, memory_order_acquire);
    uint32_t avail = (w - r) / 2, k = frames < avail ? frames : avail;
    for (uint32_t i = 0; i < k; i++) {
        float l = q->buf[(r + 2 * i) & (q->cap - 1)] * gain;
        float rr = q->buf[(r + 2 * i + 1) & (q->cap - 1)] * gain;
        if (left) left[i] = l;
        if (right) right[i] = rr;
        q->last = l; q->lastR = rr;
    }
    atomic_store_explicit(&q->r, r + 2 * k, memory_order_release);
    float vl = q->last, vr = q->lastR;
    for (uint32_t i = k; i < frames; i++) {
        vl *= 0.995f; vr *= 0.995f;
        if (left) left[i] = vl;
        if (right) right[i] = vr;
    }
    q->last = vl; q->lastR = vr;
    return k;
}
