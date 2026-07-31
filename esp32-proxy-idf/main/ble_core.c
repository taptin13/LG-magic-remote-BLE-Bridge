#include "ble_core.h"
#include "mac_gatt.h"
#include "remote_manager.h"
#include "bridge_metrics.h"
#include "bridge_fault.h"
#include "config.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_sm.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "BLECORE";

#ifndef BLE_CORE_CMD_Q
#define BLE_CORE_CMD_Q 24
#endif
#ifndef BLE_CORE_EVT_Q
#define BLE_CORE_EVT_Q 32
#endif
#ifndef BLE_CORE_TX_Q
#define BLE_CORE_TX_Q 24
#endif

#define PRESSED_MAX 16

typedef struct {
  bridge_packet_t pkt;
  uint32_t gen;
  uint8_t attempts;
} ble_tx_item_t;

typedef struct {
  ble_disc_ctx_t ctx;
  uint16_t val_h;
  bool used;
} read_arg_t;

static QueueHandle_t s_cmd_q;
static QueueHandle_t s_evt_q;
static QueueHandle_t s_tx_q;
static SemaphoreHandle_t s_wake;
static SemaphoreHandle_t s_tx_mu;
static TaskHandle_t s_owner;
static ble_disc_evt_fn s_disc_handler;
static uint8_t s_chr_kind_pending;
static read_arg_t s_read_pool[8];

static bridge_packet_t s_motion_latest;
static bool s_motion_pend;
static uint32_t s_motion_gen;
static uint32_t s_tx_gen = 1;

static uint16_t s_pressed[PRESSED_MAX];
static int s_pressed_n;
/** Release đã quyết định gửi nhưng chưa vào TX queue — retry đến khi enqueue được. */
static uint16_t s_pending_rel[PRESSED_MAX];
static int s_pending_rel_n;

bool ble_core_is_owner(void) {
  return s_owner && xTaskGetCurrentTaskHandle() == s_owner;
}

static read_arg_t *alloc_read_arg(const ble_disc_ctx_t *ctx, uint16_t val_h) {
  for (int i = 0; i < 8; i++) {
    if (!s_read_pool[i].used) {
      s_read_pool[i].used = true;
      s_read_pool[i].ctx = *ctx;
      s_read_pool[i].val_h = val_h;
      return &s_read_pool[i];
    }
  }
  return NULL;
}

static void free_read_arg(void *p) {
  read_arg_t *a = (read_arg_t *)p;
  if (!a) return;
  a->used = false;
}

static void fill_uuid(ble_disc_evt_t *e, const ble_uuid_t *u) {
  e->uuid_type = 0;
  e->uuid16 = 0;
  memset(e->uuid128, 0, sizeof(e->uuid128));
  if (!u) return;
  if (u->type == BLE_UUID_TYPE_16) {
    e->uuid_type = 16;
    e->uuid16 = BLE_UUID16(u)->value;
  } else if (u->type == BLE_UUID_TYPE_128) {
    e->uuid_type = 128;
    memcpy(e->uuid128, BLE_UUID128(u)->value, 16);
  }
}

bool ble_core_post_disc_evt(const ble_disc_evt_t *evt) {
  if (!evt || !s_evt_q) return false;
  if (ble_core_is_owner() && s_disc_handler) {
    s_disc_handler(evt);
    return true;
  }
  if (xQueueSend(s_evt_q, evt, 0) != pdTRUE) {
    bridge_metrics()->tx_overflow++;
    return false;
  }
  if (s_wake) xSemaphoreGive(s_wake);
  return true;
}

static int cb_svc(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *svc,
                  void *arg) {
  ble_disc_ctx_t *ctx = (ble_disc_ctx_t *)arg;
  ble_disc_evt_t e = {0};
  e.kind = BLE_DISC_EVT_SVC;
  if (ctx) e.ctx = *ctx;
  e.conn = conn;
  e.status = error ? error->status : BLE_HS_EUNKNOWN;
  if (svc) {
    e.start_h = svc->start_handle;
    e.end_h = svc->end_handle;
    fill_uuid(&e, &svc->uuid.u);
  }
  ble_core_post_disc_evt(&e);
  return 0;
}

