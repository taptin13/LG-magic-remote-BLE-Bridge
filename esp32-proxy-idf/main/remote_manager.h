#pragma once
#include "remote_decoder.h"
#include "host/ble_hs.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void remote_manager_init(remote_decoder_t *decoder);
void remote_manager_tick(void);
const char *remote_manager_state_name(void);
bool remote_manager_ready(void);
bool remote_manager_cached_peer(ble_addr_t *out);

#ifdef __cplusplus
}
#endif
