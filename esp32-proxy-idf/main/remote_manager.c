#include "remote_manager.h"
#include "ble_core.h"
#include "bridge_state.h"
#include "bridge_metrics.h"
#include "config.h"
#include "event_bus.h"
#include "mac_gatt.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/ble_gatt.h"
#include "host/ble_store.h"
#include "host/ble_sm.h"
#include <string.h>

static const char *TAG = "RM";

static remote_decoder_t *s_dec;
static int64_t s_state_ms;
static int64_t s_scan_ms;
static bool s_paired;
static bool s_got_target;
static bool s_do_connect;
static bool s_remote_drop;
static ble_addr_t s_target;
static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint8_t s_own_addr_type;

static uint16_t s_rep_handles[16];
static uint8_t s_rep_ids[16];
static int s_rep_count;

static uint16_t s_d1_start, s_d1_end, s_hid_start, s_hid_end;
static uint16_t s_proto_handle;

/* Chars needing CCCD + optional 2908 */
typedef struct {
  uint16_t val_handle;
  uint16_t end_handle; /* exclusive upper for dsc disc */
  bool need_report_ref;
} chr_job_t;

static chr_job_t s_jobs[24];
static int s_job_n, s_job_i;
static uint16_t s_cccds[16];
static int s_cccd_n, s_cccd_i;
static int s_pending_2908;
static bool s_dsc_jobs_done;
static bool s_disc_ok;
static bool s_disc_fail;
static bool s_need_secure;
static int64_t s_connect_ms;
static int64_t s_reconnect_delay_ms = 400;
static int s_enc_fail_streak;
/** Incremented on each connect/disconnect — stale discovery callbacks are ignored. */
static uint32_t s_conn_gen;
static uint32_t s_disc_gen;
/** Deferred NVS — do not commit flash inside BLE callback. */
static bool s_nvs_dirty;
static ble_addr_t s_nvs_addr;

static const ble_uuid128_t uuid_d1ff = BLE_UUID128_INIT(REMOTE_D1FF_UUID128);
static const ble_uuid16_t uuid_hid = BLE_UUID16_INIT(0x1812);
static const ble_uuid16_t uuid_a001 = BLE_UUID16_INIT(0xA001);
static const ble_uuid16_t uuid_2a4d = BLE_UUID16_INIT(0x2A4D);
static const ble_uuid16_t uuid_2a4e = BLE_UUID16_INIT(0x2A4E);
static const ble_uuid16_t uuid_2902 = BLE_UUID16_INIT(0x2902);
static const ble_uuid16_t uuid_2908 = BLE_UUID16_INIT(0x2908);

static int gap_event(struct ble_gap_event *event, void *arg);
static void start_scan_burst(void);
static void try_connect(void);
static void try_cached_reconnect(void);
static void begin_discover(void);
static void finish_discover_ok(void);
static void discover_fail(void);
static int write_next_cccd(void);
static void run_next_job_dsc(void);

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static void reset_motion_session(void) {
  event_bus_reset_motion();
  ble_core_drop_motion();
  /* Soft reset keeps gyro bias — hard reset made airmouse dead until the
   * remote was held still (~0.6s+), while buttons/scroll still worked. */
  if (s_dec) remote_decoder_reset_session(s_dec);
}

static void remember_report(uint16_t handle, uint8_t id) {
  if (s_rep_count >= 16) return;
  s_rep_handles[s_rep_count] = handle;
  s_rep_ids[s_rep_count] = id;
  s_rep_count++;
}

static uint8_t report_id_for(uint16_t h) {
  for (int i = 0; i < s_rep_count; i++)
    if (s_rep_handles[i] == h) return s_rep_ids[i];
  return 0;
}

static void set_state(remote_link_state_t s) {
  if (bridge_state_remote() == s) return;
  s_state_ms = now_ms();
  bridge_state_set_remote(s);
  ESP_LOGI(TAG, "state → %s", bridge_state_remote_name());
}

const char *remote_manager_state_name(void) { return bridge_state_remote_name(); }

bool remote_manager_ready(void) { return bridge_state_remote() == REM_READY; }

static bool s_have_cached_addr;

