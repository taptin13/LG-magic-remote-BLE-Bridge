# MR25GA — Sổ tay nghiên cứu

Cập nhật: 2026-07-30. Ghi lại toàn bộ những gì đã xác minh được về LG Magic
Remote MR25GA trên macOS, để không phải điều tra lại từ đầu.

## 1. Nhận dạng thiết bị

| Thuộc tính | Giá trị |
|---|---|
| Tên advertising | `LGE MR25GA` |
| Địa chỉ BLE (public) | `78:00:A8:C0:D5:4E` |
| UUID peripheral trên macOS | `CF31F0D0-5DD6-6ABF-C024-D6A709AF0801` |
| Chip | Realtek Bee (`RTKBee*`, Model `0.9`) |
| Manufacturer data (LG `00C4`) | ASCII `SCD 21.1,BA 35,webOS` |
| PnP ID | `015D 0062…` (vendor LG) |

UUID peripheral do macOS sinh ra theo từng host; địa chỉ public mới là thứ
định danh thật và dùng để lọc log `bluetoothd`.

## 2. Bản đồ GATT

Xác minh bằng nRF Connect (iOS) và đối chiếu lại bằng full discovery trong
Studio. Các service `FFF*`/`FFE*` **nằm bên trong service `D0FF`**, không phải
service riêng — đây là điểm ban đầu hiểu sai.

| Service | Characteristic | Thuộc tính |
|---|---|---|
| `180F` Battery | `2A19` | read, notify |
| `180A` Device Info | nhiều char | read |
| `1813` Scan Parameters | `2A4F` Scan Interval Window | writeWithoutResponse |
| | `2A31` Scan Refresh | notify |
| `0000D1FF-3C17-D293-8E48-14FE2E4DA212` | `A001` | notify, writeWithoutResponse |
| | `A002` | write, writeWithoutResponse |
| `0000D0FF-3C17-D293-8E48-14FE2E4DA212` | `FFD1`, `FFD8` | writeWithoutResponse |
| | `FFD2`–`FFD5` | read |
| | `FFF1` | read |
| | `FFF2` | write |
| | `FFE0`–`FFE2` | read |

### Giá trị đọc được

```
FFD2 = 78 00 A8 C0 D5 4E          ← chính là địa chỉ BLE của remote
FFD3 = 01 00 0C 38
FFD4 = 61 B0 0B 00
FFE0 = 03 00 00 01 11 00 00 00 | 01 00 0C 38 | 61 B0 0B 00 | 01 E0 03 08
                                  ^^^^ = FFD3   ^^^^ = FFD4
```

`FFE0` là bản ghi tổng hợp chứa lại nội dung `FFD3` và `FFD4`, nên rất có thể
là khối mô tả session/pairing state chứ không phải dữ liệu HID.

## 3. Mất kết nối — PacketLogger (22:38 / `.pklg`)

Capture: `/Users/vuongtran/Documents/Untitled [Live].txt` +
`/Users/vuongtran/Documents/Untitled [Live].pklg`

### SMP thật (hai lần, handle `0x0050` và `0x0052`)

```
t≈0.03s  Remote → SMP Security Request
t≈0.84s  Mac    → SMP Pairing Request
t≈0.90s  Remote → SMP Pairing Response
         … không có Pairing Confirm / Random / DHKey / Pairing Failed …
t≈2.74s  HCI Disconnection Complete — Connection Timeout
```

**Không có PDU `Pairing Failed`.** Mã Apple `708` là bluetoothd báo sau khi
link chết, không phải remote gửi reason SMP. Sau Response, Mac **không gửi
Pairing Confirm**; GATT vẫn chạy song song.

### SMP fields (decode từ `.pklg`)

Cùng payload ở cả hai phiên. L2CAP CID `0x0006`:

| PDU | Bytes (sau opcode) | Ý nghĩa |
|---|---|---|
| Security Request | `0B 01` | AuthReq=`0x01` Bonding, **không** MITM, **không** SC |
| Pairing Request (Mac) | `01 04 00 01 10 03 03` | IO=`KeyboardDisplay`, AuthReq=`0x01`, MaxKey=16, KeyDist Enc+Id |
| Pairing Response (Remote) | `02 03 00 01 10 03 03` | IO=`NoInputNoOutput`, AuthReq=`0x01`, MaxKey=16, KeyDist Enc+Id |

