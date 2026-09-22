#ifndef HEARPORT_ATOMICS_H
#define HEARPORT_ATOMICS_H

#include <stdbool.h>
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

#ifdef __cplusplus
}
#endif

#endif
