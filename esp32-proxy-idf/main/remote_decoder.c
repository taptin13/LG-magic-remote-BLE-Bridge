#include "remote_decoder.h"
#include "event_bus.h"
#ifndef HOST_TEST
#include "esp_log.h"
static const char *TAG = "DEC";
#else
#define ESP_LOGI(...) ((void)0)
#endif
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct remote_decoder {
  float sens, thresh, soft_dead;
  double gyro_lpf[3], gyro_bias[3], bias_sum[3];
  int bias_samples;
  bool calibrating, pointer_mode;
  double carry_x, carry_y;
  int still_samples;
  uint16_t last_btn;
};

static const int kBiasWarmup = 60;
static const double kLpf = 0.42;
static const double kStill = 70.0;
/* ~80ms đứng yên (FD ~100Hz) mới xóa fractional carry. */
static const int kStillClearSamples = 8;

remote_decoder_t *remote_decoder_create(void) {
  remote_decoder_t *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  d->sens = 0.045f;
  d->thresh = 280.f;
  d->soft_dead = 28.f;
  d->calibrating = true;
  return d;
}

void remote_decoder_reset(remote_decoder_t *d) {
  if (!d) return;
  memset(d->gyro_lpf, 0, sizeof(d->gyro_lpf));
  memset(d->gyro_bias, 0, sizeof(d->gyro_bias));
  memset(d->bias_sum, 0, sizeof(d->bias_sum));
  d->bias_samples = 0;
  d->calibrating = true;
  d->pointer_mode = false;
  d->carry_x = d->carry_y = 0;
  d->still_samples = 0;
  d->last_btn = 0;
}

void remote_decoder_set_sens(remote_decoder_t *d, float s, float thresh, float dead) {
  if (!d) return;
  d->sens = s;
  d->thresh = thresh;
  d->soft_dead = dead;
}

static double soft_axis(const remote_decoder_t *d, double v) {
  /* Soft knee giống hid-dongle — mượt hơn excess². */
  double a = fabs(v);
  if (a <= d->soft_dead) return 0;
  double s = (a - d->soft_dead) / (a + d->soft_dead);
  return v < 0 ? -s * a : s * a;
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
  /* Layout FD (đúng như esp32-hid-dongle / ProtocolAnalyzer):
   * p[16..17]=button BE, p[18]=wheel — KHÔNG phải p[16]=wheel. */
  uint16_t btn = ((uint16_t)p[16] << 8) | p[17];
  int8_t wheel = (int8_t)p[18];

  if (d->calibrating) {
    d->bias_sum[0] += gx;
    d->bias_sum[1] += gy;
    d->bias_sum[2] += gz;
    d->bias_samples++;
    if (d->bias_samples >= kBiasWarmup) {
      d->gyro_bias[0] = d->bias_sum[0] / d->bias_samples;
      d->gyro_bias[1] = d->bias_sum[1] / d->bias_samples;
      d->gyro_bias[2] = d->bias_sum[2] / d->bias_samples;
      d->calibrating = false;
#ifndef HOST_TEST
      ESP_LOGI(TAG, "gyro bias ready");
#endif
    }
  } else {
    double cx = gx - d->gyro_bias[0];
    double cy = gy - d->gyro_bias[1];
    double cz = gz - d->gyro_bias[2];
    /* Bias nhẹ khi đứng yên (giống Studio) — tránh “hút” khi rê chậm. */
    if (fabs(cx) < kStill && fabs(cz) < kStill) {
      const double b = 0.0015;
      d->gyro_bias[0] = (1 - b) * d->gyro_bias[0] + b * gx;
      d->gyro_bias[1] = (1 - b) * d->gyro_bias[1] + b * gy;
      d->gyro_bias[2] = (1 - b) * d->gyro_bias[2] + b * gz;
      cx = gx - d->gyro_bias[0];
      cy = gy - d->gyro_bias[1];
      cz = gz - d->gyro_bias[2];
    }
    d->gyro_lpf[0] = kLpf * cx + (1 - kLpf) * d->gyro_lpf[0];
    d->gyro_lpf[1] = kLpf * cy + (1 - kLpf) * d->gyro_lpf[1];
    d->gyro_lpf[2] = kLpf * cz + (1 - kLpf) * d->gyro_lpf[2];

    double sx = soft_axis(d, d->gyro_lpf[2]) * d->sens;
    double sy = soft_axis(d, d->gyro_lpf[0]) * d->sens;
    if (fabs(d->gyro_lpf[0]) > d->thresh || fabs(d->gyro_lpf[2]) > d->thresh)
      d->pointer_mode = true;

    if (sx == 0.0 && sy == 0.0) {
      /* Giữ fractional carry khi qua deadzone ngắn; chỉ clear sau ~80ms đứng yên. */
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

  /* Wheel: kênh riêng — không chung accumulator với cursor. */
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
