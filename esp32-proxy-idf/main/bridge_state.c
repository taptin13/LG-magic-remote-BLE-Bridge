#include "bridge_state.h"

#ifndef HOST_TEST
#include "esp_log.h"
static const char *TAG = "BSTATE";
#define BSTATE_LOGI(...) ESP_LOGI(TAG, __VA_ARGS__)
#else
#define BSTATE_LOGI(...) ((void)0)
#endif

static mac_link_state_t s_mac = MAC_ADV;
static remote_link_state_t s_rem = REM_IDLE;
static bridge_overall_state_t s_all = BRIDGE_WAIT_MAC;
static uint32_t s_mac_sess = 1;
static uint32_t s_rem_sess = 1;

void bridge_state_init(void) {
  s_mac = MAC_ADV;
  s_rem = REM_IDLE;
  s_all = BRIDGE_WAIT_MAC;
  s_mac_sess = 1;
  s_rem_sess = 1;
}

void bridge_state_recompute_overall(void) {
  bridge_overall_state_t next;
  if (s_mac != MAC_READY) {
    next = BRIDGE_WAIT_MAC;
  } else if (s_rem != REM_READY) {
    next = (s_rem == REM_RECOVERING) ? BRIDGE_RECOVERING : BRIDGE_WAIT_REMOTE;
  } else {
    next = BRIDGE_STREAMING;
  }
  if (next != s_all) {
    s_all = next;
    BSTATE_LOGI("overall → %s (mac=%s rem=%s)", bridge_state_overall_name(),
                bridge_state_mac_name(), bridge_state_remote_name());
  }
}

void bridge_state_set_mac(mac_link_state_t s) {
  if (s_mac == s) return;
  s_mac = s;
  BSTATE_LOGI("mac → %s", bridge_state_mac_name());
  bridge_state_recompute_overall();
}

void bridge_state_set_remote(remote_link_state_t s) {
  if (s_rem == s) return;
  s_rem = s;
  BSTATE_LOGI("remote → %s", bridge_state_remote_name());
  bridge_state_recompute_overall();
}

mac_link_state_t bridge_state_mac(void) { return s_mac; }
remote_link_state_t bridge_state_remote(void) { return s_rem; }
bridge_overall_state_t bridge_state_overall(void) { return s_all; }

uint32_t bridge_session_mac(void) { return s_mac_sess; }
uint32_t bridge_session_remote(void) { return s_rem_sess; }

uint32_t bridge_session_bump_mac(void) {
  s_mac_sess++;
  return s_mac_sess;
}

uint32_t bridge_session_bump_remote(void) {
  s_rem_sess++;
  return s_rem_sess;
}

const char *bridge_state_mac_name(void) {
  switch (s_mac) {
    case MAC_ADV: return "Advertising";
    case MAC_CONNECTED: return "Connected";
    case MAC_ENCRYPTED: return "Encrypted";
    case MAC_EVENT_SUBSCRIBED: return "EventSubscribed";
    case MAC_READY: return "MacReady";
    default: return "?";
  }
}

const char *bridge_state_remote_name(void) {
  switch (s_rem) {
    case REM_IDLE: return "Idle";
    case REM_WAIT_MAC: return "WaitMac";
    case REM_SCANNING: return "Scanning";
    case REM_CONNECTING: return "Connecting";
    case REM_ENCRYPTED: return "Encrypted";
    case REM_DISCOVERING: return "Discovering";
    case REM_SUBSCRIBED: return "Subscribed";
    case REM_READY: return "RemoteReady";
    case REM_RECOVERING: return "Recovering";
    default: return "?";
  }
}

const char *bridge_state_overall_name(void) {
  switch (s_all) {
    case BRIDGE_WAIT_MAC: return "WaitingForMac";
    case BRIDGE_WAIT_REMOTE: return "WaitingForRemote";
    case BRIDGE_STREAMING: return "Streaming";
    case BRIDGE_RECOVERING: return "Recovering";
    default: return "?";
  }
}
