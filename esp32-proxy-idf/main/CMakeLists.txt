idf_component_register(
  SRCS
    "main.c"
    "event_bus.c"
    "remote_decoder.c"
    "mac_gatt.c"
    "remote_manager.c"
    "mac_bridge.c"
    "ble_core.c"
    "bridge_state.c"
    "bridge_metrics.c"
    "bridge_packet.c"
    "bridge_fault.c"
    "transport_channels.c"
    "ble_tx.c"
  INCLUDE_DIRS "."
  REQUIRES nvs_flash bt freertos esp_timer driver
)
