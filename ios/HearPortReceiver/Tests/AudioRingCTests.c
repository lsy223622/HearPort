#include "HearPortAtomics.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

static void test_order_capacity_and_underflow(void) {
    HearPortAudioRing *ring = hearport_audio_ring_create(3);
    assert(ring != NULL);
    const float first[] = {1, -1, 2, -2};
    const float second[] = {3, -3, 4, -4};
    float output[8] = {0};
    assert(hearport_audio_ring_push(ring, first, 2) == 2);
    assert(hearport_audio_ring_pop(ring, output, 1) == 1);
    assert(output[0] == 1 && output[1] == -1);
    assert(hearport_audio_ring_push(ring, second, 2) == 2);
    assert(hearport_audio_ring_fill(ring) == 3);
    assert(hearport_audio_ring_pop(ring, output, 4) == 3);
    assert(output[0] == 2 && output[2] == 3 && output[4] == 4);
    assert(output[6] == 0 && output[7] == 0);
    hearport_audio_ring_destroy(ring);
}

static void test_reset_discards_old_audio_and_converges(void) {
    HearPortAudioRing *ring = hearport_audio_ring_create(2);
    const float old[] = {7, -7};
    const float fresh[] = {8, -8};
    float output[2] = {99, 99};
    assert(hearport_audio_ring_push(ring, old, 1) == 1);
    hearport_audio_ring_request_reset(ring);
    hearport_audio_ring_request_reset(ring);
    assert(!hearport_audio_ring_reset_acknowledged(ring));
    assert(hearport_audio_ring_push(ring, fresh, 1) == 0);
    assert(hearport_audio_ring_pop(ring, output, 1) == 0);
    assert(output[0] == 0 && output[1] == 0);
    assert(hearport_audio_ring_reset_acknowledged(ring));
    assert(hearport_audio_ring_push(ring, fresh, 1) == 1);
    assert(hearport_audio_ring_pop(ring, output, 1) == 1);
    assert(output[0] == 8 && output[1] == -8);
    hearport_audio_ring_destroy(ring);
}

struct concurrent_case {
    HearPortAudioRing *ring;
    atomic_int produced;
};

static void *produce(void *context) {
    struct concurrent_case *test = context;
    for (int value = 1; value <= 50000; ++value) {
        const float frame[] = {(float)value, (float)-value};
        while (hearport_audio_ring_push(test->ring, frame, 1) == 0) {
            sched_yield();
        }
        atomic_store(&test->produced, value);
    }
    return NULL;
}

static void test_concurrent_publication_has_no_torn_or_duplicate_frames(void) {
    struct concurrent_case test = {hearport_audio_ring_create(257), 0};
    pthread_t thread;
    assert(pthread_create(&thread, NULL, produce, &test) == 0);
    for (int expected = 1; expected <= 50000; ++expected) {
        float output[2] = {0};
        while (hearport_audio_ring_pop(test.ring, output, 1) == 0) {
            sched_yield();
        }
        assert(output[0] == (float)expected);
        assert(output[1] == (float)-expected);
    }
    assert(pthread_join(thread, NULL) == 0);
    assert(atomic_load(&test.produced) == 50000);
    hearport_audio_ring_destroy(test.ring);
}

static void *reset_and_produce(void *context) {
    struct concurrent_case *test = context;
    for (int value = 1; value <= 10000; ++value) {
        hearport_audio_ring_request_reset(test->ring);
        while (!hearport_audio_ring_reset_acknowledged(test->ring)) {
            sched_yield();
        }
        const float frame[] = {(float)value, (float)-value};
        while (hearport_audio_ring_push(test->ring, frame, 1) == 0) {
            sched_yield();
        }
    }
    atomic_store(&test->produced, 10000);
    return NULL;
}

static void test_concurrent_resets_never_replay_older_pcm(void) {
    struct concurrent_case test = {hearport_audio_ring_create(8), 0};
    pthread_t thread;
    assert(pthread_create(&thread, NULL, reset_and_produce, &test) == 0);
    float latest = 0;
    while (atomic_load(&test.produced) == 0 || hearport_audio_ring_fill(test.ring) != 0) {
        float output[2] = {0};
        if (hearport_audio_ring_pop(test.ring, output, 1) == 1) {
            assert(output[0] >= latest);
            assert(output[1] == -output[0]);
            latest = output[0];
        }
        assert(hearport_audio_ring_fill(test.ring) <= 8);
        sched_yield();
    }
    assert(pthread_join(thread, NULL) == 0);
    hearport_audio_ring_destroy(test.ring);
}

int main(void) {
    test_order_capacity_and_underflow();
    test_reset_discards_old_audio_and_converges();
    test_concurrent_publication_has_no_torn_or_duplicate_frames();
    test_concurrent_resets_never_replay_older_pcm();
    puts("audio_ring_tests_passed");
    return 0;
}
