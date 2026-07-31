#pragma once
#include "remote_decoder.h"

// Connection Manager — state machine cho LG Remote (Central)
class RemoteManager {
 public:
  enum State : uint8_t {
    Idle = 0,
    WaitMac,
    Scanning,
    Connecting,
    Discover,
    Secure,
    Ready,
    ReconnectWait,
  };

  void begin(RemoteDecoder *decoder);
  void tick();  // gọi từ task / loop — không block lâu
  void onNotify(uint8_t reportId, uint8_t *data, size_t len);
  State state() const { return state_; }
  const char *stateName() const;

 private:
  void setState(State s);
  void startScanBurst();
  void tryConnect();
  bool discoverAndSubscribe();
  void loadCache();
  void saveCache();

  State state_ = Idle;
  RemoteDecoder *decoder_ = nullptr;
  uint32_t stateMs_ = 0;
  uint32_t scanStartedMs_ = 0;
  bool haveTarget_ = false;
  bool doConnect_ = false;
  bool paired_ = false;
  uint8_t targetType_ = 0;
};