Chọn method: KeyboardDisplay ∩ NoInputNoOutput → **Just Works**.
Cả hai `SC=0` → **LE Legacy** (không Secure Connections).
Bonding=1, MITM=0 → bước kế của Central phải là **Pairing Confirm**. Mac không gửi.

Giả thuyết mạnh: stack macOS hiện đại kỳ vọng LE SC; remote Realtek Bee chỉ
offer Legacy Just Works. bluetoothd ghi “Just Works” rồi **im** thay vì
`Pairing Failed`, trong khi remote dần ngừng trả ATT → supervision timeout.

### Disconnect = Connection Timeout (supervision)

Mac gửi `LE Connection Update` với **Supervision Timeout = 720 ms**. Sau
`Find Information — Report Map` (~t+2.0s) remote im ~750 ms → HCI timeout.
Khớp “~2.3s mất link”: remote ngừng trả lời ATT, rồi supervision cắt — không
thấy remote gửi `Pairing Failed`.

nRF trên iOS vẫn đứt ~2.3s không bonding: remote có hành vi ngừng phục vụ host
lạ; trên Mac thêm chuyện pairing kẹt sau Response.

### HID có thật (trước đây kết luận sai)

```
HID Information (0x0010) = 00 00 00 01
Report Map @ 0x0017 (Find Information — không kịp response trước khi đứt)
Manufacturer = "Realtek BT", Model = "Model Nbr 0.9"
PnP ID = 015D 0062 8701 00
```

Service HID tồn tại. Studio chỉ discover `D1FF`+`D0FF` nên bỏ lỡ;
`bluetoothd` vẫn probe HID (`Bluetooth LE HID activity woke up machine fully`).

### bluetoothd (khớp decode)

```
Security (without man-in-the-middle) was requested by device
Accepting security request … "Just Works"
smpPairingCompleted … status=708
```

### Ngân sách thời gian (vẫn đúng cho thử GATT)

| Giai đoạn | Thời gian |
|---|---|
| Link sống tới timeout | ~2.7s từ Connection Complete |
| Conn interval ban đầu | 30 ms → update 15 ms |
| Supervision timeout (Mac đặt) | **720 ms** |
| Discovery D1FF+D0FF + A001 notify | ~1.2s |

Studio đo ngân sách từ `didConnect`.


### Những giả thuyết đã loại trừ

- **Remote kẹt cấu hình / hỏng** — sai. Phiên 21:43 trả về đủ bản đồ GATT y
  nguyên như đã ghi ở mục 2.
- **Cần chế độ pairing / tổ hợp huỷ đăng ký** — sai. Remote advertise và nhận
  connect bình thường, không cần tổ hợp nào.
- **Lỗi riêng của macOS, CoreBluetooth, hay app này** — sai. nRF Connect trên
  iOS bị ngắt ở đúng cùng mốc thời gian.
- **Pin yếu, slot kết nối bị TV chiếm, bảng bond đầy** — không cần thiết để
  giải thích hiện tượng nữa.
- **"Trước đây connect được, giờ không"** — không có chuyện đó. Remote chưa bao
  giờ giữ link lâu hơn ~2.3s. Những giá trị `FFD2`/`FFD3`/`FFD4`/`FFE0` ở mục 2
  đọc được là nhờ chen vào trong từng cửa sổ ngắn, qua nhiều lần connect lại.
- **Thiếu IO Cap / AuthReq** — đã có từ `.pklg`; không phải MITM/passkey.

Ghi chú: remote chỉ xuất hiện trong System Settings **sau khi** một app đã chủ
động connect tới nó; nó không tự advertise theo cách System Settings nhận ra.

### Experiment A — HID qua CoreBluetooth (22:53)

Studio gọi `discoverServices([D1FF, D0FF, 1812])` mỗi lần connect. Kết quả lặp
lại trên **mọi** phiên:

```
Service D1FF …
Service D0FF …
HID 1812 not in discovered services
HID skip 2A4A/2A4B/2A4E: not discovered
```

Không bao giờ có dòng `Service …1812`. Trong khi PacketLogger (HCI) thấy
`bluetoothd` đọc HID Information / Report Map trên cùng remote.

**Kết luận:** HID có trong GATT ở tầng HCI, nhưng **CoreBluetooth không expose
`0x1812` cho app** (system HID stack giữ). Experiment A trên Mac/Studio là
dead end — không đọc được Report Map từ app.

FFF2 sweep 29 candidates trong cùng run: nhiều NAK `value's length is invalid`,
một số ghi không NAK nhưng **không** có notify `A001`. Khớp kết luận mục 4.