static int cb_chr(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr,
                  void *arg) {
  ble_disc_ctx_t *ctx = (ble_disc_ctx_t *)arg;
  ble_disc_evt_t e = {0};
  e.kind = (s_chr_kind_pending == 2) ? BLE_DISC_EVT_CHR_HID : BLE_DISC_EVT_CHR_D1;
  if (ctx) e.ctx = *ctx;
  e.conn = conn;
  e.status = error ? error->status : BLE_HS_EUNKNOWN;
  if (chr) {
    e.def_h = chr->def_handle;
    e.val_h = chr->val_handle;
    fill_uuid(&e, &chr->uuid.u);
  }
  ble_core_post_disc_evt(&e);
  return 0;
}

static int cb_dsc(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                  const struct ble_gatt_dsc *dsc, void *arg) {
  ble_disc_ctx_t *ctx = (ble_disc_ctx_t *)arg;
  ble_disc_evt_t e = {0};
  e.kind = BLE_DISC_EVT_DSC;
  if (ctx) e.ctx = *ctx;
  e.conn = conn;
  e.status = error ? error->status : BLE_HS_EUNKNOWN;
  e.chr_val_h = chr_val_handle;
  if (dsc) {
    e.dsc_h = dsc->handle;
    fill_uuid(&e, &dsc->uuid.u);
  }
  ble_core_post_disc_evt(&e);
  return 0;
}

static int cb_read(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                   void *arg) {
  read_arg_t *ra = (read_arg_t *)arg;
  ble_disc_evt_t e = {0};
  e.kind = BLE_DISC_EVT_READ2908;
  if (ra) {
    e.ctx = ra->ctx;
    e.tag_val_h = ra->val_h;
  }
  e.conn = conn;
  e.status = error ? error->status : BLE_HS_EUNKNOWN;
  if (error && error->status == 0 && attr && attr->om) {
    uint16_t len = OS_MBUF_PKTLEN(attr->om);
    if (len > sizeof(e.data)) len = sizeof(e.data);
    ble_hs_mbuf_to_flat(attr->om, e.data, len, NULL);
    e.data_len = (uint8_t)len;
  }
  ble_core_post_disc_evt(&e);
  free_read_arg(ra);
  return 0;
}

static int cb_write(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                    void *arg) {
  (void)attr;
  ble_disc_ctx_t *ctx = (ble_disc_ctx_t *)arg;
  ble_disc_evt_t e = {0};
  e.kind = BLE_DISC_EVT_CCCD_WRITE;
  if (ctx) e.ctx = *ctx;
  e.conn = conn;
  e.status = error ? error->status : BLE_HS_EUNKNOWN;
  ble_core_post_disc_evt(&e);
  return 0;
}

void ble_core_init(void) {
  if (s_cmd_q) return;
  s_cmd_q = xQueueCreate(BLE_CORE_CMD_Q, sizeof(ble_core_msg_t));
  s_evt_q = xQueueCreate(BLE_CORE_EVT_Q, sizeof(ble_disc_evt_t));
  s_tx_q = xQueueCreate(BLE_CORE_TX_Q, sizeof(ble_tx_item_t));
  s_wake = xSemaphoreCreateBinary();
  s_tx_mu = xSemaphoreCreateMutex();
  s_tx_gen = 1;
  s_pressed_n = 0;
  s_pending_rel_n = 0;
}

void ble_core_set_disc_handler(ble_disc_evt_fn fn) { s_disc_handler = fn; }

uint32_t ble_core_tx_gen(void) { return s_tx_gen; }

static void pressed_add(uint16_t code) {
  for (int i = 0; i < s_pressed_n; i++)
    if (s_pressed[i] == code) return;
  if (s_pressed_n < PRESSED_MAX) s_pressed[s_pressed_n++] = code;
}

static void pressed_remove(uint16_t code) {
  for (int i = 0; i < s_pressed_n; i++) {
    if (s_pressed[i] == code) {
      s_pressed[i] = s_pressed[--s_pressed_n];
      return;
    }
  }
}

