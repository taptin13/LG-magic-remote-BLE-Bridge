# ESP32 — dual-role bridge

1. Board: ESP32 (Arduino core **3.3.x**)
2. Open `esp32-ble-bridge.ino` → Upload
3. Serial 115200: debug (`[MAC]`, `[REMOTE]`, `[STATUS]`)
4. Advertising name: **MR-BLE-Bridge**

Mac app scans that name and subscribes to HID notify. ESP32 simultaneously bonds `LGE MR25GA`.
