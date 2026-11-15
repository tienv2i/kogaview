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

- Bản sửa lỗi đã được áp dụng vào [crates/desktop/qml/Viewer.qml](crates/desktop/qml/Viewer.qml) mà không làm mất các thuộc tính debug (`objectName: "viewerViewport"`, `objectName: "viewerCanvas"`) của OpenCode.
- Đã build và verify thành công trên binary thật qua Mutter RemoteDesktop và input events thực tế.
- Chưa tạo git commit để không can thiệp hay gây xung đột với chu trình làm việc của OpenCode.

---

## 4. Ghi chú kiểm chứng (agent, cùng ngày)

- **Căn giữa: đã kiểm chứng.** Assertion trên `canvas.mapToItem(viewport, …)`
  cho `fit`, `100%`, zoom 3× (bị cắt cả bốn phía), xoay 90/180/270° và lật
  H/V, với ảnh 1200×800 và 600×900: tâm ảnh trùng tâm viewport trong sai số
  1 px. Trên binary thật, ảnh chiếm x 177–1102 (tâm 639.5) trong viewport rộng
  1280 và cao 617 px = 800 × 0.77175, không bị cắt.
- **Lật ảnh: đã sửa thêm.** `transform: Scale` lấy gốc mặc định là góc trên-trái
  của item, nên "flip" đẩy ảnh ra ngoài viewport (tâm đo được x = −560). Nay
  gốc đặt tại tâm canvas.
- **`zoomAt`: đã kiểm chứng.** Gọi trực tiếp `zoomAt(1.25, …)` tại ba vị trí con
  trỏ: điểm ảnh dưới con trỏ lệch 0.00 px.
- **Đường nhập liệu cuộn (wheel): chưa kiểm chứng được trong phiên này.** Mọi
  cách inject đều thất bại hoặc không đáng tin: `QTest.wheelEvent` và
  `QGuiApplication::sendEvent(window, QWheelEvent)` báo đã gửi nhưng handler
  không nhận trên Wayland; `NotifyPointerAxisDiscrete` của Mutter RemoteDesktop
  đến app dưới dạng kéo/pan (`DragHandler` active) chứ không phải `WheelEvent`.
  Việc cuộn thực tế do chủ dự án kiểm tra bằng touchpad thật; phiên này không
  tái lập được.
- Chi tiết đầy đủ: [M1-REPORT.md](M1-REPORT.md).
