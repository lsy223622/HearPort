#include "HearPortAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct HearPortAudioRing {
    size_t capacity;
    float *samples;
    _Atomic uint64_t read_cursor;
    _Atomic uint64_t write_cursor;
    _Atomic uint64_t requested_generation;
    _Atomic uint64_t acknowledged_generation;
};

HearPortAudioRing *hearport_audio_ring_create(size_t capacity_frames) {
    if (capacity_frames == 0 || capacity_frames > SIZE_MAX / (2 * sizeof(float))) {
        return NULL;
    }
    HearPortAudioRing *ring = calloc(1, sizeof(*ring));
    if (ring == NULL) return NULL;
    ring->samples = calloc(capacity_frames * 2, sizeof(float));
    if (ring->samples == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity_frames;
    return ring;
}

void hearport_audio_ring_destroy(HearPortAudioRing *ring) {
    if (ring == NULL) return;
    free(ring->samples);
    free(ring);
}

void hearport_audio_ring_request_reset(HearPortAudioRing *ring) {
    atomic_fetch_add_explicit(&ring->requested_generation, 1, memory_order_release);
}

bool hearport_audio_ring_reset_acknowledged(const HearPortAudioRing *ring) {
    return atomic_load_explicit(&ring->acknowledged_generation, memory_order_acquire) ==
           atomic_load_explicit(&ring->requested_generation, memory_order_acquire);
}

size_t hearport_audio_ring_fill(const HearPortAudioRing *ring) {
    if (!hearport_audio_ring_reset_acknowledged(ring)) return 0;
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_acquire);
    const uint64_t read = atomic_load_explicit(&ring->read_cursor, memory_order_acquire);
    if (write < read) return 0;
    const size_t fill = (size_t)(write - read);
    return fill < ring->capacity ? fill : ring->capacity;
}

size_t hearport_audio_ring_push(HearPortAudioRing *ring, const float *stereo,
                                size_t frames) {
    if (frames == 0 || !hearport_audio_ring_reset_acknowledged(ring)) return 0;
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->read_cursor, memory_order_acquire);
    const size_t available = ring->capacity - (size_t)(write - read);
    const size_t count = frames < available ? frames : available;
    for (size_t frame = 0; frame < count; ++frame) {
        const size_t offset = ((size_t)(write + frame) % ring->capacity) * 2;
        ring->samples[offset] = stereo[frame * 2];
        ring->samples[offset + 1] = stereo[frame * 2 + 1];
    }
    atomic_store_explicit(&ring->write_cursor, write + count, memory_order_release);
    return count;
}

static void acknowledge_reset(HearPortAudioRing *ring, uint64_t generation) {
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_acquire);
    atomic_store_explicit(&ring->read_cursor, write, memory_order_release);
    atomic_store_explicit(&ring->acknowledged_generation, generation, memory_order_release);
}

size_t hearport_audio_ring_pop(HearPortAudioRing *ring, float *stereo,
                               size_t frames) {
    if (frames == 0) return 0;
    const uint64_t generation = atomic_load_explicit(&ring->requested_generation,
                                                      memory_order_acquire);
    if (generation != atomic_load_explicit(&ring->acknowledged_generation,
                                            memory_order_relaxed)) {
        memset(stereo, 0, frames * 2 * sizeof(float));
        acknowledge_reset(ring, generation);
        return 0;
    }
    const uint64_t read = atomic_load_explicit(&ring->read_cursor, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_acquire);
    const size_t available = (size_t)(write - read);
    const size_t count = frames < available ? frames : available;
    for (size_t frame = 0; frame < count; ++frame) {
        const size_t offset = ((size_t)(read + frame) % ring->capacity) * 2;
        stereo[frame * 2] = ring->samples[offset];
        stereo[frame * 2 + 1] = ring->samples[offset + 1];
    }
    if (count < frames) {
        memset(stereo + count * 2, 0, (frames - count) * 2 * sizeof(float));
    }
    atomic_store_explicit(&ring->read_cursor, read + count, memory_order_release);
    const uint64_t latest = atomic_load_explicit(&ring->requested_generation,
                                                  memory_order_acquire);
    if (latest != generation) {
        memset(stereo, 0, frames * 2 * sizeof(float));
        acknowledge_reset(ring, latest);
        return 0;
    }
    return count;
}
