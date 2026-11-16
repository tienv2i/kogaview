# Viewer Mouse Wheel & Canvas Center Alignment Bug Report

**Date:** 2026-11-15  
**Component:** `crates/desktop/qml/Viewer.qml`  
**Symptoms:** 
1. `WheelHandler` hoàn toàn không nhận sự kiện cuộn (scroll-to-zoom không hoạt động trên Wayland/Touchpad/RemoteDesktop).
2. Ảnh mở lên bị dạt sang rìa (lệch tâm), và khi zoom thì ảnh bị trôi dạt méo mó không cố định con trỏ.

---

## 1. Gốc rễ lỗi WheelHandler không hoạt động

### Nguyên nhân
- Trong Qt 6 Quick, `WheelHandler` kế thừa từ `QQuickSinglePointHandler`.
- Khác với `DragHandler` hay `TapHandler` (mặc định chấp nhận `PointerDevice.AllDevices`), `WheelHandler` có giá trị mặc định:
  ```qml
  acceptedDevices: PointerDevice.Mouse
  ```
- Trên Linux Wayland / GNOME (đặc biệt khi dùng laptop touchpad hoặc khi inject sự kiện qua Mutter RemoteDesktop / `QTest.wheelEvent`), thiết bị trỏ của window/seat được gán loại `PointerDevice.TouchPad` hoặc pointer tổng hợp của seat, **không mang cờ thuần `PointerDevice.Mouse`**.
- Do đó, `WheelHandler` âm thầm loại bỏ (drop) mọi sự kiện cuộn chuột trước khi gọi callback `onWheel`.

### Giải pháp
Khai báo rõ ràng thiết bị chấp nhận trong `WheelHandler`:
```qml
WheelHandler {
    acceptedDevices: PointerDevice.AllDevices
    onWheel: function(event) {
        ...
    }
}
```

---

## 2. Gốc rễ lỗi ảnh bị lệch về rìa và trôi lệch tâm khi zoom

### Nguyên nhân
Trong code cũ của `Viewer.qml`:
```qml
Item {
    id: canvas
    width: Math.max(1, image.implicitWidth)
    height: Math.max(1, image.implicitHeight)
    scale: view.zoom
    rotation: view.rotationAngle
    x: viewport.width / 2 - width * scale / 2 + view.offsetX
    y: viewport.height / 2 - height * scale / 2 + view.offsetY
    ...
```
- Trong Qt Quick, thuộc tính `scale` của `Item` mặc định biến đổi quanh tâm (`transformOrigin: Item.Center`).
- Tọa độ tâm unscaled là `x + width / 2`.
- Khi viết `x: viewport.width / 2 - width * scale / 2 + view.offsetX`:
  - Tâm thực tế bị dịch chuyển: $\text{center}_x = \frac{\text{viewport.width}}{2} + \text{offsetX} + \frac{\text{width}}{2} \times (1 - \text{scale})$.
  - Ngay cả khi `offsetX = 0`, khi `scale != 1` (ví dụ sau khi `fit()` tính toán zoom = 0.77 hay 0.25), ảnh bị đẩy hẳn sang rìa thay vì nằm chính giữa viewport!
  - Khi zoom, tâm ảnh tự động trôi dạt theo `scale`, khiến công thức tính neo con trỏ trong `zoomAt` bị sai hoàn toàn.

### Giải pháp
Đặt vị trí unscaled về đúng tâm viewport:
```qml
Item {
    id: canvas
    width: Math.max(1, image.implicitWidth)
    height: Math.max(1, image.implicitHeight)
    scale: view.zoom
    rotation: view.rotationAngle
    x: (viewport.width - width) / 2 + view.offsetX
    y: (viewport.height - height) / 2 + view.offsetY
    ...
```
Khi đó:
- Ảnh luôn luôn nằm chính giữa viewport ở mọi mức zoom khi `offsetX = 0, offsetY = 0`.
- Tâm của canvas luôn là `viewport.width / 2 + view.offsetX` và `viewport.height / 2 + view.offsetY`.
- Thuộc tính `zoomAt` giữ chính xác từng pixel dưới con trỏ chuột bất kể góc xoay hay mức zoom.

---

## 3. Trạng thái trong codebase hiện tại

- Bản sửa lỗi đã được áp dụng vào [crates/desktop/qml/Viewer.qml](crates/desktop/qml/Viewer.qml) mà không làm mất các thuộc tính debug (`objectName: "viewerViewport"`, `objectName: "viewerCanvas"`) của phiên agent trước.
- Cách kiểm chứng và các con số đo được ghi ở mục 4. Lưu ý: `NotifyPointerAxisDiscrete`
  của Mutter RemoteDesktop **không** dùng được để kiểm tra wheel (nó đến app dưới
  dạng pan), nên mọi kết quả ở mục 4 là sự kiện wheel được bơm trực tiếp với loại
  thiết bị touchpad/mouse khai báo tường minh, chưa phải gesture vật lý.