static void load_cache(void) {
  nvs_handle_t h;
  s_have_cached_addr = false;
  if (nvs_open("mrproxy", NVS_READONLY, &h) == ESP_OK) {
    uint8_t v = 0;
    if (nvs_get_u8(h, "paired", &v) == ESP_OK) s_paired = (v != 0);
    uint8_t addr[6];
    size_t len = sizeof(addr);
    uint8_t atype = 0;
    if (nvs_get_blob(h, "raddr", addr, &len) == ESP_OK && len == 6 &&
        nvs_get_u8(h, "rtype", &atype) == ESP_OK) {
      memcpy(s_target.val, addr, 6);
      s_target.type = atype;
      s_have_cached_addr = true;
      ESP_LOGI(TAG, "cache addr %02X:%02X:%02X:%02X:%02X:%02X type=%u",
               addr[5], addr[4], addr[3], addr[2], addr[1], addr[0], atype);
    }
    nvs_close(h);
  }
  ESP_LOGI(TAG, "cache paired=%d have_addr=%d", (int)s_paired, (int)s_have_cached_addr);
}

static void save_cache_addr(const ble_addr_t *addr) {
  if (!addr) return;
  s_target = *addr;
  s_have_cached_addr = true;
  nvs_handle_t h;
  if (nvs_open("mrproxy", NVS_READWRITE, &h) == ESP_OK) {
    nvs_set_u8(h, "paired", 1);
    nvs_set_blob(h, "raddr", addr->val, 6);
    nvs_set_u8(h, "rtype", addr->type);
    nvs_commit(h);
    nvs_close(h);
    s_paired = true;
    ESP_LOGI(TAG, "saved bond addr type=%u", addr->type);
  }
}

static void save_cache_addr_deferred(const ble_addr_t *addr) {
  if (!addr) return;
  s_target = *addr;
  s_have_cached_addr = true;
  s_nvs_addr = *addr;
  s_nvs_dirty = true;
}

static void flush_nvs_if_dirty(void) {
  if (!s_nvs_dirty) return;
  s_nvs_dirty = false;
  save_cache_addr(&s_nvs_addr);
}

static void save_cache(void) {
  save_cache_addr_deferred(&s_target);
}

/** After ENC OK — prefer identity addr (more stable than RPA scan). */
static void remember_bonded_peer(uint16_t conn) {
  struct ble_gap_conn_desc d;
  if (ble_gap_conn_find(conn, &d) != 0) return;
  ble_addr_t a = d.peer_id_addr;
  bool empty = true;
  for (int i = 0; i < 6; i++)
    if (a.val[i] != 0) {
      empty = false;
      break;
    }
  if (empty) a = d.peer_ota_addr;
  save_cache_addr_deferred(&a);
}

static void smp_for_remote(void) {
  /* LG Magic Remote = Legacy Just Works + bonding (hid-dongle). */
  ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
  ble_hs_cfg.sm_bonding = 1;
  ble_hs_cfg.sm_mitm = 0;
  ble_hs_cfg.sm_sc = 0;
  ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
  ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
}

static bool name_is_remote(const uint8_t *name, uint8_t name_len) {
  if (!name || name_len == 0) return false;
  char buf[32];
  uint8_t n = name_len < sizeof(buf) - 1 ? name_len : (uint8_t)(sizeof(buf) - 1);
  memcpy(buf, name, n);
  buf[n] = 0;
  /* Exact or contains — ADV may only have short name. */
  if (strcmp(buf, REMOTE_NAME) == 0) return true;
  if (strstr(buf, "MR25GA") != NULL) return true;
  if (strstr(buf, "LGE MR") != NULL) return true;
  return false;
}

static void on_notify(uint16_t attr_handle, const uint8_t *data, uint16_t len) {
  if (!s_dec || !data || len == 0) return;
  uint8_t rid = report_id_for(attr_handle);
  if (rid == 0xFD && len >= 19) {
    int64_t started_us = esp_timer_get_time();
    remote_decoder_on_fd(s_dec, data, len);
    uint32_t elapsed_us = (uint32_t)(esp_timer_get_time() - started_us);
    bridge_metrics_t *metrics = bridge_metrics();
    metrics->remote_fd_count++;
    metrics->decoder_total_us += elapsed_us;
    if (elapsed_us > metrics->decoder_max_us) metrics->decoder_max_us = elapsed_us;
  }
}

