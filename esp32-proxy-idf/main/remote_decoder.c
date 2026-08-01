#include "remote_decoder.h"
#include "event_bus.h"
#ifndef HOST_TEST
#include "esp_log.h"
static const char *TAG = "DEC";
#else
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#endif
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct remote_decoder {
  float sens, thresh, soft_dead, tremor;
  double gyro_lpf[3], gyro_bias[3], bias_sum[3];
  double bias_min[3], bias_max[3];
  double fallback_bias[3];
  int bias_samples;
  int calib_age;
  bool calibrating, have_bias, have_fallback, pointer_mode;
  double carry_x, carry_y;
  int still_samples;
  uint16_t last_btn;
};

static const int kBiasWarmup = 60;
/* Re-lock after reconnect can be shorter — we already have a fallback bias. */
static const int kBiasWarmupQuick = 30;
/* ~2s at ~100Hz FD. If the user keeps waving, restore last good bias instead of
 * inventing a provisional zero-point (which makes the cursor run by itself). */
static const int kBiasFallbackTimeout = 200;
/* Reject calibration windows containing hand movement. Raw gyro noise while
 * stationary is well below this span; a moving reconnect starts a fresh
 * window and calibrates automatically once the remote is held still. */
static const double kBiasStableSpan = 90.0;
static const double kLpf = 0.42;
static const double kStill = 70.0;
/* ~80ms still (FD ~100Hz) before clearing fractional carry. */
static const int kStillClearSamples = 8;

static void clear_motion_transients(remote_decoder_t *d) {
  memset(d->gyro_lpf, 0, sizeof(d->gyro_lpf));
  d->pointer_mode = false;
  d->carry_x = d->carry_y = 0;
  d->still_samples = 0;
  d->last_btn = 0;
}

static void clear_calib_window(remote_decoder_t *d) {
  memset(d->bias_sum, 0, sizeof(d->bias_sum));
  memset(d->bias_min, 0, sizeof(d->bias_min));
  memset(d->bias_max, 0, sizeof(d->bias_max));
  d->bias_samples = 0;
  d->calib_age = 0;
}

remote_decoder_t *remote_decoder_create(void) {
  remote_decoder_t *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  d->sens = 0.045f;
  d->thresh = 280.f;
  d->soft_dead = 28.f;
  d->tremor = 0.35f; /* mild hand-shake reduction by default */
  d->calibrating = true;
  d->have_bias = false;
  d->have_fallback = false;
  return d;
}

void remote_decoder_reset(remote_decoder_t *d) {
  if (!d) return;
  memset(d->gyro_bias, 0, sizeof(d->gyro_bias));
  memset(d->fallback_bias, 0, sizeof(d->fallback_bias));
  clear_calib_window(d);
  d->calibrating = true;
  d->have_bias = false;
  d->have_fallback = false;
  clear_motion_transients(d);
}

void remote_decoder_reset_session(remote_decoder_t *d) {
  if (!d) return;
  /* Keep last committed bias as fallback, but block motion until a still
   * window re-locks (or timeout restores the fallback). Emitting with a
   * stale/provisional bias is what made the cursor run by itself. */
  if (d->have_bias) {
    d->fallback_bias[0] = d->gyro_bias[0];
    d->fallback_bias[1] = d->gyro_bias[1];
    d->fallback_bias[2] = d->gyro_bias[2];
    d->have_fallback = true;
  } else {
    d->have_fallback = false;
  }
  clear_calib_window(d);
  d->calibrating = true;
  clear_motion_transients(d);
}

void remote_decoder_set_sens(remote_decoder_t *d, float s, float thresh, float dead) {
  if (!d) return;
  d->sens = s;
  d->thresh = thresh;
  d->soft_dead = dead;
}

void remote_decoder_set_tremor(remote_decoder_t *d, float tremor) {
  if (!d) return;
  if (tremor < 0.f) tremor = 0.f;
  if (tremor > 1.f) tremor = 1.f;
  d->tremor = tremor;
}

