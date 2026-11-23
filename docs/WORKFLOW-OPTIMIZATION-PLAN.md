# Kế hoạch tối ưu quy trình OpenCode & phân mức độ Check/Test

> **Trạng thái:** Đã áp dụng toàn bộ (2026-11-23).
> **Nguyên tắc:** Không xóa bất kỳ dữ liệu lịch sử nào; giữ nguyên các quy tắc kiến trúc cốt lõi của dự án.

---

## 1. Phân mức độ Check/Test (Verification Tiers)

Thay vì áp dụng quy trình kiểm tra tối đa cho mọi thay đổi nhỏ, tách thành **3 mức độ rõ ràng**:

| Mức độ | Khi nào dùng | Những gì cần chạy | Có cần cửa sổ thật / screenshot? | Có cần Mutation-check? |
|---|---|---|---|---|
| **Tier 1 — Fast (Mặc định sau mỗi tính năng/fix)** | Đang phát triển từng tính năng hoặc sửa bug nhỏ | Target hẹp liên quan (`just test cargo`, `just test <suite>`, `just test translations`) + `cargo fmt --check` (nếu sửa Rust). Không chạy lại `just doctor` nếu môi trường không đổi. | Không bắt buộc | Không (với bugfix, ưu tiên TDD: viết test fail trước khi sửa) |
| **Tier 2 — Standard (Trước khi commit / chốt nhóm tính năng)** | Trước khi commit hoặc gộp nhiều thay đổi | Chạy full `just test` **1 lần duy nhất** + `cargo fmt --check`. | Chỉ khi sửa UI hiển thị (layout, dialog, menu, font, icon, theme) | Không bắt buộc |
| **Tier 3 — Deep (Khi người dùng gọi `/verify` hoặc chốt milestone)** | Người dùng chủ động yêu cầu kiểm tra kỹ lại | Chạy full `just test`, mở app thật (dùng trực tiếp `kogaview-dev`, không bắt buộc XDG cô lập), chụp screenshot `docs/evidence/`, kiểm tra log/journal, failure paths, tiếng Anh + tiếng Việt, và kiểm tra toàn bộ tồn đọng trong `docs/VERIFICATION-QUEUE.md`. | Có | Có (chọn lọc cho các bugfix/invariant quan trọng) |

### Quy tắc log lại những thứ chưa kiểm tra (`docs/VERIFICATION-QUEUE.md`)

Khi chạy ở **Tier 1** hoặc **Tier 2**, agent **bắt buộc** ghi lại các hạng mục bỏ qua vào file `docs/VERIFICATION-QUEUE.md` để khi người dùng gọi kiểm tra kỹ (**Tier 3 / `/verify`**), agent biết chính xác cần kiểm tra bù những gì — không bị sót và không phải đoán lại.

Mẫu cấu trúc cho `docs/VERIFICATION-QUEUE.md`:

```markdown
# Verification Queue (Các mục chưa kiểm tra kỹ)

Các hạng mục bên dưới đã qua kiểm tra nhanh (Tier 1/2) nhưng chưa qua kiểm tra đầy đủ (Tier 3).
Khi người dùng gọi `/verify`, kiểm tra lần lượt các mục đang mở, ghi bằng chứng, rồi xóa khỏi danh sách này (hoặc chuyển sang `docs/M1-REPORT.md` khi `/handoff`).

## Đang chờ kiểm tra

- [ ] **[YYYY-MM-DD] Tên tính năng / commit**
  - **File chính:** `...`
  - **Đã chạy:** `just test editor` (pass)
  - **Chưa kiểm tra:**
    - Chưa chạy cửa sổ thật trên Wayland để kiểm tra layout & icon
    - Chưa chụp ảnh kiểm tra bản dịch tiếng Việt
    - Chưa chạy full `just test`
    - Chưa kiểm tra failure path (file không tồn tại / hủy ngang)
```

---

## 2. Danh sách thay đổi sẽ áp dụng sau khi session kia hoàn tất

### A. Cắt gọn ngữ cảnh nạp đầu phiên (không mất dữ liệu cũ)
1. **Archive `docs/SESSION-STATE.md` (hiện 3,358 dòng / 272 KB):**
   - Di chuyển nguyên vẹn toàn bộ nội dung hiện tại sang `docs/SESSION-STATE-ARCHIVE.md` (không xóa bất kỳ dòng nào).
   - Viết lại `docs/SESSION-STATE.md` ngắn gọn (~50–80 dòng): chỉ giữ nhánh hiện tại, môi trường máy, các ghi chú quan trọng hiện hành, trạng thái mới nhất, và đường dẫn trỏ tới `docs/SESSION-STATE-ARCHIVE.md` khi cần tra cứu lịch sử.