static void disconnect_remote(void) {
  if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
    uint16_t c = s_conn;
    s_conn = BLE_HS_CONN_HANDLE_NONE;
    if (ble_core_is_owner())
      (void)ble_core_do_disconnect(c);
    else
      ble_core_cmd_disconnect(c);
  }
  s_conn_gen++;
  s_disc_gen++;
  bridge_session_bump_remote();
  ble_core_cmd_release_buttons();
}

static bool disc_ctx_ok(const ble_disc_ctx_t *ctx, uint16_t conn_handle) {
  if (!ctx) return false;
  if (ctx->conn != conn_handle || ctx->conn != s_conn) return false;
  if (ctx->conn_gen != s_conn_gen || ctx->disc_gen != s_disc_gen) {
    bridge_metrics()->session_mismatch++;
    return false;
  }
  if (bridge_state_remote() != REM_DISCOVERING || s_disc_fail) return false;
  return true;
}

static bool evt_uuid_eq(const ble_disc_evt_t *e, const ble_uuid_t *u) {
  if (!e || !u) return false;
  if (e->uuid_type == 16 && u->type == BLE_UUID_TYPE_16)
    return e->uuid16 == BLE_UUID16(u)->value;
  if (e->uuid_type == 128 && u->type == BLE_UUID_TYPE_128)
    return memcmp(e->uuid128, BLE_UUID128(u)->value, 16) == 0;
  return false;
}

/* ---------- GATT discovery (BleCore processes events; host only enqueues) ---------- */

static uint16_t s_cccd_map_val[24];
static uint16_t s_cccd_map_h[24];
static int s_cccd_map_n;
static ble_disc_ctx_t s_disc_ctx;
static int64_t s_disc_deadline_ms;
static int64_t s_secure_deadline_ms;

static void map_cccd(uint16_t val_h, uint16_t cccd_h) {
  if (s_cccd_map_n >= 24) return;
  s_cccd_map_val[s_cccd_map_n] = val_h;
  s_cccd_map_h[s_cccd_map_n] = cccd_h;
  s_cccd_map_n++;
}

static uint16_t cccd_for_val(uint16_t val_h) {
  for (int i = 0; i < s_cccd_map_n; i++)
    if (s_cccd_map_val[i] == val_h) return s_cccd_map_h[i];
  return 0;
}

static void maybe_start_cccd_writes(void) {
  if (!s_dsc_jobs_done || s_pending_2908 > 0) return;
  if (s_proto_handle) {
    uint8_t mode = 0x01;
    ble_core_cmd_gattc_write_no_rsp(s_conn, s_proto_handle, &mode, 1);
    ESP_LOGI(TAG, "proto mode report");
  }
  ESP_LOGI(TAG, "CCCD queue n=%d (pending2908=0)", s_cccd_n);
  s_cccd_i = 0;
  write_next_cccd();
}

static void run_next_job_dsc(void) {
  if (s_job_i >= s_job_n) {
    s_dsc_jobs_done = true;
    maybe_start_cccd_writes();
    return;
  }
  chr_job_t *j = &s_jobs[s_job_i];
  uint16_t end = j->end_handle;
  if (end <= j->val_handle) end = j->val_handle + 5;
  ble_core_cmd_gattc_disc_dscs(s_conn, j->val_handle, end, &s_disc_ctx);
}

static int write_next_cccd(void) {
  if (s_cccd_i >= s_cccd_n) {
    finish_discover_ok();
    return 0;
  }
  uint16_t h = s_cccds[s_cccd_i++];
  uint8_t v[2] = {0x01, 0x00};
  ble_core_cmd_gattc_write(s_conn, h, v, 2, &s_disc_ctx);
  return 0;
}

static void add_job(uint16_t val, uint16_t end, bool need_ref) {
  if (s_job_n >= 24) return;
  s_jobs[s_job_n].val_handle = val;
  s_jobs[s_job_n].end_handle = end;
  s_jobs[s_job_n].need_report_ref = need_ref;
  s_job_n++;
}

