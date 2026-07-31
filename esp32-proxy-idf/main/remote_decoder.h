#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct remote_decoder remote_decoder_t;

remote_decoder_t *remote_decoder_create(void);
void remote_decoder_reset(remote_decoder_t *d);
void remote_decoder_set_sens(remote_decoder_t *d, float s, float thresh, float dead);
void remote_decoder_on_fd(remote_decoder_t *d, const uint8_t *p, size_t len);

#ifdef __cplusplus
}
#endif