static void pending_rel_add(uint16_t code) {
  for (int i = 0; i < s_pending_rel_n; i++)
    if (s_pending_rel[i] == code) return;
  if (s_pending_rel_n < PRESSED_MAX) s_pending_rel[s_pending_rel_n++] = code;
}

static void note_button_locked(const bridge_packet_t *pkt) {
  if (!pkt || pkt->type != PKT_BUTTON) return;
  if (pkt->u.button.down)
    pressed_add(pkt->u.button.code);
  else
    pressed_remove(pkt->u.button.code);
}

/** Caller holds s_tx_mu. Đẩy pending releases vào TX; không bỏ code nếu enqueue fail. */
static void flush_pending_releases_locked(void) {
  while (s_pending_rel_n > 0) {
    uint16_t code = s_pending_rel[0];
    ble_tx_item_t it = {0};
    it.pkt.type = PKT_BUTTON;
    it.pkt.u.button.code = code;
    it.pkt.u.button.down = 0;
    it.gen = s_tx_gen;
    it.attempts = 0;

    if (xQueueSend(s_tx_q, &it, 0) == pdTRUE) {
      s_pending_rel[0] = s_pending_rel[--s_pending_rel_n];
      bridge_metrics()->button_synthetic_release++;
      continue;
    }

    /* Queue đầy — bỏ item cũ (không phải release) để nhường chỗ. */
    ble_tx_item_t discarded;
    bool enqueued = false;
    while (xQueueReceive(s_tx_q, &discarded, 0) == pdTRUE) {
      if (discarded.pkt.type == PKT_BUTTON && discarded.pkt.u.button.down == 0) {
        /* Giữ release khác trong pending nếu chưa có. */
        pending_rel_add(discarded.pkt.u.button.code);
      } else if (discarded.pkt.type == PKT_BUTTON && discarded.pkt.u.button.down) {
        bridge_metrics()->tx_drop_button++;
        pending_rel_add(discarded.pkt.u.button.code); /* down mất → cần release */
      } else if (discarded.pkt.type == PKT_MOTION) {
        bridge_metrics()->tx_drop_motion++;
      } else {
        bridge_metrics()->tx_drop_other++;
      }
      bridge_metrics()->tx_overflow++;
      if (xQueueSend(s_tx_q, &it, 0) == pdTRUE) {
        s_pending_rel[0] = s_pending_rel[--s_pending_rel_n];
        bridge_metrics()->button_synthetic_release++;
        enqueued = true;
        break;
      }
    }
    if (!enqueued) break; /* vẫn đầy / rỗng bất thường — retry vòng sau */
  }
}

void ble_core_release_pressed_buttons(void) {
  if (!s_tx_mu) return;
  xSemaphoreTake(s_tx_mu, portMAX_DELAY);
  for (int i = 0; i < s_pressed_n; i++) pending_rel_add(s_pressed[i]);
  s_pressed_n = 0;
  flush_pending_releases_locked();
  xSemaphoreGive(s_tx_mu);
  if (s_wake) xSemaphoreGive(s_wake);
}

void ble_core_flush_tx(void) {
  if (!s_tx_mu) return;
  xSemaphoreTake(s_tx_mu, portMAX_DELAY);
  s_tx_gen++;
  s_motion_pend = false;
  if (s_tx_q) xQueueReset(s_tx_q);
  s_pressed_n = 0;
  s_pending_rel_n = 0; /* Mac disconnect — không notify được */
  xSemaphoreGive(s_tx_mu);
}

static void exec_cmd(const ble_core_msg_t *m);

bool ble_core_post(const ble_core_msg_t *msg) {
  if (!msg || !s_cmd_q) return false;
  if (ble_core_is_owner()) {
    exec_cmd(msg);
    return true;
  }
  if (xQueueSend(s_cmd_q, msg, 0) != pdTRUE) {
    ESP_LOGW(TAG, "cmd queue full type=%d", (int)msg->cmd);
    return false;
  }
  if (s_wake) xSemaphoreGive(s_wake);
  return true;
}

