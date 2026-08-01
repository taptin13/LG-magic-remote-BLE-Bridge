#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct remote_decoder remote_decoder_t;

remote_decoder_t *remote_decoder_create(void);
/** Hard reset — clears bias and re-enters calibration (boot / CMD calib). */
void remote_decoder_reset(remote_decoder_t *d);
/** Soft reset — keeps last good gyro bias so airmouse works immediately after
 *  remote drop/reconnect; only clears LPF / carry / button latch. */
void remote_decoder_reset_session(remote_decoder_t *d);
void remote_decoder_set_sens(remote_decoder_t *d, float s, float thresh, float dead);
/** tremor 0..1 — stronger low-speed LPF + deadzone boost for hand shake. */
void remote_decoder_set_tremor(remote_decoder_t *d, float tremor);
void remote_decoder_on_fd(remote_decoder_t *d, const uint8_t *p, size_t len);

#ifdef __cplusplus
}
#endif
