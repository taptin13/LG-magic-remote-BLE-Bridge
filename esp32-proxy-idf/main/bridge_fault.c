#include "bridge_fault.h"

static bridge_fault_t s_fault;

void bridge_fault_reset(void) { s_fault = (bridge_fault_t){0}; }

bridge_fault_t *bridge_fault(void) { return &s_fault; }

#if BRIDGE_FAULT_INJECT
bool bridge_fault_should_drop_tx(void) {
  if (s_fault.drop_next_tx == 0) return false;
  s_fault.drop_next_tx--;
  return true;
}

bool bridge_fault_should_overflow(void) {
  if (s_fault.force_tx_overflow == 0) return false;
  s_fault.force_tx_overflow--;
  return true;
}
#endif