bool ble_core_submit_packet(const bridge_packet_t *pkt) {
  if (!pkt || !s_tx_q || !s_tx_mu) return false;

  xSemaphoreTake(s_tx_mu, portMAX_DELAY);
  uint32_t gen = s_tx_gen;

  if (pkt->type == PKT_MOTION) {
    s_motion_latest = *pkt;
    s_motion_pend = true;
    s_motion_gen = gen;
    xSemaphoreGive(s_tx_mu);
    if (s_wake) xSemaphoreGive(s_wake);
    return true;
  }

  note_button_locked(pkt);
  if (bridge_fault_should_overflow()) {
    /* Simulate full queue for button/status path. */
    bridge_metrics()->tx_overflow++;
    if (pkt->type == PKT_BUTTON) {
      if (pkt->u.button.down) pending_rel_add(pkt->u.button.code);
      else pending_rel_add(pkt->u.button.code);
      flush_pending_releases_locked();
    }
    xSemaphoreGive(s_tx_mu);
    return false;
  }
  /* Button-up: cũng đưa vào pending nếu queue đầy — không mất release. */
  if (pkt->type == PKT_BUTTON && !pkt->u.button.down) {
    ble_tx_item_t it = {.pkt = *pkt, .gen = gen, .attempts = 0};
    if (xQueueSend(s_tx_q, &it, 0) != pdTRUE) {
      pending_rel_add(pkt->u.button.code);
      flush_pending_releases_locked();
    }
    xSemaphoreGive(s_tx_mu);
    if (s_wake) xSemaphoreGive(s_wake);
    return true;
  }

  ble_tx_item_t it = {.pkt = *pkt, .gen = gen, .attempts = 0};
  if (xQueueSend(s_tx_q, &it, 0) == pdTRUE) {
    xSemaphoreGive(s_tx_mu);
    if (s_wake) xSemaphoreGive(s_wake);
    return true;
  }

  if (pkt->type == PKT_BUTTON || pkt->type == PKT_STATUS) {
    ble_tx_item_t discarded;
    if (xQueueReceive(s_tx_q, &discarded, 0) == pdTRUE) {
      bridge_metrics()->tx_overflow++;
      if (discarded.pkt.type == PKT_BUTTON) {
        bridge_metrics()->tx_drop_button++;
        if (discarded.pkt.u.button.down)
          pending_rel_add(discarded.pkt.u.button.code);
        else
          pending_rel_add(discarded.pkt.u.button.code);
      } else if (discarded.pkt.type == PKT_MOTION) {
        bridge_metrics()->tx_drop_motion++;
      } else {
        bridge_metrics()->tx_drop_other++;
      }
      if (xQueueSend(s_tx_q, &it, 0) == pdTRUE) {
        flush_pending_releases_locked();
        xSemaphoreGive(s_tx_mu);
        if (s_wake) xSemaphoreGive(s_wake);
        return true;
      }
    }
  } else {
    bridge_metrics()->tx_drop_other++;
  }
  if (pkt->type == PKT_BUTTON && pkt->u.button.down) {
    pressed_remove(pkt->u.button.code);
    pending_rel_add(pkt->u.button.code); /* down không vào queue → cần release path */
  }
  flush_pending_releases_locked();
  xSemaphoreGive(s_tx_mu);
  return false;
}