static uint16_t s_prev_def;

static void handle_disc_svc(const ble_disc_evt_t *e) {
  if (e->status == BLE_HS_EDONE) {
    if (s_d1_start) {
      ble_core_cmd_gattc_disc_chrs(s_conn, s_d1_start, s_d1_end, 1, &s_disc_ctx);
    } else if (s_hid_start) {
      ble_core_cmd_gattc_disc_chrs(s_conn, s_hid_start, s_hid_end, 2, &s_disc_ctx);
    } else {
      ESP_LOGW(TAG, "no D1FF/HID services");
      discover_fail();
    }
    return;
  }
  if (e->status != 0) {
    discover_fail();
    return;
  }
  ble_uuid_t *ud1 = (ble_uuid_t *)&uuid_d1ff.u;
  ble_uuid_t *uhid = (ble_uuid_t *)&uuid_hid.u;
  if (evt_uuid_eq(e, ud1)) {
    s_d1_start = e->start_h;
    s_d1_end = e->end_h;
    ESP_LOGI(TAG, "D1FF %u-%u", s_d1_start, s_d1_end);
  } else if (evt_uuid_eq(e, uhid)) {
    s_hid_start = e->start_h;
    s_hid_end = e->end_h;
    ESP_LOGI(TAG, "HID %u-%u", s_hid_start, s_hid_end);
  }
}

static void handle_disc_chr_d1(const ble_disc_evt_t *e) {
  if (e->status == BLE_HS_EDONE) {
    if (s_hid_start)
      ble_core_cmd_gattc_disc_chrs(s_conn, s_hid_start, s_hid_end, 2, &s_disc_ctx);
    else {
      s_job_i = 0;
      run_next_job_dsc();
    }
    return;
  }
  if (e->status != 0) {
    discover_fail();
    return;
  }
  if (evt_uuid_eq(e, (ble_uuid_t *)&uuid_a001.u))
    add_job(e->val_h, e->val_h + 5, false);
}

static void handle_disc_chr_hid(const ble_disc_evt_t *e) {
  if (e->status == BLE_HS_EDONE) {
    if (s_job_n > 0 && s_hid_end) s_jobs[s_job_n - 1].end_handle = s_hid_end;
    for (int i = 0; i < s_job_n; i++) {
      if (s_jobs[i].end_handle <= s_jobs[i].val_handle)
        s_jobs[i].end_handle = s_jobs[i].val_handle + 10;
    }
    s_job_i = 0;
    run_next_job_dsc();
    return;
  }
  if (e->status != 0) {
    discover_fail();
    return;
  }
  if (s_job_n > 0 && s_prev_def) s_jobs[s_job_n - 1].end_handle = e->def_h - 1;
  s_prev_def = e->def_h;
  if (evt_uuid_eq(e, (ble_uuid_t *)&uuid_2a4e.u)) {
    s_proto_handle = e->val_h;
  } else if (evt_uuid_eq(e, (ble_uuid_t *)&uuid_2a4d.u)) {
    add_job(e->val_h, 0, true);
  }
}

static void handle_disc_dsc(const ble_disc_evt_t *e) {
  if (e->status == BLE_HS_EDONE) {
    s_job_i++;
    run_next_job_dsc();
    return;
  }
  if (e->status != 0) {
    discover_fail();
    return;
  }
  if (evt_uuid_eq(e, (ble_uuid_t *)&uuid_2902.u)) {
    map_cccd(e->chr_val_h, e->dsc_h);
    if (s_job_i < s_job_n && !s_jobs[s_job_i].need_report_ref) {
      if (s_cccd_n < 16) s_cccds[s_cccd_n++] = e->dsc_h;
    }
  } else if (evt_uuid_eq(e, (ble_uuid_t *)&uuid_2908.u)) {
    s_pending_2908++;
    ble_core_cmd_gattc_read(s_conn, e->dsc_h, e->chr_val_h, &s_disc_ctx);
  }
}

