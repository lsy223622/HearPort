#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
void* offline_recovery_create(int budget_ms, int replay_mode, int startup_ms, double send_mbps);
void offline_recovery_destroy(void* context);
void offline_recovery_produced(void* context, uint32_t sequence, uint64_t captured,
                               uint64_t now);
int offline_recovery_feedback(void* context, uint32_t generation, uint32_t received,
    uint64_t played, uint64_t generated, uint64_t now, int corrected, int replay, int lead_ms,
    uint32_t* replay_sequences, int capacity);
uint32_t offline_recovery_generation(void* context);
#ifdef __cplusplus
}
#endif
