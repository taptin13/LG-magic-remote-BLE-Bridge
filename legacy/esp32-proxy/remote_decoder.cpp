#include "remote_decoder.h"
#include "event_bus.h"
#include <Arduino.h>
#include <math.h>
#include <string.h>

static const int kBiasWarmup = 60;
static const double kLpfAlpha = 0.42;
static const double kStillGate = 70.0;
static const int kStillFramesBeforeBias = 40;
static const uint16_t kBtnOK = 0x8044;
static const uint16_t kBtnSettings = 0x8043;
static const uint16_t kBtnVoice = 0x808B;

void RemoteDecoder::reset() {
  memset(gyroLPF_, 0, sizeof(gyroLPF_));
  memset(gyroBias_, 0, sizeof(gyroBias_));
  memset(biasSum_, 0, sizeof(biasSum_));
  biasSamples_ = 0;
  calibrating_ = true;
  pointerMode_ = false;
  carryX_ = carryY_ = 0;
  stillFrames_ = 0;
  lastBtn_ = 0;
  mouseButtons_ = 0;
}

double RemoteDecoder::softAxis(double v) const {
  double a = fabs(v);
  if (a <= softDead_) return 0;
  double excess = a - softDead_;
  double shaped = excess + excess * excess * 0.0008;
  return v < 0 ? -shaped : shaped;
}

void RemoteDecoder::publishMotion(int16_t dx, int16_t dy, uint16_t buttons) {
  BusEvent ev{};
  ev.type = BUS_MOTION;
  ev.u.motion = {dx, dy, buttons};
  eventBusPublish(&ev);
}

void RemoteDecoder::publishButton(uint16_t code, bool down) {
  BusEvent ev{};
  ev.type = BUS_BUTTON;
  ev.u.button = {code, (uint8_t)(down ? 1 : 0)};
  eventBusPublish(&ev);
}

void RemoteDecoder::onFD(const uint8_t *p, size_t len) {
  if (len < 19) return;

  int16_t imu[6];
  for (int i = 0; i < 6; i++) {
    uint16_t raw = ((uint16_t)p[4 + i * 2] << 8) | p[5 + i * 2];
    imu[i] = (int16_t)raw;
  }
  double gx = imu[0], gy = imu[1], gz = imu[2];
  int8_t wheel = (int8_t)p[16];
  uint16_t btn = ((uint16_t)p[17] << 8) | p[18];

  if (calibrating_) {
    biasSum_[0] += gx;
    biasSum_[1] += gy;
    biasSum_[2] += gz;
    biasSamples_++;
    if (biasSamples_ >= kBiasWarmup) {
      gyroBias_[0] = biasSum_[0] / biasSamples_;
      gyroBias_[1] = biasSum_[1] / biasSamples_;
      gyroBias_[2] = biasSum_[2] / biasSamples_;
      calibrating_ = false;
      Serial.printf("[DEC] gyro bias ready\n");
    }
  } else {
    double cx = gx - gyroBias_[0];
    double cy = gy - gyroBias_[1];
    double cz = gz - gyroBias_[2];
    if (fabs(cx) < kStillGate && fabs(cz) < kStillGate) {
      stillFrames_++;
      double b = stillFrames_ >= kStillFramesBeforeBias ? 0.012 : 0.0015;
      gyroBias_[0] = (1 - b) * gyroBias_[0] + b * gx;
      gyroBias_[1] = (1 - b) * gyroBias_[1] + b * gy;
      gyroBias_[2] = (1 - b) * gyroBias_[2] + b * gz;
      cx = gx - gyroBias_[0];
      cy = gy - gyroBias_[1];
      cz = gz - gyroBias_[2];
    } else {
      stillFrames_ = 0;
    }

    const double a = kLpfAlpha;
    gyroLPF_[0] = a * cx + (1 - a) * gyroLPF_[0];
    gyroLPF_[1] = a * cy + (1 - a) * gyroLPF_[1];
    gyroLPF_[2] = a * cz + (1 - a) * gyroLPF_[2];

    double sx = softAxis(gyroLPF_[2]) * sens_;
    double sy = softAxis(gyroLPF_[0]) * sens_;
    if (invX_) sx = -sx;
    if (invY_) sy = -sy;
    if (fabs(gyroLPF_[0]) > thresh_ || fabs(gyroLPF_[2]) > thresh_) pointerMode_ = true;

    if (sx == 0.0 && sy == 0.0) {
      carryX_ = carryY_ = 0;
    } else {
      carryX_ += sx;
      carryY_ += sy;
      int idx = (int)trunc(carryX_);
      int idy = (int)trunc(carryY_);
      carryX_ -= idx;
      carryY_ -= idy;
      while (idx != 0 || idy != 0) {
        int16_t dx = (int16_t)constrain(idx, -127, 127);
        int16_t dy = (int16_t)constrain(idy, -127, 127);
        idx -= dx;
        idy -= dy;
        publishMotion(dx, dy, mouseButtons_);
      }
    }
  }

  if (wheel != 0 && pointerMode_) {
    // scroll as button codes 0xF010 / 0xF011 (Mac map)
    publishButton(wheel > 0 ? 0xF010 : 0xF011, true);
    publishButton(wheel > 0 ? 0xF010 : 0xF011, false);
  }

  if (btn == lastBtn_) return;
  uint16_t prev = lastBtn_;
  lastBtn_ = btn;

  if (prev != 0) {
    if (prev == kBtnOK) mouseButtons_ &= ~0x0001;
    else if (prev == kBtnSettings) mouseButtons_ &= ~0x0002;
    else publishButton(prev, false);
    if (prev == kBtnOK || prev == kBtnSettings) {
      publishMotion(0, 0, mouseButtons_);
    }
  }
  if (btn != 0) {
    if (btn == kBtnOK) {
      mouseButtons_ |= 0x0001;
      publishMotion(0, 0, mouseButtons_);
    } else if (btn == kBtnSettings) {
      mouseButtons_ |= 0x0002;
      publishMotion(0, 0, mouseButtons_);
    } else {
      publishButton(btn, true);
    }
  }
}
