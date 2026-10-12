#include "HearPortAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct HearPortAudioRing {
    size_t capacity;
    float *samples;
    _Atomic uint64_t *source_begin;
    _Atomic uint64_t *source_end;
    _Atomic uint64_t *captured_at;
    _Atomic uint64_t last_source;
    _Atomic uint64_t expired_frames;
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
    ring->source_begin = calloc(capacity_frames, sizeof(*ring->source_begin));
    ring->source_end = calloc(capacity_frames, sizeof(*ring->source_end));
    ring->captured_at = calloc(capacity_frames, sizeof(*ring->captured_at));
    atomic_store(&ring->last_source, UINT64_MAX);
    if (ring->samples == NULL || ring->source_begin == NULL ||
        ring->source_end == NULL || ring->captured_at == NULL) {
        free(ring->samples);
        free(ring->source_begin);
        free(ring->source_end);
        free(ring->captured_at);
        free(ring);
        return NULL;
    }
    ring->capacity = capacity_frames;
    return ring;
}

void hearport_audio_ring_destroy(HearPortAudioRing *ring) {
    if (ring == NULL) return;
    free(ring->samples);
    free(ring->source_begin);
    free(ring->source_end);
    free(ring->captured_at);
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
    return hearport_audio_ring_push_timed(ring, stereo, frames, UINT64_MAX, UINT64_MAX, UINT64_MAX);
}

size_t hearport_audio_ring_push_timed(HearPortAudioRing *ring, const float *stereo,
    size_t frames, uint64_t source_begin, uint64_t source_end, uint64_t captured_at) {
    if (frames == 0 || !hearport_audio_ring_reset_acknowledged(ring)) return 0;
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->read_cursor, memory_order_acquire);
    const size_t available = ring->capacity - (size_t)(write - read);
    const size_t count = frames < available ? frames : available;
    for (size_t frame = 0; frame < count; ++frame) {
        const size_t offset = ((size_t)(write + frame) % ring->capacity) * 2;
        ring->samples[offset] = stereo[frame * 2];
        ring->samples[offset + 1] = stereo[frame * 2 + 1];
        const size_t slot = offset / 2;
        const bool timed = captured_at != UINT64_MAX && source_end >= source_begin;
        const uint64_t span = timed ? source_end - source_begin : 0;
        const uint64_t begin = timed ? source_begin + span * frame / frames : UINT64_MAX;
        const uint64_t end = timed ? source_begin + span * (frame + 1) / frames : UINT64_MAX;
        atomic_store_explicit(&ring->source_begin[slot], begin, memory_order_relaxed);
        atomic_store_explicit(&ring->source_end[slot], end, memory_order_relaxed);
        atomic_store_explicit(&ring->captured_at[slot], timed ?
            captured_at + (begin - source_begin) * 1000000000ull / 48000 : UINT64_MAX,
            memory_order_relaxed);
    }
    atomic_store_explicit(&ring->write_cursor, write + count, memory_order_release);
    return count;
}

static void acknowledge_reset(HearPortAudioRing *ring, uint64_t generation) {
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_acquire);
    atomic_store_explicit(&ring->read_cursor, write, memory_order_release);
    atomic_store_explicit(&ring->last_source, UINT64_MAX, memory_order_release);
    atomic_store_explicit(&ring->acknowledged_generation, generation, memory_order_release);
}

size_t hearport_audio_ring_pop(HearPortAudioRing *ring, float *stereo,
                               size_t frames) {
    return hearport_audio_ring_pop_at(ring, stereo, frames, 0, 0);
}

size_t hearport_audio_ring_pop_at(HearPortAudioRing *ring, float *stereo,
    size_t frames, uint64_t now, uint64_t maximum_age) {
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
    size_t count = 0;
    uint64_t cursor = read;
    while (count < frames && cursor < write) {
        const size_t slot = (size_t)(cursor % ring->capacity);
        const uint64_t captured = atomic_load_explicit(&ring->captured_at[slot], memory_order_relaxed);
        atomic_store_explicit(&ring->last_source,
            atomic_load_explicit(&ring->source_end[slot], memory_order_relaxed), memory_order_release);
        ++cursor;
        const uint64_t presentation = now + count * 1000000000ull / 48000;
        if (maximum_age != 0 && captured != UINT64_MAX && presentation >= captured &&
            presentation - captured >= maximum_age) {
            atomic_fetch_add_explicit(&ring->expired_frames, 1, memory_order_relaxed);
            continue;
        }
        stereo[count * 2] = ring->samples[slot * 2];
        stereo[count * 2 + 1] = ring->samples[slot * 2 + 1];
        ++count;
    }
    if (count < frames) {
        memset(stereo + count * 2, 0, (frames - count) * 2 * sizeof(float));
    }
    atomic_store_explicit(&ring->read_cursor, cursor, memory_order_release);
    const uint64_t latest = atomic_load_explicit(&ring->requested_generation,
                                                  memory_order_acquire);
    if (latest != generation) {
        memset(stereo, 0, frames * 2 * sizeof(float));
        acknowledge_reset(ring, latest);
        return 0;
    }
    return count;
}

uint64_t hearport_audio_ring_source_fill(const HearPortAudioRing *ring) {
    if (!hearport_audio_ring_reset_acknowledged(ring)) return 0;
    const uint64_t read = atomic_load_explicit(&ring->read_cursor, memory_order_acquire);
    const uint64_t write = atomic_load_explicit(&ring->write_cursor, memory_order_acquire);
    if (write <= read) return 0;
    const uint64_t begin = atomic_load_explicit(&ring->source_begin[read % ring->capacity], memory_order_relaxed);
    const uint64_t end = atomic_load_explicit(&ring->source_end[(write - 1) % ring->capacity], memory_order_relaxed);
    if (begin == UINT64_MAX || end == UINT64_MAX) return write - read;
    return end >= begin ? end - begin : 0;
}

uint64_t hearport_audio_ring_last_source(const HearPortAudioRing *ring) {
    return atomic_load_explicit(&ring->last_source, memory_order_acquire);
}

uint64_t hearport_audio_ring_expired_frames(const HearPortAudioRing *ring) {
    return atomic_load_explicit(&ring->expired_frames, memory_order_relaxed);
}