static void handle_disc_read2908(const ble_disc_evt_t *e) {
  uint16_t val_h = e->tag_val_h;
  if (e->status == 0 && e->data_len >= 1) {
    remember_report(val_h, e->data[0]);
    ESP_LOGI(TAG, "report id=0x%02X handle=%u", e->data[0], val_h);
    if (e->data[0] == 0xFD) {
      uint16_t cccd = cccd_for_val(val_h);
      if (cccd && s_cccd_n < 16) {
        bool dup = false;
        for (int i = 0; i < s_cccd_n; i++)
          if (s_cccds[i] == cccd) {
            dup = true;
            break;
          }
        if (!dup) {
          s_cccds[s_cccd_n++] = cccd;
          ESP_LOGI(TAG, "subscribe FD CCCD=%u", cccd);
        }
      }
    }
  }
  if (s_pending_2908 > 0) s_pending_2908--;
  maybe_start_cccd_writes();
}

static void handle_disc_cccd_write(const ble_disc_evt_t *e) {
  if (e->status != 0) ESP_LOGW(TAG, "CCCD err %d", e->status);
  write_next_cccd();
}

static void on_disc_evt(const ble_disc_evt_t *e) {
  if (!e || !disc_ctx_ok(&e->ctx, e->conn)) return;
  switch (e->kind) {
    case BLE_DISC_EVT_SVC:
      handle_disc_svc(e);
      break;
    case BLE_DISC_EVT_CHR_D1:
      handle_disc_chr_d1(e);
      break;
    case BLE_DISC_EVT_CHR_HID:
      handle_disc_chr_hid(e);
      break;
    case BLE_DISC_EVT_DSC:
      handle_disc_dsc(e);
      break;
    case BLE_DISC_EVT_READ2908:
      handle_disc_read2908(e);
      break;
    case BLE_DISC_EVT_CCCD_WRITE:
      handle_disc_cccd_write(e);
      break;
    default:
      break;
  }
}

static void discover_fail(void) {
  if (s_disc_fail) return;
  s_disc_fail = true;
  ESP_LOGW(TAG, "discover FAIL");
  disconnect_remote();
  set_state(REM_RECOVERING);
  bridge_metrics()->reconnect_count++;
}

static void finish_discover_ok(void) {
  s_disc_ok = true;
  save_cache();
  reset_motion_session();
  struct ble_gap_upd_params up = {
      .itvl_min = 6,
      .itvl_max = 9,
      .latency = 0,
      .supervision_timeout = 400,
      .min_ce_len = 0,
      .max_ce_len = 0,
  };
  if (ble_core_is_owner())
    (void)ble_core_do_gap_update(s_conn, &up);
  else
    ble_core_cmd_gap_update(s_conn, &up);
  set_state(REM_READY);
  mac_gatt_set_status(ST_READY);
  ESP_LOGI(TAG, "READY reports=%d cccd=%d", s_rep_count, s_cccd_n);
}

static void begin_discover(void) {
  s_d1_start = s_d1_end = s_hid_start = s_hid_end = 0;
  s_job_n = s_job_i = 0;
  s_cccd_n = s_cccd_i = 0;
  s_cccd_map_n = 0;
  s_pending_2908 = 0;
  s_dsc_jobs_done = false;
  s_rep_count = 0;
  s_proto_handle = 0;
  s_disc_ok = s_disc_fail = false;
  s_prev_def = 0;
  s_disc_gen++;
  s_disc_ctx.conn = s_conn;
  s_disc_ctx.conn_gen = s_conn_gen;
  s_disc_ctx.disc_gen = s_disc_gen;
  s_disc_deadline_ms = now_ms() + 15000;
  set_state(REM_DISCOVERING);
  ble_core_cmd_gattc_disc_svcs(s_conn, &s_disc_ctx);
}

/* ---------- GAP / scan / connect ---------- */

