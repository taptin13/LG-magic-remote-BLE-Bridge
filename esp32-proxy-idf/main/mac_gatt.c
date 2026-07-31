#include "mac_gatt.h"
#include "ble_core.h"
#include "bridge_state.h"
#include "config.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "host/ble_store.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <string.h>
static const char *TAG = "MAC";

static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_evt_val_handle;
static uint16_t s_sts_val_handle;
static uint16_t s_cmd_val_handle;
static bool s_subscribed;
static bool s_encrypted;
static bool s_ready;
static uint8_t s_seq;
static uint8_t s_status = ST_BOOT;
static mac_cmd_cb_t s_cmd_cb;
static uint8_t s_own_addr_type;
static uint32_t s_link_gen = 1;

static const ble_uuid128_t uuid_svc =
  BLE_UUID128_INIT(PROXY_SVC_UUID128);
static const ble_uuid128_t uuid_evt =
  BLE_UUID128_INIT(PROXY_EVT_UUID128);
static const ble_uuid128_t uuid_sts =
  BLE_UUID128_INIT(PROXY_STS_UUID128);
static const ble_uuid128_t uuid_cmd =
  BLE_UUID128_INIT(PROXY_CMD_UUID128);

static int gatt_svr_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg);

#if PROXY_REQUIRE_MAC_ENC
#define CMD_FLAGS (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC)
#else
#define CMD_FLAGS (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP)
#endif

static const struct ble_gatt_svc_def gatt_svcs[] = {
  {
    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = &uuid_svc.u,
    .characteristics = (struct ble_gatt_chr_def[]){
      {
        .uuid = &uuid_evt.u,
        .access_cb = gatt_svr_chr_access,
        .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &s_evt_val_handle,
      },
      {
        .uuid = &uuid_sts.u,
        .access_cb = gatt_svr_chr_access,
        .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &s_sts_val_handle,
      },
      {
        .uuid = &uuid_cmd.u,
        .access_cb = gatt_svr_chr_access,
        .flags = CMD_FLAGS,
        .val_handle = &s_cmd_val_handle,
      },
      {0},
    },
  },
  {0},
};

static bool link_encrypted(uint16_t conn_handle) {
  struct ble_gap_conn_desc d;
  if (ble_gap_conn_find(conn_handle, &d) != 0) return false;
  return d.sec_state.encrypted != 0;
}

static void refresh_ready(void) {
#if PROXY_REQUIRE_MAC_ENC
  bool next = s_subscribed && s_encrypted;
#else
  bool next = s_subscribed;
#endif
  if (next == s_ready) return;
  s_ready = next;
  if (s_ready) {
    ESP_LOGI(TAG, "Mac ready (sub=%d enc=%d)", (int)s_subscribed, (int)s_encrypted);
    bridge_state_set_mac(MAC_READY);
    struct ble_gap_upd_params up = {
        .itvl_min = 6,
        .itvl_max = 9,
        .latency = 0,
        .supervision_timeout = 400,
        .min_ce_len = 0,
        .max_ce_len = 0,
    };
    ble_core_cmd_gap_update(s_conn, &up);
    mac_gatt_set_status(ST_SCAN_REMOTE);
  }
}

static int gatt_svr_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg) {
  (void)arg;
  if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
    if (attr_handle == s_sts_val_handle) {
      int rc = os_mbuf_append(ctxt->om, &s_status, 1);
      return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (attr_handle == s_evt_val_handle) {
      uint8_t z = 0;
      int rc = os_mbuf_append(ctxt->om, &z, 1);
      return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
  }
  if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && attr_handle == s_cmd_val_handle) {
#if PROXY_REQUIRE_MAC_ENC
    if (!link_encrypted(conn_handle)) {
      ESP_LOGW(TAG, "CMD rejected — link not encrypted");
      return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
#endif
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    uint8_t buf[32];
    if (len > sizeof(buf)) len = sizeof(buf);
    int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, len, NULL);
    if (rc == 0 && s_cmd_cb) s_cmd_cb(buf, len);
    return 0;
  }
  return BLE_ATT_ERR_UNLIKELY;
}

static void on_subscribe(uint16_t conn_handle, uint16_t attr_handle, uint8_t cur) {
  if (conn_handle != s_conn) return;
  if (attr_handle == s_evt_val_handle) {
    s_subscribed = (cur & 1) != 0;
    ESP_LOGI(TAG, "Event CCCD=%d", (int)s_subscribed);
    /* Không downgrade nếu đã MacReady (ENC+sub có thể đến trước dòng set này). */
    if (s_subscribed && bridge_state_mac() < MAC_READY)
      bridge_state_set_mac(MAC_EVENT_SUBSCRIBED);
    refresh_ready();
  }
}

static int gap_event(struct ble_gap_event *event, void *arg);

void mac_gatt_adv_start_raw(void) {
  struct ble_gap_adv_params adv = {0};
  struct ble_hs_adv_fields fields = {0};
  const char *name = PROXY_NAME;

  int rc = ble_hs_util_ensure_addr(0);
  if (rc != 0) {
    ESP_LOGE(TAG, "ensure_addr %d", rc);
    return;
  }
  rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
  if (rc != 0) {
    ESP_LOGE(TAG, "infer_addr %d", rc);
    return;
  }
  ble_svc_gap_device_name_set(PROXY_NAME);

  fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
  fields.name = (uint8_t *)name;
  fields.name_len = strlen(name);
  fields.name_is_complete = 1;
  fields.uuids128 = (ble_uuid128_t *)&uuid_svc;
  fields.num_uuids128 = 1;
  fields.uuids128_is_complete = 1;
  ble_gap_adv_set_fields(&fields);

  adv.conn_mode = BLE_GAP_CONN_MODE_UND;
  adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
  rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv, gap_event, NULL);
  ESP_LOGI(TAG, "ADV \"%s\" rc=%d (Mac ENC=%d)", name, rc, PROXY_REQUIRE_MAC_ENC);
  bridge_state_set_mac(MAC_ADV);
  mac_gatt_set_status_raw(ST_WAIT_MAC);
}

