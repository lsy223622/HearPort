#ifndef HEARPORT_SPAKE2_PROVIDER_H
#define HEARPORT_SPAKE2_PROVIDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  HEARPORT_SPAKE2_OK = 0,
  HEARPORT_SPAKE2_INVALID_ARGUMENT = 1,
  HEARPORT_SPAKE2_INVALID_POINT = 2,
  HEARPORT_SPAKE2_CONFIRMATION_FAILED = 3,
  HEARPORT_SPAKE2_INTERNAL_ERROR = 4
};

typedef struct hearport_spake2_session hearport_spake2_session;
typedef struct hearport_spake2_output hearport_spake2_output;

int hearport_spake2_sha256(const uint8_t *input, size_t input_len,
                           uint8_t output[32]);
int hearport_spake2_hmac_sha256(const uint8_t *key, size_t key_len,
                                const uint8_t *message, size_t message_len,
                                uint8_t output[32]);
int hearport_spake2_random(uint8_t *output, size_t output_len);
int hearport_spake2_pin_to_scalar(const uint8_t *pin, size_t pin_len,
                                  uint8_t output[32]);

// role: 1 = RFC 9382 Party A (Windows), 2 = Party B (iPad).
// The returned public point is SEC1 uncompressed and exactly 65 bytes.
int hearport_spake2_begin(uint8_t role, const uint8_t scalar[32],
                          const uint8_t *identity_a, size_t identity_a_len,
                          const uint8_t *identity_b, size_t identity_b_len,
                          uint8_t public_point[65],
                          hearport_spake2_session **session_out);

// Finishes the first SPAKE2 round. The session is consumed on every call.
// The returned output owns the session key and local confirmation MAC.
int hearport_spake2_finish(hearport_spake2_session *session,
                           const uint8_t *peer_point, size_t peer_point_len,
                           hearport_spake2_output **output_out,
                           uint8_t confirmation[32]);

int hearport_spake2_verify_confirmation(const hearport_spake2_output *output,
                                        const uint8_t confirmation[32]);
int hearport_spake2_copy_session_key(const hearport_spake2_output *output,
                                     uint8_t session_key[16]);
void hearport_spake2_session_free(hearport_spake2_session *session);
void hearport_spake2_output_free(hearport_spake2_output *output);

#ifdef __cplusplus
}
#endif

#endif