static void drain_tx(int64_t budget_us) {
  int64_t t0 = esp_timer_get_time();
  while (esp_timer_get_time() - t0 < budget_us) {
    ble_tx_item_t it;
    bool got = false;
    uint32_t gen = 0;

    xSemaphoreTake(s_tx_mu, portMAX_DELAY);
    flush_pending_releases_locked();
    gen = s_tx_gen;

    if (xQueueReceive(s_tx_q, &it, 0) == pdTRUE) {
      got = true;
    } else if (s_motion_pend) {
      it.pkt = s_motion_latest;
      it.gen = s_motion_gen;
      it.attempts = 0;
      s_motion_pend = false;
      got = true;
    }

    if (!got) {
      xSemaphoreGive(s_tx_mu);
      break;
    }

    if (it.gen != gen) {
      xSemaphoreGive(s_tx_mu);
      continue; /* stale after flush */
    }
    xSemaphoreGive(s_tx_mu);

    if (!mac_gatt_mac_ready()) continue;
    if (bridge_fault_should_drop_tx()) {
      bridge_metrics()->tx_notify_fail++;
      continue;
    }
    if (mac_gatt_notify_raw(&it.pkt)) continue;

    bridge_metrics()->tx_notify_fail++;
    if (it.pkt.type == PKT_MOTION) {
      bridge_metrics()->tx_drop_motion++;
      continue;
    }
    if (it.attempts + 1 >= BRIDGE_NOTIFY_MAX_RETRY) {
      if (it.pkt.type == PKT_BUTTON && it.pkt.u.button.down) {
        xSemaphoreTake(s_tx_mu, portMAX_DELAY);
        pending_rel_add(it.pkt.u.button.code);
        flush_pending_releases_locked();
        xSemaphoreGive(s_tx_mu);
      }
      continue;
    }

    xSemaphoreTake(s_tx_mu, portMAX_DELAY);
    if (it.gen == s_tx_gen) {
      it.attempts++;
      it.gen = s_tx_gen;
      if (xQueueSendToFront(s_tx_q, &it, 0) != pdTRUE) {
        if (it.pkt.type == PKT_BUTTON && it.pkt.u.button.down)
          pending_rel_add(it.pkt.u.button.code);
        else if (it.pkt.type == PKT_BUTTON && !it.pkt.u.button.down)
          pending_rel_add(it.pkt.u.button.code);
      }
    }
    xSemaphoreGive(s_tx_mu);
    break;
  }
}

int ble_core_do_scan_cancel(void) { return ble_gap_disc_cancel(); }

int ble_core_do_scan_start(uint8_t own_addr_type, uint32_t duration_ms, ble_gap_event_fn *cb) {
  struct ble_gap_disc_params dp = {0};
  dp.passive = 0;
  dp.limited = 0;
  dp.filter_duplicates = 0;
  dp.itvl = SCAN_INTERVAL;
  dp.window = SCAN_WINDOW;
  int rc = ble_gap_disc(own_addr_type, duration_ms, &dp, cb, NULL);
  if (rc != 0) ESP_LOGW(TAG, "disc rc=%d", rc);
  return rc;
}

int ble_core_do_connect(uint8_t own_addr_type, const ble_addr_t *addr, ble_gap_event_fn *cb) {
  if (!addr) return BLE_HS_EINVAL;
  int rc = ble_gap_connect(own_addr_type, addr, 30000, NULL, cb, NULL);
  if (rc != 0) ESP_LOGW(TAG, "connect rc=%d", rc);
  return rc;
}

int ble_core_do_disconnect(uint16_t conn) {
  if (conn == BLE_HS_CONN_HANDLE_NONE) return 0;
  return ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
}

int ble_core_do_security(uint16_t conn) {
  if (conn == BLE_HS_CONN_HANDLE_NONE) return BLE_HS_EINVAL;
  int rc = ble_gap_security_initiate(conn);
  ESP_LOGI(TAG, "security_initiate rc=%d", rc);
  return rc;
}

int ble_core_do_gap_update(uint16_t conn, const struct ble_gap_upd_params *up) {
  if (conn == BLE_HS_CONN_HANDLE_NONE || !up) return BLE_HS_EINVAL;
  return ble_gap_update_params(conn, up);
}

/* Persistent ctx copies for NimBLE async ops (arg must outlive callback). */
static ble_disc_ctx_t s_op_ctx_svc;
static ble_disc_ctx_t s_op_ctx_chr;
static ble_disc_ctx_t s_op_ctx_dsc;
static ble_disc_ctx_t s_op_ctx_write;

int ble_core_do_gattc_disc_svcs(uint16_t conn, const ble_disc_ctx_t *ctx) {
  if (!ctx) return BLE_HS_EINVAL;
  s_op_ctx_svc = *ctx;
  return ble_gattc_disc_all_svcs(conn, cb_svc, &s_op_ctx_svc);
}