Capture cùng lúc: `/Users/vuongtran/Documents/Untitled [Live].pklg` (241 KB,
mtime 22:56). Xác nhận ở HCI:

- **24×** chu kỳ `Security Req → Pairing Req → Pairing Rsp` — **0×** Confirm /
  Failed (Mac vẫn kẹt sau Response trên mọi reconnect của Studio).
- `bluetoothd` **có** đọc HID: Information `00 00 00 01`, Report Map **71 byte**:

```
05 0C 09 01 A1 01 85 FD 95 1E 75 08 15 00 26 FF 00 81 00 C0
05 0C 09 01 A1 01 85 F9 95 1E 75 08 15 00 26 FF 00 81 00
   95 C8 75 08 15 00 26 FF 00 B1 00 C0
05 0C 09 01 A1 01 85 FE 95 7C 75 08 15 00 26 FF 00 81 00 C0
```

  Consumer Control: Report ID `0xFD` / `0xF9` = 30B input; `0xF9` thêm Feature
  200B; `0xFE` = 124B input. Đây là kênh HID proprietary (khớp hướng
  `lg-magic-master` sau khi đã bond) — chỉ `bluetoothd` đọc được, không phải CB.
- ATT Error `0x0D` (Invalid Attribute Value Length) ×12 — khớp FFF2 NAK.
- Supervision `15 ms / 720 ms` lặp lại ~48 lần.

### Còn để mở

- ~~HID `1812` qua Studio~~ — dead end (CB không expose; experiment A).
- **(C)** ESP32 Legacy JW — **THÀNH CÔNG** (2026-07-30 23:32 Serial):
  - `auth complete success=1`, `secureConnection -> ok`
  - Link sống **10.72s** rồi mới drop (`SURVIVED past watchdog`)
  - ESP32 thấy **HID=1 D1FF=1 D0FF=1**; Report Map 71B khớp PacketLogger
  - Có RX HID Report ngắn (`00`, `40 00`) trước khi đứt
  - Firmware handle-based: **5× Report `2A4D`**, Protocol Mode=01
  - **`[RX]` liên tục** Report ID `0xFD` len=19 (IMU/airmouse) khi rê remote —
    stream ổn định sau bond. Bước tiếp: decode `0xFD`/`0xF9`/`0xFE` (+ nút)
    theo `lg-magic-master`.
- ~~(B) Capture TV~~ — không có TV.## 4. Handshake GATT — kết quả sweep 22:08–22:10

Sweep cố định trong app (`SweepConfig`): 19 candidates × 5 targets
(`A001`, `A002`, `FFD1`, `FFD8`, `FFF2`) = **95 writes**. Discovery mỗi lần
`D1FF`+`D0FF`, ready ~1.2s, còn ~1.05s ngân sách. Kết quả:

```
SWEEP finished: all 95 writes delivered, no response on any target
```

Không có dòng `RX` / `RESPONSE` nào. Link vẫn chết ~2.3–2.7s bất kể ghi vào đâu.

### Những gì đã loại chắc

| Target | Kết quả |
|---|---|
| `A001` | 19/19 ghi `withoutResponse`, im lặng |
| `A002` | 19/19 ghi, trước đó còn có ACK `withResponse`; im lặng |
| `FFD1` | 19/19 ghi `withoutResponse`, im lặng |
| `FFD8` | 19/19 ghi `withoutResponse`, im lặng |
| `FFF2` | 19/19 thử; **một số bị từ chối độ dài** (xem dưới) |

Candidates đã loại trên mọi target: echo từ `FFD2`/`FFD3`/`FFD4`/`FFE0` + các
payload ngắn `00`/`01`/`02` và biến thể 1–4 byte.

Bề mặt GATT vẫn mở (write tới được, không `Insufficient Authentication`).
Kết luận: **các payload đoán kiểu echo/short không phải handshake**, hoặc
handshake cần điều kiện khác (bond thành công, thứ tự multi-write, length cố
định, hoặc dữ liệu nằm ngoài bộ candidates này).

### Manh mối mới: `FFF1` / `FFF2`

Probe đầy đủ lúc 22:20:

```
FFF1 = 0C 01 00 16 DC 07 5D 00 F0 0F 00 03   (12 bytes, length-prefixed)
FFD2 = 78 00 A8 C0 D5 4E                     (địa chỉ BLE)
FFD3 = 01 00 0C 38
FFD4 = 61 B0 0B 00
FFD5 = (empty)
FFE0 = 03 00 00 01 11 00 00 00 | 01 00 0C 38 | 61 B0 0B 00 | 01 E0 03 08
       ^^^^^^^^ header ^^^^^^^^   ^^^^FFD3^^^^   ^^^^FFD4^^^^
FFE1 = (empty)
FFE2 = (empty)
```

