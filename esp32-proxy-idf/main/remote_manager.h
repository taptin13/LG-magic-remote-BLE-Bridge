#pragma once
#include "remote_decoder.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void remote_manager_init(remote_decoder_t *decoder);
void remote_manager_tick(void);
const char *remote_manager_state_name(void);
bool remote_manager_ready(void);

#ifdef __cplusplus
}
#endif