int ble_core_do_gattc_disc_chrs(uint16_t conn, uint16_t start, uint16_t end, uint8_t kind,
                                const ble_disc_ctx_t *ctx) {
  if (!ctx) return BLE_HS_EINVAL;
  s_op_ctx_chr = *ctx;
  s_chr_kind_pending = kind;
  return ble_gattc_disc_all_chrs(conn, start, end, cb_chr, &s_op_ctx_chr);
}

int ble_core_do_gattc_disc_dscs(uint16_t conn, uint16_t start, uint16_t end,
                                const ble_disc_ctx_t *ctx) {
  if (!ctx) return BLE_HS_EINVAL;
  s_op_ctx_dsc = *ctx;
  return ble_gattc_disc_all_dscs(conn, start, end, cb_dsc, &s_op_ctx_dsc);
}

int ble_core_do_gattc_read(uint16_t conn, uint16_t handle, uint16_t tag_val_h,
                           const ble_disc_ctx_t *ctx) {
  if (!ctx) return BLE_HS_EINVAL;
  read_arg_t *ra = alloc_read_arg(ctx, tag_val_h);
  if (!ra) return BLE_HS_ENOMEM;
  int rc = ble_gattc_read(conn, handle, cb_read, ra);
  if (rc != 0) free_read_arg(ra);
  return rc;
}

int ble_core_do_gattc_write(uint16_t conn, uint16_t handle, const uint8_t *data, uint8_t len,
                            const ble_disc_ctx_t *ctx) {
  if (!ctx || !data || len > 4) return BLE_HS_EINVAL;
  s_op_ctx_write = *ctx;
  return ble_gattc_write_flat(conn, handle, data, len, cb_write, &s_op_ctx_write);
}

int ble_core_do_gattc_write_no_rsp(uint16_t conn, uint16_t handle, const uint8_t *data,
                                   uint8_t len) {
  if (!data) return BLE_HS_EINVAL;
  return ble_gattc_write_no_rsp_flat(conn, handle, data, len);
}

int ble_core_do_sm_inject(uint16_t conn, uint8_t action, uint32_t passkey) {
  struct ble_sm_io pkey = {0};
  pkey.action = action;
  if (action == BLE_SM_IOACT_NUMCMP)
    pkey.numcmp_accept = passkey ? 1 : 0;
  else
    pkey.passkey = passkey;
  return ble_sm_inject_io(conn, &pkey);
}