static int gap_event(struct ble_gap_event *event, void *arg) {
  (void)arg;
  switch (event->type) {
    case BLE_GAP_EVENT_DISC: {
      if (bridge_state_remote() != REM_SCANNING) return 0;
      struct ble_hs_adv_fields fields;
      if (ble_hs_adv_parse_fields(&fields, event->disc.data, event->disc.length_data) != 0)
        return 0;
      if (!name_is_remote(fields.name, fields.name_len)) return 0;
      ESP_LOGI(TAG, "found remote rssi=%d type=%u", event->disc.rssi,
               event->disc.addr.type);
      ble_core_cmd_scan_cancel();
      s_target = event->disc.addr;
      s_got_target = true;
      return 0;
    }
    case BLE_GAP_EVENT_DISC_COMPLETE:
      ESP_LOGI(TAG, "scan complete reason=%d", event->disc_complete.reason);
      if (bridge_state_remote() == REM_SCANNING && !s_got_target && !s_do_connect)
        set_state(REM_RECOVERING);
      return 0;
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status != 0) {
        ESP_LOGW(TAG, "central connect fail %d", event->connect.status);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        set_state(REM_RECOVERING);
        return 0;
      }
      {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->connect.conn_handle, &desc) != 0) return 0;
        if (desc.role != BLE_GAP_ROLE_MASTER) return 0; /* Mac peripheral conn */
        s_conn = event->connect.conn_handle;
        s_conn_gen++;
        bridge_session_bump_remote();
        ESP_LOGI(TAG, "REMOTE CONNECT handle=%u gen=%lu", s_conn, (unsigned long)s_conn_gen);
        set_state(REM_ENCRYPTED);
        s_secure_deadline_ms = now_ms() + 12000;
        smp_for_remote();
        /* Bonded reconnect: already encrypted → discover immediately, no re-pair. */
        if (desc.sec_state.encrypted) {
          ESP_LOGI(TAG, "already bonded/encrypted");
          s_need_secure = false;
          remember_bonded_peer(s_conn);
          begin_discover();
          return 0;
        }
        s_need_secure = true;
        s_connect_ms = now_ms();
        ble_core_cmd_security(s_conn);
        s_need_secure = false;
        ESP_LOGI(TAG, "waiting ENC…");
      }
      return 0;
    case BLE_GAP_EVENT_DISCONNECT: {
      struct ble_gap_conn_desc *d = &event->disconnect.conn;
      if (d->role == BLE_GAP_ROLE_MASTER || event->disconnect.conn.conn_handle == s_conn) {
        ESP_LOGI(TAG, "REMOTE DISCONNECT reason=%d", event->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_conn_gen++;
        s_disc_gen++;
        bridge_session_bump_remote();
        reset_motion_session();
        ble_core_cmd_release_buttons();
        s_remote_drop = true;
      }
      return 0;
    }
    case BLE_GAP_EVENT_ENC_CHANGE:
      if (event->enc_change.conn_handle != s_conn) return 0;
      ESP_LOGI(TAG, "ENC status=%d (0=ok)", event->enc_change.status);
      if (event->enc_change.status != 0) {
        s_enc_fail_streak++;
        ESP_LOGW(TAG, "ENC fail streak=%d — NOT deleting bond yet", s_enc_fail_streak);
        /* Delete bond only after many failures — remote often resends Pairing Request. */
        if (s_enc_fail_streak >= 3) {
          struct ble_gap_conn_desc desc;
          if (ble_gap_conn_find(s_conn, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
            ble_store_util_delete_peer(&desc.peer_ota_addr);
            ESP_LOGW(TAG, "bond deleted after %d ENC fails", s_enc_fail_streak);
          }
          s_enc_fail_streak = 0;
        }
        s_reconnect_delay_ms = 2000;
        disconnect_remote();
        set_state(REM_RECOVERING);
        return 0;
      }
      s_enc_fail_streak = 0;
      s_reconnect_delay_ms = 600;
      remember_bonded_peer(s_conn);
      begin_discover();
      return 0;
    case BLE_GAP_EVENT_CONN_UPDATE:
      if (event->conn_update.status == 0 && event->conn_update.conn_handle == s_conn) {
        struct ble_gap_conn_desc d;
        if (ble_gap_conn_find(s_conn, &d) == 0)
          ESP_LOGI(TAG, "Remote CI itvl=%u (×1.25ms)", d.conn_itvl);
      }
      return 0;
    case BLE_GAP_EVENT_PASSKEY_ACTION: {
      uint8_t action = event->passkey.params.action;
      uint32_t passkey = 0;
      if (action == BLE_SM_IOACT_INPUT || action == BLE_SM_IOACT_DISP) passkey = 0;
      /* NUMCMP accept encoded as passkey=1 for our inject helper — see below */
      if (action == BLE_SM_IOACT_NUMCMP) {
        /* Must go through owner — post full inject via cmd with action only;
         * NUMCMP needs numcmp_accept; extend if needed. */
        ble_core_cmd_sm_inject(event->passkey.conn_handle, action, 1);
      } else {
        ble_core_cmd_sm_inject(event->passkey.conn_handle, action, passkey);
      }
      ESP_LOGI(TAG, "PASSKEY action=%u posted", action);
      return 0;
    }
    case BLE_GAP_EVENT_NOTIFY_RX: {
      if (event->notify_rx.conn_handle != s_conn) return 0;
      uint16_t len = OS_MBUF_PKTLEN(event->notify_rx.om);
      uint8_t buf[64];
      if (len > sizeof(buf)) len = sizeof(buf);
      ble_hs_mbuf_to_flat(event->notify_rx.om, buf, len, NULL);
      on_notify(event->notify_rx.attr_handle, buf, len);
      return 0;
    }
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
      /*
       * LG remote often sends Pairing Request on every connect even when bonded.
       * RETRY + delete_peer → loses bond each time. IGNORE = keep LTK, re-encrypt.
       */
      ESP_LOGI(TAG, "REPEAT_PAIRING — IGNORE (keep NVS bond)");
      return BLE_GAP_REPEAT_PAIRING_IGNORE;
    }
    default:
      return 0;
  }
}

