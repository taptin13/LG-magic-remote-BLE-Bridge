#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Fault injection (compile with -DBRIDGE_FAULT_INJECT=1).
 * Host tests exercise the flag API; firmware optionally gates TX path.
 */

#ifndef BRIDGE_FAULT_INJECT
#define BRIDGE_FAULT_INJECT 0
#endif

typedef struct {
  uint32_t drop_next_tx;
  uint32_t force_tx_overflow;
  uint32_t inject_session_mismatch;
} bridge_fault_t;

void bridge_fault_reset(void);
bridge_fault_t *bridge_fault(void);

#if BRIDGE_FAULT_INJECT
bool bridge_fault_should_drop_tx(void);
bool bridge_fault_should_overflow(void);
#else
static inline bool bridge_fault_should_drop_tx(void) { return false; }
static inline bool bridge_fault_should_overflow(void) { return false; }
#endif

#ifdef __cplusplus
}
#endif
