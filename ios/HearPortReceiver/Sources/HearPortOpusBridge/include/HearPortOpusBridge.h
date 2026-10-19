#ifndef HEARPORT_OPUS_BRIDGE_H
#define HEARPORT_OPUS_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* PCM uses interleaved stereo float samples at 48 kHz; frame counts are per channel. */
void *hp_opus_encoder_create(int bitrate, int *error);
void hp_opus_encoder_destroy(void *encoder);
int hp_opus_encode(void *encoder, const float *pcm, int frame_count,
                   unsigned char *packet, int capacity);
int hp_opus_lookahead(void *encoder);

void *hp_opus_decoder_create(int *error);
void hp_opus_decoder_destroy(void *decoder);
/* Passing packet == NULL and bytes == 0 requests normal packet loss concealment. */
int hp_opus_decode(void *decoder, const unsigned char *packet, int bytes,
                   float *pcm, int frame_capacity);

const char *hp_opus_version(void);

#ifdef __cplusplus
}
#endif

#endif