static void start_scan_burst(void) {
  (void)ble_core_do_scan_cancel();
  smp_for_remote();
  s_got_target = false;
  s_do_connect = false;
  s_scan_ms = now_ms();

  ESP_LOGI(TAG, "SCAN burst %dms \"%s\"%s", SCAN_BURST_MS, REMOTE_NAME,
           s_paired ? " (reconnect — press remote button)" : "");
  int rc = ble_core_do_scan_start(s_own_addr_type, SCAN_BURST_MS, gap_event);
  if (rc != 0) {
    ESP_LOGW(TAG, "SCAN start fail %d", rc);
    set_state(REM_RECOVERING);
    return;
  }
  set_state(REM_SCANNING);
  mac_gatt_set_status(ST_SCAN_REMOTE);
}

static void try_connect(void) {
  set_state(REM_CONNECTING);
  mac_gatt_set_status(ST_REMOTE_CONN);
  (void)ble_core_do_scan_cancel();
  smp_for_remote();

  ESP_LOGI(TAG, "connecting type=%u (keep bonds, paired=%d)", s_target.type, (int)s_paired);
  int rc = ble_core_do_connect(s_own_addr_type, &s_target, gap_event);
  if (rc != 0) {
    ESP_LOGW(TAG, "connect FAIL rc=%d", rc);
    set_state(REM_RECOVERING);
  }
}

/** Try direct connect to cached identity — skip scan if remote is in range / ADV. */
static void try_cached_reconnect(void) {
  if (!s_paired || !s_have_cached_addr) {
    start_scan_burst();
    return;
  }
  ESP_LOGI(TAG, "cached reconnect (press remote button if not seen)");
  s_got_target = false;
  s_do_connect = false;
  try_connect();
}

void remote_manager_init(remote_decoder_t *decoder) {
  s_dec = decoder;
  load_cache();
  ble_hs_id_infer_auto(0, &s_own_addr_type);
  ble_core_set_disc_handler(on_disc_evt);
  set_state(REM_WAIT_MAC);
}

