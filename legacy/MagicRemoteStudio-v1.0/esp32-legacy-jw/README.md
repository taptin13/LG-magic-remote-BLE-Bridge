# ESP32 — MR25GA Legacy Just Works + Mac bridge

ESP32 bonds the remote and prints framed lines for MagicRemote Studio:

```
BRIDGE STATUS scanning|connected|holding|disconnected
BRIDGE UP 12.0
BRIDGE HID FD 0022 BF01FD01...
```

## Nạp

1. Upload `esp32-legacy-jw.ino` (ESP32 Arduino core 3.3.x)
2. Serial 115200 (Studio sẽ mở cổng — đừng để Serial Monitor chiếm)

## Mac

Studio → **Connect bridge** → chọn `cu.wchusbserial…` → rê/bấm remote.
