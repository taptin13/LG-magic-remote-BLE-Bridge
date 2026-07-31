# esp32-proxy

Firmware dual-role theo kiến trúc mới (xem `../ARCHITECTURE.md`).

## Arduino IDE

1. Mở `esp32-proxy.ino`
2. Board: ESP32 Dev Module
3. Upload
4. Serial 115200

## macOS

1. Build/run target **MagicRemoteBLE**
2. Scan → Connect **MR-Proxy**
3. Bật **Map → Mac keyboard/mouse** (Accessibility)
4. Bấm nút remote khi ESP đang SCAN

## Khác với esp32-hid-dongle

| | hid-dongle | proxy |
|--|------------|-------|
| Mac | BLE HID | Custom GATT + app CGEvent |
| Cấu trúc | 1 file .ino | Modules + FreeRTOS queue |
| Reconnect | trong loop | RemoteManager state machine |
