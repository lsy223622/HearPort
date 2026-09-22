#include "HearPortAtomics.h"

uint64_t hearport_atomic_load_u64(const uint64_t *value) {
    return __atomic_load_n(value, __ATOMIC_RELAXED);
}

uint64_t hearport_atomic_fetch_add_u64(uint64_t *value, uint64_t amount) {
    return __atomic_fetch_add(value, amount, __ATOMIC_RELAXED);
}

uint64_t hearport_atomic_exchange_u64(uint64_t *value, uint64_t replacement) {
    return __atomic_exchange_n(value, replacement, __ATOMIC_RELAXED);
}

bool hearport_atomic_compare_exchange_u64(uint64_t *value,
                                          uint64_t *expected,
                                          uint64_t replacement) {
    return __atomic_compare_exchange_n(value,
                                       expected,
                                       replacement,
                                       false,
                                       __ATOMIC_RELAXED,
                                       __ATOMIC_RELAXED);
}