/* Soft knee like hid-dongle — smoother than excess².
 *
 * Applied to the 2D magnitude, not to each axis on its own. A per-axis knee gives
 * each axis a different gain, which bends slow diagonals toward the dominant axis
 * and makes the weaker axis flicker across the deadzone — the pointer then walks a
 * zigzag instead of a straight line. Scaling both axes by one factor derived from
 * the vector length keeps the direction exact at every speed. */
static void soft_vector(double dead, double vx, double vy, double *ox, double *oy) {
  double mag = sqrt(vx * vx + vy * vy);
  if (mag <= dead) {
    *ox = 0;
    *oy = 0;
    return;
  }
  double s = (mag - dead) / (mag + dead);
  *ox = vx * s;
  *oy = vy * s;
}

static void pub_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel) {
  event_bus_publish_motion(dx, dy, buttons, wheel);
}

static void pub_wheel(int8_t wheel) {
  event_bus_publish_wheel(wheel);
}

static void pub_button(uint16_t code, bool down) {
  bus_event_t ev = {.type = BUS_BUTTON};
  ev.u.button = (button_payload_t){code, (uint8_t)(down ? 1 : 0)};
  event_bus_publish(&ev);
}

void remote_decoder_on_fd(remote_decoder_t *d, const uint8_t *p, size_t len) {
  if (!d || !p || len < 19) return;

  int16_t imu[6];
  for (int i = 0; i < 6; i++) {
    uint16_t raw = ((uint16_t)p[4 + i * 2] << 8) | p[5 + i * 2];
    imu[i] = (int16_t)raw;
  }
  double gx = imu[0], gy = imu[1], gz = imu[2];
  /* FD layout (matches esp32-hid-dongle / ProtocolAnalyzer):
   * p[16..17]=button BE, p[18]=wheel — NOT p[16]=wheel. */
  uint16_t btn = ((uint16_t)p[16] << 8) | p[17];
  int8_t wheel = (int8_t)p[18];

  if (d->calibrating) {
    d->calib_age++;
    if (d->bias_samples == 0) {
      d->bias_min[0] = d->bias_max[0] = gx;
      d->bias_min[1] = d->bias_max[1] = gy;
      d->bias_min[2] = d->bias_max[2] = gz;
    } else {
      if (gx < d->bias_min[0]) d->bias_min[0] = gx;
      if (gx > d->bias_max[0]) d->bias_max[0] = gx;
      if (gy < d->bias_min[1]) d->bias_min[1] = gy;
      if (gy > d->bias_max[1]) d->bias_max[1] = gy;
      if (gz < d->bias_min[2]) d->bias_min[2] = gz;
      if (gz > d->bias_max[2]) d->bias_max[2] = gz;
    }

    bool stable = (d->bias_max[0] - d->bias_min[0] <= kBiasStableSpan) &&
                  (d->bias_max[1] - d->bias_min[1] <= kBiasStableSpan) &&
                  (d->bias_max[2] - d->bias_min[2] <= kBiasStableSpan);
    if (!stable) {
      d->bias_sum[0] = gx;
      d->bias_sum[1] = gy;
      d->bias_sum[2] = gz;
      d->bias_min[0] = d->bias_max[0] = gx;
      d->bias_min[1] = d->bias_max[1] = gy;
      d->bias_min[2] = d->bias_max[2] = gz;
      d->bias_samples = 1;
    } else {
      d->bias_sum[0] += gx;
      d->bias_sum[1] += gy;
      d->bias_sum[2] += gz;
      d->bias_samples++;
      int need = d->have_fallback ? kBiasWarmupQuick : kBiasWarmup;
      if (d->bias_samples >= need) {
        d->gyro_bias[0] = d->bias_sum[0] / d->bias_samples;
        d->gyro_bias[1] = d->bias_sum[1] / d->bias_samples;
        d->gyro_bias[2] = d->bias_sum[2] / d->bias_samples;
        d->calibrating = false;
        d->have_bias = true;
#ifndef HOST_TEST
        ESP_LOGI(TAG, "gyro bias ready");
#endif
      }
    }

    /* Waving after reconnect: restore last good bias instead of inventing one. */
    if (d->calibrating && d->have_fallback && d->calib_age >= kBiasFallbackTimeout) {
      d->gyro_bias[0] = d->fallback_bias[0];
      d->gyro_bias[1] = d->fallback_bias[1];
      d->gyro_bias[2] = d->fallback_bias[2];
      d->calibrating = false;
      d->have_bias = true;
#ifndef HOST_TEST
      ESP_LOGW(TAG, "gyro bias fallback (no still window)");
#endif
    }

    /* No motion while calibrating — provisional bias made the cursor run wild. */
    goto decode_buttons;
  }

  {
    double cx = gx - d->gyro_bias[0];
    double cy = gy - d->gyro_bias[1];
    double cz = gz - d->gyro_bias[2];
    /* Light bias when still (like Studio) — avoids "snap" on slow drags. */
    if (fabs(cx) < kStill && fabs(cz) < kStill) {
      const double b = 0.0015;
      d->gyro_bias[0] = (1 - b) * d->gyro_bias[0] + b * gx;
      d->gyro_bias[1] = (1 - b) * d->gyro_bias[1] + b * gy;
      d->gyro_bias[2] = (1 - b) * d->gyro_bias[2] + b * gz;
      cx = gx - d->gyro_bias[0];
      cy = gy - d->gyro_bias[1];
      cz = gz - d->gyro_bias[2];
    }
    /* Tremor↑ → heavier LPF (less high-frequency hand shake). Floor keeps
     * intentional flicks responsive even at max tremor. */
    double lpf = kLpf * (1.0 - 0.70 * (double)d->tremor);
    if (lpf < 0.12) lpf = 0.12;
    d->gyro_lpf[0] = lpf * cx + (1 - lpf) * d->gyro_lpf[0];
    d->gyro_lpf[1] = lpf * cy + (1 - lpf) * d->gyro_lpf[1];
    d->gyro_lpf[2] = lpf * cz + (1 - lpf) * d->gyro_lpf[2];

    /* Boost deadzone with tremor so tiny shakes never leave the knee. */
    double dead = (double)d->soft_dead * (1.0 + 1.25 * (double)d->tremor);
    double sx, sy;
    soft_vector(dead, d->gyro_lpf[2], d->gyro_lpf[0], &sx, &sy);
    sx *= d->sens;
    sy *= d->sens;
    if (fabs(d->gyro_lpf[0]) > d->thresh || fabs(d->gyro_lpf[2]) > d->thresh)
      d->pointer_mode = true;

    if (sx == 0.0 && sy == 0.0) {
      /* Keep fractional carry through short deadzone; clear only after ~80ms still. */
      d->still_samples++;
      if (d->still_samples >= kStillClearSamples) {
        d->carry_x = d->carry_y = 0;
        d->still_samples = 0;
      }
    } else {
      d->still_samples = 0;
      d->carry_x += sx;
      d->carry_y += sy;
      int idx = (int)trunc(d->carry_x);
      int idy = (int)trunc(d->carry_y);
      d->carry_x -= idx;
      d->carry_y -= idy;
      if (idx || idy) {
        if (idx > 32767) idx = 32767;
        if (idx < -32768) idx = -32768;
        if (idy > 32767) idy = 32767;
        if (idy < -32768) idy = -32768;
        pub_motion((int16_t)idx, (int16_t)idy, 0, 0);
      }
    }
  }

decode_buttons:
  /* Wheel: separate channel — not shared accumulator with cursor. */
  if (wheel != 0) {
    pub_wheel(wheel);
  }

  if (btn == d->last_btn) return;
  uint16_t prev = d->last_btn;
  d->last_btn = btn;

  if (prev) {
    pub_button(prev, false);
  }
  if (btn) {
    pub_button(btn, true);
  }
}