- Chưa tạo git commit để không can thiệp hay gây xung đột với chu trình làm việc của phiên agent trước.

---

## 4. Ghi chú kiểm chứng (agent, cùng ngày)

### 4.1. Căn giữa — đã kiểm chứng

- Assertion trên `canvas.mapToItem(viewport, …)` cho `fit`, `100%`, zoom 3× (bị
  cắt cả bốn phía), xoay 90/180/270° và lật H/V, với ảnh 1200×800 và 600×900:
  tâm ảnh trùng tâm viewport trong sai số 1 px.
- Trên binary thật, ảnh chiếm x 177–1102 (tâm 639.5) trong viewport rộng 1280
  và cao 617 px = 800 × 0.77175, không bị cắt.

### 4.2. Lật ảnh — phát hiện thêm và đã sửa

`transform: Scale` lấy gốc mặc định là góc trên-trái của item, nên "flip" đẩy
ảnh ra ngoài viewport (tâm đo được x = −560). Nay gốc đặt tại tâm canvas
(`origin.x: canvas.width / 2`, `origin.y: canvas.height / 2`).

### 4.3. Scroll-to-zoom — đã kiểm chứng, nguyên nhân trong mục 1 là **đúng**

Cơ chế của mục 1 được xác nhận bằng **phép thử đối chứng**: cùng một sự kiện
wheel mang thiết bị kiểu `TouchPad` (pixelDelta = 15, angleDelta = 0):

| `acceptedDevices` | kết quả |
|---|---|
| `PointerDevice.Mouse` (chỉ chuột) | **bị lọc**, zoom giữ nguyên 0.6 |
| `PointerDevice.AllDevices` | nhận, zoom `0.6 → 0.6966` (= 1.01¹⁵) |

Với thiết bị kiểu `Mouse` (angleDelta ±120) thì cả hai cấu hình đều zoom
(`0.6 → 0.7182` = 1.0015¹²⁰ và quay lại). Nghĩa là chính `acceptedDevices` là
thứ chặn touchpad, đúng như phân tích ở mục 1.

Điểm ảnh dưới con trỏ được giữ cố định trong sai số 0.5 px tại ba vị trí con
trỏ, cả khi gửi kèm scroll phase (`ScrollBegin/Update/End`) lẫn khi không.

Trên **app thật** (cửa sổ 1280×820, ảnh 1200×800, có toolbar + filmstrip), bơm
một sự kiện wheel kiểu touchpad vào cửa sổ: `zoom 0.77175 → 0.895978`,
`offsetY 0 → −7.08` — tức là zoom neo theo con trỏ chứ không neo theo tâm
viewport.

### 4.4. Vì sao các lần thử trước đó "không thấy gì"

- `QTest.wheelEvent()` và `QGuiApplication::sendEvent(window, QWheelEvent)` thực
  ra **đã** gửi được sự kiện; handler im lặng vì lúc đó còn lọc thiết bị
  touchpad — tức là lỗi thật, không phải harness hỏng.
- `QWindowSystemInterface::handleWheelEvent()` trả về `false` (không đưa vào
  hàng đợi) với phase `ScrollUpdate` trên Qt 6.12, cho cả `pixelDelta` lẫn
  `angleDelta`. Muốn bơm giữa gesture thì dùng `NoScrollPhase`, hoặc gửi trực
  tiếp `QWheelEvent` vào cửa sổ.
- `NotifyPointerAxisDiscrete` của Mutter RemoteDesktop vẫn không dùng được: nó
  đến app dưới dạng chuyển động trỏ và kích hoạt `DragHandler` (pan) chứ không
  phải wheel.

### 4.5. Đã đưa vào pipeline

- Test tự động: `tests/qml/tst_viewer.cpp` (14 test) nạp nguyên bản
  `crates/desktop/qml/Viewer.qml`, assert trên transform thật của Qt Quick và
  bơm wheel event có khai báo loại thiết bị. Chạy bằng `just test` (sau các test
  Cargo, QPA `offscreen`).
- Kiểm tra ngược: tạm khôi phục công thức cũ `x: viewport.width / 2 - width *
  scale / 2` thì suite **fail 13 test**, trong đó có neo con trỏ lệch −96.6 px —
  tức là lỗi này không thể quay lại mà không bị chặn.
- Chi tiết đầy đủ: [M1-REPORT.md](M1-REPORT.md) mục "Verification actually
  performed" hàng 21–24.

### 4.6. Phần chưa kiểm chứng

Chưa có thao tác chuột/touchpad **vật lý** nào do phiên này thực hiện: mọi con
số ở trên đến từ sự kiện bơm vào với đúng loại thiết bị và đúng dạng dữ liệu
(`pixelDelta`/`angleDelta`) mà libinput sinh ra. Bước cuối — compositor chuyển
một gesture thật vào cửa sổ — dựa trên lần kiểm tra trực tiếp của chủ dự án.