void mac_gatt_start_advertise(void) {
  ble_core_cmd_adv_start();
}

void mac_gatt_stop_advertise(void) {
  ble_core_cmd_adv_stop();
}

static int gap_event(struct ble_gap_event *event, void *arg) {
  (void)arg;
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status == 0) {
        s_conn = event->connect.conn_handle;
        s_subscribed = false;
        s_encrypted = false;
        s_ready = false;
        s_link_gen++;
        bridge_session_bump_mac();
        bridge_state_set_mac(MAC_CONNECTED);
        ble_core_cmd_flush_tx();
        ESP_LOGI(TAG, "CONNECT handle=%u gen=%lu", s_conn, (unsigned long)s_link_gen);
#if PROXY_REQUIRE_MAC_ENC
        ble_core_cmd_security(s_conn);
#endif
      } else {
        ESP_LOGW(TAG, "connect fail %d — re-ADV", event->connect.status);
        ble_core_cmd_adv_start();
      }
      return 0;
    case BLE_GAP_EVENT_DISCONNECT:
      ESP_LOGI(TAG, "DISCONNECT reason=%d", event->disconnect.reason);
      s_conn = BLE_HS_CONN_HANDLE_NONE;
      s_subscribed = false;
      s_encrypted = false;
      s_ready = false;
      s_link_gen++;
      bridge_session_bump_mac();
      bridge_state_set_mac(MAC_ADV);
      /* Mac gone — flush TX + clear pressed (không notify được). */
      ble_core_cmd_flush_tx();
      mac_gatt_set_status(ST_WAIT_MAC);
      ble_core_cmd_adv_start();
      return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
      on_subscribe(event->subscribe.conn_handle, event->subscribe.attr_handle,
                   event->subscribe.cur_notify | (event->subscribe.cur_indicate << 1));
      return 0;
    case BLE_GAP_EVENT_CONN_UPDATE:
      if (event->conn_update.conn_handle == s_conn) {
        struct ble_gap_conn_desc d;
        if (ble_gap_conn_find(s_conn, &d) == 0) {
          ESP_LOGI(TAG, "Mac CI itvl=%u lat=%u (×1.25ms)", d.conn_itvl, d.conn_latency);
        }
      }
      return 0;
    case BLE_GAP_EVENT_ENC_CHANGE:
      ESP_LOGI(TAG, "ENC status=%d", event->enc_change.status);
      if (event->enc_change.conn_handle == s_conn) {
        s_encrypted = (event->enc_change.status == 0) && link_encrypted(s_conn);
        if (s_encrypted) bridge_state_set_mac(MAC_ENCRYPTED);
        refresh_ready();
      }
      return 0;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
      {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0)
          ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
      }
    default:
      return 0;
  }
}

void mac_gatt_init(mac_cmd_cb_t cmd_cb) {
  s_cmd_cb = cmd_cb;
  ble_svc_gap_init();
  ble_svc_gatt_init();
  int rc = ble_gatts_count_cfg(gatt_svcs);
  if (rc != 0) {
    ESP_LOGE(TAG, "gatts_count_cfg %d", rc);
    return;
  }
  rc = ble_gatts_add_svcs(gatt_svcs);
  if (rc != 0) {
    ESP_LOGE(TAG, "gatts_add_svcs %d", rc);
    return;
  }
  ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
  /* Legacy JW cho remote LG; Mac dùng Just Works bond (không MITM PIN). */
  ble_hs_cfg.sm_bonding = 1;
  ble_hs_cfg.sm_sc = 0;
  ble_hs_cfg.sm_mitm = 0;
  ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
  ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
}

void mac_gatt_set_status(uint8_t st) {
  s_status = st;
  ble_core_cmd_set_status(st);
}

void mac_gatt_set_status_raw(uint8_t st) {
  s_status = st;
  if (s_conn == BLE_HS_CONN_HANDLE_NONE) return;
  struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_status, 1);
  if (om) ble_gatts_notify_custom(s_conn, s_sts_val_handle, om);
}

bool mac_gatt_notify_event(const bridge_packet_t *pkt) {
  return ble_core_submit_packet(pkt);
}

bool mac_gatt_notify_raw(const bridge_packet_t *pkt) {
  if (!pkt || s_conn == BLE_HS_CONN_HANDLE_NONE || !s_subscribed) return false;
  bridge_packet_t out = *pkt;
  out.seq = ++s_seq;
  struct os_mbuf *om = ble_hs_mbuf_from_flat(&out, sizeof(out));
  if (!om) return false;
  int rc = ble_gatts_notify_custom(s_conn, s_evt_val_handle, om);
  return rc == 0;
}

bool mac_gatt_mac_connected(void) {
  return s_conn != BLE_HS_CONN_HANDLE_NONE;
}

bool mac_gatt_mac_ready(void) {
  return s_ready;
}

uint32_t mac_gatt_link_gen(void) {
  return s_link_gen;
}
