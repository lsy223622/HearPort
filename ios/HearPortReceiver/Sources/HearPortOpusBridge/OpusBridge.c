#include "HearPortOpusBridge.h"

#include <opus.h>
#include <stddef.h>

void *hp_opus_encoder_create(int bitrate, int *error) {
  int create_error = OPUS_OK;
  OpusEncoder *encoder = opus_encoder_create(
      48000, 2, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &create_error);
  if (encoder == NULL) {
    if (error != NULL) {
      *error = create_error;
    }
    return NULL;
  }

  int configuration_error = opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
  if (configuration_error == OPUS_OK) {
    configuration_error = opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
  }
  if (configuration_error == OPUS_OK) {
    configuration_error = opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(5));
  }
  if (configuration_error == OPUS_OK) {
    configuration_error = opus_encoder_ctl(encoder, OPUS_SET_VBR(0));
  }
  if (configuration_error == OPUS_OK) {
    configuration_error = opus_encoder_ctl(encoder, OPUS_SET_DTX(0));
  }
  if (configuration_error == OPUS_OK) {
    configuration_error = opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(0));
  }
  if (configuration_error != OPUS_OK) {
    opus_encoder_destroy(encoder);
    if (error != NULL) {
      *error = configuration_error;
    }
    return NULL;
  }

  if (error != NULL) {
    *error = OPUS_OK;
  }
  return encoder;
}

void hp_opus_encoder_destroy(void *encoder) {
  if (encoder != NULL) {
    opus_encoder_destroy((OpusEncoder *)encoder);
  }
}

int hp_opus_encode(void *encoder, const float *pcm, int frame_count,
                   unsigned char *packet, int capacity) {
  if (encoder == NULL || pcm == NULL || packet == NULL || frame_count <= 0 ||
      capacity <= 0) {
    return OPUS_BAD_ARG;
  }
  return opus_encode_float((OpusEncoder *)encoder, pcm, frame_count, packet, capacity);
}

int hp_opus_lookahead(void *encoder) {
  if (encoder == NULL) {
    return OPUS_BAD_ARG;
  }
  int lookahead = 0;
  int result = opus_encoder_ctl((OpusEncoder *)encoder, OPUS_GET_LOOKAHEAD(&lookahead));
  return result == OPUS_OK ? lookahead : result;
}

void *hp_opus_decoder_create(int *error) {
  int create_error = OPUS_OK;
  OpusDecoder *decoder = opus_decoder_create(48000, 2, &create_error);
  if (error != NULL) {
    *error = create_error;
  }
  return decoder;
}

void hp_opus_decoder_destroy(void *decoder) {
  if (decoder != NULL) {
    opus_decoder_destroy((OpusDecoder *)decoder);
  }
}

int hp_opus_decode(void *decoder, const unsigned char *packet, int bytes,
                   float *pcm, int frame_capacity) {
  if (decoder == NULL || pcm == NULL || frame_capacity <= 0 || bytes < 0 ||
      (packet == NULL && bytes != 0) || (packet != NULL && bytes == 0)) {
    return OPUS_BAD_ARG;
  }
  return opus_decode_float((OpusDecoder *)decoder, packet, bytes, pcm,
                           frame_capacity, 0);
}

const char *hp_opus_version(void) {
  return opus_get_version_string();
}