static void exec_cmd(const ble_core_msg_t *m) {
  switch (m->cmd) {
    case BLE_CMD_ADV_START:
      mac_gatt_adv_start_raw();
      break;
    case BLE_CMD_ADV_STOP:
      ble_gap_adv_stop();
      break;
    case BLE_CMD_SCAN_CANCEL:
      (void)ble_core_do_scan_cancel();
      break;
    case BLE_CMD_SCAN_START:
      (void)ble_core_do_scan_start(m->own_addr_type, m->scan_ms, m->gap_cb);
      break;
    case BLE_CMD_CONNECT:
      (void)ble_core_do_connect(m->own_addr_type, &m->addr, m->gap_cb);
      break;
    case BLE_CMD_DISCONNECT:
      (void)ble_core_do_disconnect(m->conn);
      break;
    case BLE_CMD_SECURITY:
      (void)ble_core_do_security(m->conn);
      break;
    case BLE_CMD_SET_STATUS:
      mac_gatt_set_status_raw(m->status_byte);
      break;
    case BLE_CMD_FLUSH_TX:
      ble_core_flush_tx();
      break;
    case BLE_CMD_GAP_UPDATE:
      (void)ble_core_do_gap_update(m->conn, &m->upd);
      break;
    case BLE_CMD_GATTC_DISC_SVCS:
      if (ble_core_do_gattc_disc_svcs(m->conn, &m->disc_ctx) != 0)
        ESP_LOGW(TAG, "disc svcs fail");
      break;
    case BLE_CMD_GATTC_DISC_CHRS:
      if (ble_core_do_gattc_disc_chrs(m->conn, m->start_h, m->end_h, m->disc_chr_kind,
                                      &m->disc_ctx) != 0)
        ESP_LOGW(TAG, "disc chrs fail");
      break;
    case BLE_CMD_GATTC_DISC_DSCS:
      if (ble_core_do_gattc_disc_dscs(m->conn, m->start_h, m->end_h, &m->disc_ctx) != 0)
        ESP_LOGW(TAG, "disc dscs fail");
      break;
    case BLE_CMD_GATTC_READ:
      if (ble_core_do_gattc_read(m->conn, m->attr_h, (uint16_t)m->cb_tag, &m->disc_ctx) != 0)
        ESP_LOGW(TAG, "gattc read fail");
      break;
    case BLE_CMD_GATTC_WRITE:
      if (ble_core_do_gattc_write(m->conn, m->attr_h, m->write_buf, m->write_len, &m->disc_ctx) !=
          0)
        ESP_LOGW(TAG, "gattc write fail");
      break;
    case BLE_CMD_GATTC_WRITE_NO_RSP:
      (void)ble_core_do_gattc_write_no_rsp(m->conn, m->attr_h, m->write_buf, m->write_len);
      break;
    case BLE_CMD_SM_INJECT:
      (void)ble_core_do_sm_inject(m->conn, m->sm_action, m->sm_passkey);
      break;
    case BLE_CMD_RELEASE_BUTTONS:
      ble_core_release_pressed_buttons();
      break;
    default:
      break;
  }
}

static void drain_disc_evts(int64_t budget_us) {
  if (!s_disc_handler) return;
  int64_t t0 = esp_timer_get_time();
  ble_disc_evt_t e;
  while (esp_timer_get_time() - t0 < budget_us) {
    if (xQueueReceive(s_evt_q, &e, 0) != pdTRUE) break;
    s_disc_handler(&e);
  }
}

static void ble_core_task(void *arg) {
  (void)arg;
  s_owner = xTaskGetCurrentTaskHandle();
  ESP_LOGI(TAG, "BleCoreTask — sole NimBLE app owner");
  while (!ble_hs_synced()) vTaskDelay(pdMS_TO_TICKS(20));

  for (;;) {
    /* 1) Control commands first */
    ble_core_msg_t msg;
    int cmd_budget = 12;
    while (cmd_budget-- > 0 && xQueueReceive(s_cmd_q, &msg, 0) == pdTRUE) {
      exec_cmd(&msg);
    }
    /* 2) Discovery events (state machine) */
    drain_disc_evts(4000);
    /* 3) TX with time budget */
    drain_tx(3000);
    /* 4) Light connection tick */
    remote_manager_tick();

    if (s_wake) {
      xSemaphoreTake(s_wake, pdMS_TO_TICKS(8));
    } else {
      vTaskDelay(pdMS_TO_TICKS(8));
    }
  }
}

void ble_core_start(void) {
  ble_core_init();
  xTaskCreatePinnedToCore(ble_core_task, "bleCore", 8192, NULL, 9, NULL, 0);
}

