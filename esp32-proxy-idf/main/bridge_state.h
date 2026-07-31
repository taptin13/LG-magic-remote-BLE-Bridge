#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  MAC_ADV = 0,
  MAC_CONNECTED,
  MAC_ENCRYPTED,
  MAC_EVENT_SUBSCRIBED,
  MAC_READY,
} mac_link_state_t;

typedef enum {
  REM_IDLE = 0,
  REM_WAIT_MAC,
  REM_SCANNING,
  REM_CONNECTING,
  REM_ENCRYPTED,
  REM_DISCOVERING,
  REM_SUBSCRIBED,
  REM_READY,
  REM_RECOVERING,
} remote_link_state_t;

typedef enum {
  BRIDGE_WAIT_MAC = 0,
  BRIDGE_WAIT_REMOTE,
  BRIDGE_STREAMING,
  BRIDGE_RECOVERING,
} bridge_overall_state_t;

void bridge_state_init(void);

void bridge_state_set_mac(mac_link_state_t s);
void bridge_state_set_remote(remote_link_state_t s);
void bridge_state_recompute_overall(void);

mac_link_state_t bridge_state_mac(void);
remote_link_state_t bridge_state_remote(void);
bridge_overall_state_t bridge_state_overall(void);

uint32_t bridge_session_mac(void);
uint32_t bridge_session_remote(void);
uint32_t bridge_session_bump_mac(void);
uint32_t bridge_session_bump_remote(void);

const char *bridge_state_mac_name(void);
const char *bridge_state_remote_name(void);
const char *bridge_state_overall_name(void);

#ifdef __cplusplus
}
#endif