Byte đầu `FFF1` = `0C` = 12 = đúng độ dài. `FFE0` là bản tổng hợp chứa
`FFD3`+`FFD4`.

**29 biến thể 12-byte ghi vào `FFF2` → không có notification trên `A001`.**
Một số payload bị NAK `value's length is invalid` dù vẫn 12 byte — firmware
validate *nội dung*, không chỉ độ dài (hoặc map ATT error sai). Echo nguyên
`FFF1` cũng không mở kênh `A001`.

Kết luận tạm: `FFF1`/`FFF2` là cặp config/status, **không phải** cổng gác giữ
link `D1FF`. Link vẫn chết ~2.3s bất kể ghi `FFF2` gì.

### App hiện tại

Một nút **Run**: probe tuần tự (bỏ đuôi rỗng khi đã đủ char bắt buộc) → ghi
`FFF2` tuần tự với generation token để ACK/NAK không bị lệch gói.

## 5. Công cụ debug

### PacketLogger — bắt SMP (ưu tiên hiện tại)

Mục tiêu: đọc **SMP Pairing Failed reason** thật từ remote (không phải mã
nội bộ Apple `708`).

1. Cài **Bluetooth logging profile** cho macOS:
   https://developer.apple.com/bug-reporting/profiles-and-logs/?name=bluetooth&platform=macos  
   Mở file `.mobileconfig` → System Settings → Profiles → Install → **reboot**.

2. Tải **Additional Tools for Xcode** (đúng major với Xcode đang dùng):
   https://developer.apple.com/download/all/?q=additional%20tools%20for%20xcode  
   Trong DMG → thư mục `Hardware` → copy `PacketLogger.app` vào `/Applications`.

3. Mở PacketLogger → Clear → để nó chạy (macOS HCI trace, không cần iPhone).

4. Trong Studio bấm **Run** một lần (hoặc chỉ Connect remote) để tái hiện
   Security Request → Just Works → fail.

5. Stop capture → Filter / tìm:
   - `SMP`
   - `Pairing Request` / `Pairing Response` / `Pairing Failed`
   - `Security Request`
   - địa chỉ `78:00:A8:C0:D5:4E`

6. Ghi lại **Reason** trong `Pairing Failed` (octet):

| Reason | Ý nghĩa |
|---|---|
| `0x05` | Pairing Not Supported |
| `0x08` | Unspecified Reason |
| `0x09` | Repeated Attempts |
| `0x0A` | Invalid Parameters |
| `0x0B` | DHKey Check Failed |
| `0x0C` | Numeric Comparison Failed |
| `0x0D` | BR/EDR pairing in progress |
| `0x0E` | Cross-transport Key Derivation Not Allowed |
| `0x0F` | Key Rejected |

Có thể File → Export → BTSnoop rồi mở bằng Wireshark nếu cần.

### Xem log pairing theo thời gian thực

```bash
log stream --predicate 'subsystem == "com.apple.bluetooth"' --info --debug \
  | grep -i '78:00:A8:C0:D5:4E\|CF31F0D0'
```

Lọc theo địa chỉ/UUID của remote là cần thiết — nếu không, log của iPhone,
Apple Watch và các thiết bị khác sẽ lẫn vào và dễ đọc thành dương tính giả.

### Bật log debug đầy đủ cho SMP

```bash
sudo log config --mode "level:debug,persist:debug" --subsystem com.apple.bluetooth
```

Trả về mặc định sau khi xong:

```bash
sudo log config --mode "level:default,persist:default" --subsystem com.apple.bluetooth
```


## 6. Bài học về công cụ

- `lg-magic-master/` (driver Linux tham chiếu) **không giúp gì cho phần
  handshake**. Nó phân tích report sau khi hệ điều hành đã expose remote thành
  HID, tức là sau khi pairing đã thành công. Nó không hề cài đặt phần GATT
  proprietary.
- Fast D1FF mode che mất phần lớn bản đồ GATT. Luôn chạy full discovery khi
  khảo sát thiết bị mới.
- Auto session probe phải bị tạm dừng khi chạy Matrix, nếu không các lệnh
  read/write tự động sẽ chen trước gói ứng viên trong cửa sổ vài giây ngắn ngủi.
