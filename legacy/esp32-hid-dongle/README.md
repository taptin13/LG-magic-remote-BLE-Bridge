# MR-Dongle — Mac HID + Magic Remote

## Auto-reconnect remote

Magic Remote dùng **RPA** (địa chỉ đổi mỗi lần) → không thể connect thẳng addr đã lưu.

Cách đúng:
1. Lần đầu nối thành công → NVS `paired=1`
2. Boot sau: Mac Connect → **SCAN theo tên** `LGE MR25GA`
3. **Bấm 1 nút trên remote** để nó advertising → dongle tự connect (dùng bond keys nếu còn)

Serial: `NVS paired=1` rồi `SCAN auto-reconnect` → `SCAN found` → `RUN`

Xóa: `CFG FORGETREMOTE`

## Volume

Cần Consumer HID — flash firmware có report ID 3, rồi **Forget MR-Dongle** trên Mac và Connect lại.

## Serial CFG

`CFG GET` / `CFG CALIB` / `CFG SENS` / `CFG FORGETREMOTE` …