2. **Tách handoff khỏi mỗi task nhỏ:**
   - Chỉ cập nhật `docs/M1-REPORT.md` (hiện 313 KB) và `docs/SESSION-STATE.md` khi người dùng chủ động gọi `/handoff`.

### B. Cập nhật quy trình trong `AGENTS.md`, `docs/WORKFLOW.md` và `.opencode/`
1. **`AGENTS.md` & `docs/WORKFLOW.md`:**
   - Đưa bảng **3 mức độ Check/Test (Tier 1 / Tier 2 / Tier 3)** làm chuẩn mặc định.
   - Bỏ yêu cầu chạy `just doctor` trước mọi lượt sửa nhỏ (chỉ chạy khi bắt đầu phiên mới trên môi trường lạ hoặc khi build lỗi).
   - Bỏ yêu cầu bắt buộc tự viết debug hook tạm vào `cpp/main.cpp` rồi xóa (tránh 2 lần rebuild C++ không cần thiết; chỉ thêm hook khi người dùng yêu cầu).
   - Thay mutation-check bắt buộc ở mọi fix thành: ưu tiên TDD (viết test fail trước) ở Tier 1, chỉ làm mutation-check chọn lọc ở Tier 3.
   - Thêm quy tắc ghi nhận mục chưa kiểm tra vào `docs/VERIFICATION-QUEUE.md`.
2. **Bỏ yêu cầu chạy trong XDG cô lập (`XDG_STATE_HOME=/tmp/opencode/...`):**
   - Cập nhật `AGENTS.md`, `.opencode/skills/real-window-verification/SKILL.md` và `.opencode/commands/run.md`:
     - Mặc định chạy trực tiếp `./build/dev/bin/kogaview` với thư mục dev chuẩn (`~/.local/state/kogaview-dev`, `~/.config/kogaview-dev`), vì bản dev đã có sẵn app ID và thư mục tách biệt hoàn toàn với bản production (`kogaview`).
     - Chỉ giữ ghi chú tùy chọn dùng `XDG_*=/tmp/opencode/...` khi cần test trường hợp lần chạy đầu tiên (clean-start / config rỗng).
3. **Cập nhật `.opencode/commands/verify.md`:**
   - Khi chạy `/verify` không kèm tham số, tự động đọc `docs/VERIFICATION-QUEUE.md` để kiểm tra bù các mục đang chờ và dọn sạch các mục đã xác nhận đạt.

### C. Tối ưu `scripts/dev.py` (áp dụng sau khi session kia hoàn tất sửa `scripts/dev.py`)
1. **Chạy song song các QML test suites** trong `qml_tests()`:
   - Dùng `concurrent.futures.ThreadPoolExecutor` chạy song song các binary `QT_QPA_PLATFORM=offscreen` thay vì chạy tuần tự từng bộ một.
2. **Bỏ bước `cmake --preset dev` (configure) lặp lại trong `build()`:**
   - Chỉ chạy `cmake --preset dev` khi `build/dev/CMakeCache.txt` chưa tồn tại (giống `qml_tests()` đã làm).
3. **Thêm tùy chọn chạy QML test không rebuild C++** (ví dụ `just test --no-build <suite>` hoặc tự kiểm tra mtime):
   - Khi chỉ sửa file `.qml` và binary test đã có sẵn, bỏ qua bước `cmake --build` để lặp QML gần như tức thì.
   - **Ràng buộc an toàn (tránh stale binary):** chỉ bỏ qua build khi không có file `.cpp`/`.h`/`.rs`/`CMakeLists.txt` nào mới hơn binary test; nếu có file C++/Rust mới hơn thì bắt buộc rebuild.

---

## 3. Rà soát xung đột với các nguyên tắc hiện có & cách xử lý

Qua đối chiếu với `AGENTS.md`, `docs/WORKFLOW.md`, `opencode.json` và `.opencode/commands/*.md`, có **6 điểm cần xử lý đồng bộ** để không tự mâu thuẫn:

1. **Nguyên tắc "Green tests ≠ proven" (`AGENTS.md`, `docs/WORKFLOW.md`, `.opencode/commands/test.md`):**
   - *Xung đột:* Luật cũ yêu cầu mọi thay đổi đều phải chạy app thật & mutation-check, và `.opencode/commands/test.md` tự động yêu cầu chạy `real-window-verification` sau `just test` khi Rust/C++ đổi.
   - *Cách xử lý:* Giữ nguyên tinh thần trung thực (không bao giờ tuyên bố "đã chứng minh trên desktop" chỉ từ test xanh), nhưng tách 2 trạng thái: **Tier 1/2 = "đã qua test tự động, chờ verify" (ghi vào `docs/VERIFICATION-QUEUE.md`)** và **Tier 3 = "đã verify trên cửa sổ thật"**. Sửa `.opencode/commands/test.md` để không tự ép chạy real-window sau mỗi `just test`.
2. **Bỏ XDG cô lập vs nguy cơ làm bẩn config dev (`~/.config/kogaview-dev`):**
   - *Xung đột:* Chạy trực tiếp trên `kogaview-dev` có thể ghi đè `config.json` dev (vd: khi test đổi ngôn ngữ `vi`, đổi theme, reset layout) và làm loãng `journal/commands.jsonl`.
   - *Cách xử lý:* Mặc định dùng trực tiếp `kogaview-dev` (vốn đã tách khỏi bản production `kogaview`); chỉ dùng `XDG_*=/tmp/opencode/...` khi test clean-start, test đổi ngôn ngữ/reset settings, hoặc cần journal sạch của đúng 1 phiên. Lưu ý vẫn phải tắt instance `kogaview-dev` cũ trước khi chụp ảnh vì single-instance theo App ID.
3. **Chế độ không rebuild QML vs luật "Never run stale binary" (`AGENTS.md`, `.opencode/commands/rebuild.md`):**
   - *Xung đột:* Nếu sửa `tests/qml/*.cpp` hoặc Rust/C++ mà chạy `--no-build`, test sẽ chạy trên binary cũ -> kết quả giả.
   - *Cách xử lý:* Tự kiểm tra `mtime` của binary test so với nguồn C++/Rust trong `scripts/dev.py` (hoặc cảnh báo/từ chối `--no-build` nếu có file C++/Rust mới hơn).
4. **Chạy song song 10 QML test suites vs dùng chung tài nguyên tạm:**
   - *Xung đột:* Nếu 2 suite cùng ghi vào 1 file tạm cố định hoặc dùng chung clipboard/XDG dir, chạy song song có thể gây flake.
   - *Cách xử lý:* Kiểm tra nhanh các suite trong `tests/qml/` trước khi bật song song; cấp `TMPDIR`/`XDG_*` riêng cho từng subprocess trong `scripts/dev.py` nếu cần.
5. **File `docs/VERIFICATION-QUEUE.md` vs luật không trộn doc vào commit code (`AGENTS.md`):**
   - *Xung đột:* Cập nhật `VERIFICATION-QUEUE.md` liên tục có thể lẫn vào commit sửa code.
   - *Cách xử lý:* Coi `docs/VERIFICATION-QUEUE.md` cùng nhóm với `docs/SESSION-STATE.md` — cập nhật riêng hoặc commit cùng đợt `/handoff` / `/verify`, không trộn vào commit code nếu muốn giữ lịch sử git sạch.
6. **Không thêm `docs/VERIFICATION-QUEUE.md` vào `opencode.json`:**
   - Để tránh lặp lại tình trạng phình context như `SESSION-STATE.md`, chỉ khai báo đường dẫn này trong `AGENTS.md` và `.opencode/commands/verify.md` để agent đọc/ghi theo nhu cầu.

---

## 4. Thứ tự thực hiện khi sẵn sàng

1. Kiểm tra `git status --short` đã sạch (session kia đã commit xong).
2. Di chuyển `docs/SESSION-STATE.md` -> `docs/SESSION-STATE-ARCHIVE.md` và tạo `docs/SESSION-STATE.md` rút gọn.
3. Tạo `docs/VERIFICATION-QUEUE.md`.
4. Cập nhật đồng bộ `AGENTS.md`, `docs/WORKFLOW.md`, `.opencode/skills/real-window-verification/SKILL.md`, `.opencode/commands/run.md`, `.opencode/commands/test.md`, `.opencode/commands/verify.md`, `.opencode/commands/doctor.md`.
5. Áp dụng phần tối ưu trong `scripts/dev.py` (kèm kiểm tra stale binary và an toàn khi chạy song song) và chạy thử `just test` để xác nhận.