void ble_core_cmd_adv_start(void) {
  ble_core_msg_t m = {.cmd = BLE_CMD_ADV_START};
  ble_core_post(&m);
}
void ble_core_cmd_adv_stop(void) {
  ble_core_msg_t m = {.cmd = BLE_CMD_ADV_STOP};
  ble_core_post(&m);
}
void ble_core_cmd_scan_start(uint8_t own_addr_type, uint32_t duration_ms, ble_gap_event_fn *cb) {
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_SCAN_START;
  m.own_addr_type = own_addr_type;
  m.scan_ms = duration_ms;
  m.gap_cb = cb;
  ble_core_post(&m);
}
void ble_core_cmd_scan_cancel(void) {
  ble_core_msg_t m = {.cmd = BLE_CMD_SCAN_CANCEL};
  ble_core_post(&m);
}
void ble_core_cmd_connect(uint8_t own_addr_type, const ble_addr_t *addr, ble_gap_event_fn *cb) {
  if (!addr) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_CONNECT;
  m.own_addr_type = own_addr_type;
  m.addr = *addr;
  m.gap_cb = cb;
  ble_core_post(&m);
}
void ble_core_cmd_disconnect(uint16_t conn) {
  ble_core_msg_t m = {.cmd = BLE_CMD_DISCONNECT, .conn = conn};
  ble_core_post(&m);
}
void ble_core_cmd_security(uint16_t conn) {
  ble_core_msg_t m = {.cmd = BLE_CMD_SECURITY, .conn = conn};
  ble_core_post(&m);
}
void ble_core_cmd_set_status(uint8_t st) {
  ble_core_msg_t m = {.cmd = BLE_CMD_SET_STATUS, .status_byte = st};
  ble_core_post(&m);
}
void ble_core_cmd_gap_update(uint16_t conn, const struct ble_gap_upd_params *up) {
  if (!up) return;
  ble_core_msg_t m = {.cmd = BLE_CMD_GAP_UPDATE, .conn = conn, .upd = *up};
  ble_core_post(&m);
}
void ble_core_cmd_gattc_disc_svcs(uint16_t conn, const ble_disc_ctx_t *ctx) {
  if (!ctx) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_DISC_SVCS;
  m.conn = conn;
  m.disc_ctx = *ctx;
  ble_core_post(&m);
}
void ble_core_cmd_gattc_disc_chrs(uint16_t conn, uint16_t start, uint16_t end, uint8_t kind,
                                  const ble_disc_ctx_t *ctx) {
  if (!ctx) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_DISC_CHRS;
  m.conn = conn;
  m.start_h = start;
  m.end_h = end;
  m.disc_chr_kind = kind;
  m.disc_ctx = *ctx;
  ble_core_post(&m);
}
void ble_core_cmd_gattc_disc_dscs(uint16_t conn, uint16_t start, uint16_t end,
                                  const ble_disc_ctx_t *ctx) {
  if (!ctx) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_DISC_DSCS;
  m.conn = conn;
  m.start_h = start;
  m.end_h = end;
  m.disc_ctx = *ctx;
  ble_core_post(&m);
}
void ble_core_cmd_gattc_read(uint16_t conn, uint16_t handle, uint16_t tag_val_h,
                             const ble_disc_ctx_t *ctx) {
  if (!ctx) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_READ;
  m.conn = conn;
  m.attr_h = handle;
  m.cb_tag = tag_val_h;
  m.disc_ctx = *ctx;
  ble_core_post(&m);
}
void ble_core_cmd_gattc_write(uint16_t conn, uint16_t handle, const uint8_t *data, uint8_t len,
                              const ble_disc_ctx_t *ctx) {
  if (!ctx || !data || len > 4) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_WRITE;
  m.conn = conn;
  m.attr_h = handle;
  m.write_len = len;
  memcpy(m.write_buf, data, len);
  m.disc_ctx = *ctx;
  ble_core_post(&m);
}
void ble_core_cmd_gattc_write_no_rsp(uint16_t conn, uint16_t handle, const uint8_t *data,
                                     uint8_t len) {
  if (!data || len > 4) return;
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_GATTC_WRITE_NO_RSP;
  m.conn = conn;
  m.attr_h = handle;
  m.write_len = len;
  memcpy(m.write_buf, data, len);
  ble_core_post(&m);
}
void ble_core_cmd_sm_inject(uint16_t conn, uint8_t action, uint32_t passkey) {
  ble_core_msg_t m = {0};
  m.cmd = BLE_CMD_SM_INJECT;
  m.conn = conn;
  m.sm_action = action;
  m.sm_passkey = passkey;
  ble_core_post(&m);
}
void ble_core_cmd_flush_tx(void) {
  ble_core_msg_t m = {.cmd = BLE_CMD_FLUSH_TX};
  ble_core_post(&m);
}
void ble_core_cmd_release_buttons(void) {
  ble_core_msg_t m = {.cmd = BLE_CMD_RELEASE_BUTTONS};
  ble_core_post(&m);
}
