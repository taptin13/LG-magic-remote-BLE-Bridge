#pragma once
#include "bridge_packet.h"
#include <stddef.h>
#include <stdint.h>

// Decode LG HID report 0xFD → motion / button bus events
class RemoteDecoder {
 public:
  void reset();
  void setSens(float s) { sens_ = s; }
  void setThresh(float t) { thresh_ = t; }
  void setDead(float d) { softDead_ = d; }
  void setInvert(bool x, bool y) { invX_ = x; invY_ = y; }

  /// Gọi mỗi frame FD (19+ bytes payload, không gồm report id).
  void onFD(const uint8_t *p, size_t len);

 private:
  double softAxis(double v) const;
  void publishMotion(int16_t dx, int16_t dy, uint16_t buttons);
  void publishButton(uint16_t code, bool down);

  float sens_ = 0.045f;
  float thresh_ = 280.f;
  float softDead_ = 28.f;
  bool invX_ = false;
  bool invY_ = false;

  double gyroLPF_[3] = {0, 0, 0};
  double gyroBias_[3] = {0, 0, 0};
  double biasSum_[3] = {0, 0, 0};
  int biasSamples_ = 0;
  bool calibrating_ = true;
  bool pointerMode_ = false;
  double carryX_ = 0, carryY_ = 0;
  int stillFrames_ = 0;
  uint16_t lastBtn_ = 0;
  uint16_t mouseButtons_ = 0;
};
