#pragma once
#include "bridge_packet.h"
#include "host/ble_hs.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Sole application owner of NimBLE GAP / GATTC / Event notify. */

typedef struct {
  uint16_t conn;
  uint32_t conn_gen;
  uint32_t disc_gen;
} ble_disc_ctx_t;

typedef enum {
  BLE_CMD_NOP = 0,
  BLE_CMD_ADV_START,
  BLE_CMD_ADV_STOP,
  BLE_CMD_SCAN_START,
  BLE_CMD_SCAN_CANCEL,
  BLE_CMD_CONNECT,
  BLE_CMD_DISCONNECT,
  BLE_CMD_SECURITY,
  BLE_CMD_SET_STATUS,
  BLE_CMD_FLUSH_TX,
  BLE_CMD_GAP_UPDATE,
  BLE_CMD_GATTC_DISC_SVCS,
  BLE_CMD_GATTC_DISC_CHRS,
  BLE_CMD_GATTC_DISC_DSCS,
  BLE_CMD_GATTC_READ,
  BLE_CMD_GATTC_WRITE,
  BLE_CMD_GATTC_WRITE_NO_RSP,
  BLE_CMD_SM_INJECT,
  BLE_CMD_RELEASE_BUTTONS,
} ble_core_cmd_t;

typedef enum {
  BLE_DISC_EVT_NONE = 0,
  BLE_DISC_EVT_SVC,
  BLE_DISC_EVT_CHR_D1,
  BLE_DISC_EVT_CHR_HID,
  BLE_DISC_EVT_CHR_BATTERY,
  BLE_DISC_EVT_DSC,
  BLE_DISC_EVT_READ2908,
  BLE_DISC_EVT_READ_BATTERY,
  BLE_DISC_EVT_CCCD_WRITE,
} ble_disc_evt_kind_t;

typedef struct {
  ble_disc_evt_kind_t kind;
  ble_disc_ctx_t ctx;
  uint16_t conn;
  uint16_t status; /* ble_gatt_error.status */
  uint16_t start_h;
  uint16_t end_h;
  uint16_t val_h;
  uint16_t def_h;
  uint16_t dsc_h;
  uint16_t chr_val_h;
  uint16_t uuid16;
  uint8_t uuid_type; /* 0=none, 16, 128 */
  uint8_t uuid128[16];
  uint8_t data[4];
  uint8_t data_len;
  uint16_t tag_val_h; /* for 2908 */
} ble_disc_evt_t;

typedef struct {
  ble_core_cmd_t cmd;
  uint16_t conn;
  uint8_t status_byte;
  ble_addr_t addr;
  uint8_t own_addr_type;
  uint32_t scan_ms;
  uint32_t connect_ms;
  ble_gap_event_fn *gap_cb;
  struct ble_gap_upd_params upd;
  ble_disc_ctx_t disc_ctx;
  uint16_t start_h;
  uint16_t end_h;
  uint16_t attr_h;
  uint8_t write_buf[4];
  uint8_t write_len;
  uint8_t disc_chr_kind; /* 1=d1 2=hid 3=battery */
  uint8_t read_kind; /* BLE_DISC_EVT_READ* */
  uint8_t sm_action;
  uint32_t sm_passkey;
  uintptr_t cb_tag;
} ble_core_msg_t;

typedef void (*ble_disc_evt_fn)(const ble_disc_evt_t *evt);

void ble_core_init(void);
void ble_core_start(void);
void ble_core_wake(void);
void ble_core_set_disc_handler(ble_disc_evt_fn fn);

bool ble_core_is_owner(void);
bool ble_core_post(const ble_core_msg_t *msg);
bool ble_core_post_disc_evt(const ble_disc_evt_t *evt);

bool ble_core_submit_packet(const bridge_packet_t *pkt);
void ble_core_flush_tx(void);
/** Drop only relative motion; reliable button/status traffic is preserved. */
void ble_core_drop_motion(void);
uint32_t ble_core_tx_gen(void);
void ble_core_release_pressed_buttons(void);

/** Sync ops — BleCoreTask only. */
int ble_core_do_scan_cancel(void);
int ble_core_do_scan_start(uint8_t own_addr_type, uint32_t duration_ms, ble_gap_event_fn *cb);
int ble_core_do_connect(uint8_t own_addr_type, const ble_addr_t *addr, uint32_t timeout_ms,
                        ble_gap_event_fn *cb);
int ble_core_do_disconnect(uint16_t conn);
int ble_core_do_security(uint16_t conn);
int ble_core_do_gap_update(uint16_t conn, const struct ble_gap_upd_params *up);
int ble_core_do_gattc_disc_svcs(uint16_t conn, const ble_disc_ctx_t *ctx);
int ble_core_do_gattc_disc_chrs(uint16_t conn, uint16_t start, uint16_t end, uint8_t kind,
                                const ble_disc_ctx_t *ctx);
int ble_core_do_gattc_disc_dscs(uint16_t conn, uint16_t start, uint16_t end,
                                const ble_disc_ctx_t *ctx);
int ble_core_do_gattc_read(uint16_t conn, uint16_t handle, uint16_t tag_val_h,
                           const ble_disc_ctx_t *ctx, ble_disc_evt_kind_t kind);
int ble_core_do_gattc_write(uint16_t conn, uint16_t handle, const uint8_t *data, uint8_t len,
                            const ble_disc_ctx_t *ctx);
int ble_core_do_gattc_write_no_rsp(uint16_t conn, uint16_t handle, const uint8_t *data,
                                   uint8_t len);
int ble_core_do_sm_inject(uint16_t conn, uint8_t action, uint32_t passkey);

void ble_core_cmd_adv_start(void);
void ble_core_cmd_adv_stop(void);
void ble_core_cmd_scan_start(uint8_t own_addr_type, uint32_t duration_ms, ble_gap_event_fn *cb);
void ble_core_cmd_scan_cancel(void);
void ble_core_cmd_connect(uint8_t own_addr_type, const ble_addr_t *addr, uint32_t timeout_ms,
                          ble_gap_event_fn *cb);
void ble_core_cmd_disconnect(uint16_t conn);
void ble_core_cmd_security(uint16_t conn);
void ble_core_cmd_set_status(uint8_t st);
void ble_core_cmd_gap_update(uint16_t conn, const struct ble_gap_upd_params *up);
void ble_core_cmd_gattc_disc_svcs(uint16_t conn, const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_disc_chrs(uint16_t conn, uint16_t start, uint16_t end, uint8_t kind,
                                  const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_disc_dscs(uint16_t conn, uint16_t start, uint16_t end,
                                  const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_read(uint16_t conn, uint16_t handle, uint16_t tag_val_h,
                             const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_read_battery(uint16_t conn, uint16_t handle, const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_write(uint16_t conn, uint16_t handle, const uint8_t *data, uint8_t len,
                              const ble_disc_ctx_t *ctx);
void ble_core_cmd_gattc_write_no_rsp(uint16_t conn, uint16_t handle, const uint8_t *data,
                                     uint8_t len);
void ble_core_cmd_sm_inject(uint16_t conn, uint8_t action, uint32_t passkey);
void ble_core_cmd_flush_tx(void);
void ble_core_cmd_release_buttons(void);

#ifdef __cplusplus
}
#endif