void remote_manager_tick(void) {
  flush_nvs_if_dirty();

  /* Refresh own addr after host sync */
  static bool addr_ok;
  if (!addr_ok) {
    if (ble_hs_synced()) {
      ble_hs_id_infer_auto(0, &s_own_addr_type);
      addr_ok = true;
    }
  }

  if (!mac_gatt_mac_ready()) {
    if (bridge_state_remote() == REM_READY) {
      /* Keep remote link when app closes — reopen without re-pair. */
      return;
    }
    if (bridge_state_remote() == REM_SCANNING) {
      (void)ble_core_do_scan_cancel();
      set_state(REM_WAIT_MAC);
      return;
    }
    if (bridge_state_remote() != REM_WAIT_MAC && bridge_state_remote() != REM_IDLE && bridge_state_remote() != REM_RECOVERING &&
        bridge_state_remote() != REM_CONNECTING && bridge_state_remote() != REM_ENCRYPTED && bridge_state_remote() != REM_DISCOVERING) {
      set_state(REM_WAIT_MAC);
    }
    if (bridge_state_remote() == REM_WAIT_MAC || bridge_state_remote() == REM_IDLE) return;
    /* Connecting/Secure/Discover: let run, do not cut. */
  }

  if (bridge_state_remote() == REM_WAIT_MAC) {
    if (!mac_gatt_mac_ready()) return;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
      ESP_LOGI(TAG, "Mac back — remote still up");
      set_state(REM_READY);
      mac_gatt_set_status(ST_READY);
      return;
    }
    try_cached_reconnect();
    return;
  }

  if (s_got_target) {
    s_got_target = false;
    s_do_connect = true;
  }

  if (bridge_state_remote() == REM_SCANNING) {
    if (s_do_connect) {
      s_do_connect = false;
      try_connect();
      return;
    }
    if (now_ms() - s_scan_ms > SCAN_BURST_MS + 2000) {
      bridge_metrics()->scan_timeout++;
      set_state(REM_RECOVERING);
    }
    return;
  }

  if (bridge_state_remote() == REM_CONNECTING && now_ms() - s_state_ms > 35000) {
    bridge_metrics()->connect_timeout++;
    ESP_LOGW(TAG, "connect timeout");
    set_state(REM_RECOVERING);
    return;
  }

  if (bridge_state_remote() == REM_ENCRYPTED && s_secure_deadline_ms && now_ms() > s_secure_deadline_ms) {
    bridge_metrics()->security_timeout++;
    ESP_LOGW(TAG, "security timeout");
    disconnect_remote();
    set_state(REM_RECOVERING);
    return;
  }

  if (bridge_state_remote() == REM_DISCOVERING && s_disc_deadline_ms && now_ms() > s_disc_deadline_ms) {
    bridge_metrics()->discovery_timeout++;
    ESP_LOGW(TAG, "discovery timeout");
    discover_fail();
    return;
  }

  if (bridge_state_remote() == REM_RECOVERING) {
    if (!mac_gatt_mac_ready()) return;
    if (now_ms() - s_state_ms > s_reconnect_delay_ms) {
      /* Round 1: cached; later scan (RPA may change). */
      static int s_re_n;
      bridge_metrics()->reconnect_count++;
      if (s_paired && s_have_cached_addr && (s_re_n++ % 2) == 0)
        try_cached_reconnect();
      else
        start_scan_burst();
    }
    return;
  }

  if (bridge_state_remote() == REM_ENCRYPTED && s_need_secure && s_conn != BLE_HS_CONN_HANDLE_NONE) {
    if (now_ms() - s_connect_ms >= 250) {
      s_need_secure = false;
      smp_for_remote();
      struct ble_gap_conn_desc d2;
      if (ble_gap_conn_find(s_conn, &d2) == 0 && d2.sec_state.encrypted) {
        ESP_LOGI(TAG, "already encrypted — discover");
        begin_discover();
        return;
      }
      int rc = ble_core_do_security(s_conn);
      ESP_LOGI(TAG, "secure initiate (Legacy JW) rc=%d", rc);
      if (rc == 0 || rc == BLE_HS_EALREADY) {
        ESP_LOGI(TAG, "waiting ENC…");
      } else {
        ESP_LOGW(TAG, "secure rc=%d — try discover without wait", rc);
        begin_discover();
      }
    }
  }

  if (bridge_state_remote() == REM_READY) {
    if (s_remote_drop || s_conn == BLE_HS_CONN_HANDLE_NONE) {
      s_remote_drop = false;
      ESP_LOGI(TAG, "link lost");
      mac_gatt_set_status(ST_REMOTE_DROP);
      set_state(REM_RECOVERING);
    }
  }
}
