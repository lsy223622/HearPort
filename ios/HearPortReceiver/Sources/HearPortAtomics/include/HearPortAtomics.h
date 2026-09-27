#ifndef HEARPORT_ATOMICS_H
#define HEARPORT_ATOMICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t hearport_atomic_load_u64(const uint64_t *value);
uint64_t hearport_atomic_fetch_add_u64(uint64_t *value, uint64_t amount);
uint64_t hearport_atomic_exchange_u64(uint64_t *value, uint64_t replacement);
bool hearport_atomic_compare_exchange_u64(uint64_t *value,
                                          uint64_t *expected,
                                          uint64_t replacement);

typedef struct HearPortAudioRing HearPortAudioRing;

HearPortAudioRing *hearport_audio_ring_create(size_t capacity_frames);
void hearport_audio_ring_destroy(HearPortAudioRing *ring);
void hearport_audio_ring_request_reset(HearPortAudioRing *ring);
bool hearport_audio_ring_reset_acknowledged(const HearPortAudioRing *ring);
size_t hearport_audio_ring_fill(const HearPortAudioRing *ring);
size_t hearport_audio_ring_push(HearPortAudioRing *ring, const float *stereo,
                                size_t frames);
size_t hearport_audio_ring_pop(HearPortAudioRing *ring, float *stereo,
                               size_t frames);

#ifdef __cplusplus
}
#endif

#endif
