// Generated tables of the compiled-in translations. Edit
// `i18n/kogaview_vi.ts` and run `lupdate`/`just build`; never edit this file by
// hand — `scripts/check_translations.py` compares it with the `.ts` catalogue.

#include "translations.h"

#include <QHash>
#include <QStringList>

namespace kogaview::i18n {

static const Entry kEntries_vi[] = {
  // context: BrowserView
  { "Quick access", "Truy cập nhanh" },
  { "Folders", "Thư mục" },
  { "Hidden parent folders", "Thư mục cha bị ẩn" },
  { "Loading…", "Đang tải…" },
  { "Preview", "Xem trước" },
  { "Type", "Loại" },
  { "Size", "Dung lượng" },
  { "Dimensions", "Kích thước" },
  { "Modified", "Đã sửa lúc" },
  { "Path", "Đường dẫn" },
  { "Open", "Mở" },
  { "Edit", "Chỉnh sửa" },
  { "Open with…", "Mở bằng…" },
  { "Copy image content", "Sao chép nội dung ảnh" },
  { "Copy file path", "Sao chép đường dẫn tệp" },
  { "Copy to…", "Sao chép tới…" },
  { "Move to…", "Di chuyển tới…" },
  { "Move to trash", "Chuyển vào thùng rác" },
  { "Delete permanently…", "Xoá vĩnh viễn…" },
  { "Explore here", "Duyệt tới đây" },
  { "New folder…", "Thư mục mới…" },
  { "Copy path", "Sao chép đường dẫn" },
  { "Move up", "Di chuyển lên" },
  { "Move down", "Di chuyển xuống" },
  { "Remove from quick access", "Bỏ khỏi truy cập nhanh" },
  { "New folder", "Thư mục mới" },
  { "Folder name", "Tên thư mục" },
  { "Go to parent folder (Backspace)", "Tới thư mục cha (Backspace)" },
  { "Refresh (F5)", "Làm mới (F5)" },
  { "Open folder… (Ctrl+Shift+O)", "Mở thư mục… (Ctrl+Shift+O)" },
  { "Toggle quick access and folder tree", "Bật/tắt truy cập nhanh và cây thư mục" },
  { "Toggle preview and metadata panel", "Bật/tắt bảng xem trước và thông tin" },
  // context: EditorView
  { "Open an image for editing", "Mở ảnh để chỉnh sửa" },
  { "Undo", "Hoàn tác" },
  { "Redo", "Làm lại" },
  { "Zoom out", "Thu nhỏ" },
  { "Zoom in", "Phóng to" },
  { "Fit to window", "Vừa cửa sổ" },
  { "Actual size (100%)", "Kích thước thật (100%)" },
  { "Save", "Lưu" },
  { "Save as…", "Lưu thành…" },
  { "Save (Ctrl+S)", "Lưu (Ctrl+S)" },
  { "Save as… (Ctrl+Shift+S)", "Lưu thành… (Ctrl+Shift+S)" },
  { "Back to browser", "Về trình duyệt" },
  { "Rotate left", "Xoay trái" },
  { "Rotate right", "Xoay phải" },
  { "Flip horizontal", "Lật ngang" },
  { "Flip vertical", "Lật dọc" },
  { "History", "Lịch sử" },
  { "No edits yet", "Chưa có chỉnh sửa nào" },
  { "No image open", "Chưa mở ảnh" },
  { "Reset to original", "Về ảnh gốc" },
  { "Opening %1…", "Đang mở %1…" },
  { "Open an image…", "Mở một ảnh…" },
  { "Image", "Ảnh" },
  { "edited", "đã sửa" },
  { "saved", "đã lưu" },
  { "unsaved changes", "chưa lưu" },
  { "Saving…", "Đang lưu…" },
  { "Resize", "Đổi kích thước" },
  { "Width", "Rộng" },
  { "Height", "Cao" },
  { "Apply", "Áp dụng" },
  { "Crop", "Cắt" },
  // context: Main
  { "Open images", "Mở ảnh" },
  { "Open an image for editing", "Mở ảnh để chỉnh sửa" },
  { "Open folder", "Mở thư mục" },
  { "Choose destination folder", "Chọn thư mục đích" },
  { "Main menu", "Menu chính" },
  { "%1 items · %2 images", "%1 mục · %2 ảnh" },
  { "rev %1", "bản sửa %1" },
  { "Cancel", "Huỷ" },
  { "Delete permanently?", "Xoá vĩnh viễn?" },
  { "Permanently delete %1 item(s)? This cannot be undone.", "Xoá vĩnh viễn %1 mục? Không thể hoàn tác thao tác này." },
  { "Save image as", "Lưu ảnh thành" },
  { "Unsaved changes", "Thay đổi chưa lưu" },
  { "The editor has changes that are not saved to a file. Save them first?", "Trình chỉnh sửa có thay đổi chưa lưu vào tệp. Lưu lại trước không?" },
  // context: SettingsDialog
  { "Settings", "Cài đặt" },
  { "Appearance", "Giao diện" },
  { "Theme", "Chủ đề" },
  { "Browsing", "Đang duyệt" },
  { "Remember the last opened folder", "Nhớ thư mục mở gần nhất" },
  { "Generate thumbnails in the background", "Tạo hình thu nhỏ ở chế độ nền" },
  { "Changes are previewed as you make them. Apply saves them; OK saves and closes.", "Thay đổi được xem trước ngay khi bạn chọn. Áp dụng để lưu; OK để lưu và đóng." },
  { "Apply", "Áp dụng" },
  { "OK", "OK" },
  { "Defaults", "Mặc định" },
  { "Cancel", "Huỷ" },
  // context: Viewer
  { "Open an image to start viewing", "Mở một ảnh để bắt đầu xem" },
  { "This image cannot be decoded", "Không giải mã được ảnh này" },
  { "Edit", "Chỉnh sửa" },
  { "Open with…", "Mở bằng…" },
  { "Copy image content", "Sao chép nội dung ảnh" },
  { "Copy file path", "Sao chép đường dẫn tệp" },
  { "Copy to…", "Sao chép tới…" },
  { "Move to…", "Di chuyển tới…" },
  { "Move to trash", "Chuyển vào thùng rác" },
  { "Delete permanently…", "Xoá vĩnh viễn…" },
  { "Fit to window", "Vừa cửa sổ" },
  { "Actual size", "Kích thước thật" },
  { "Rotate left", "Xoay trái" },
  { "Rotate right", "Xoay phải" },
  { "Back to browser (Esc/Backspace)", "Về trình duyệt (Esc/Backspace)" },
  { "Fit to window (F)", "Vừa cửa sổ (F)" },
  { "Previous image (Left)", "Ảnh trước (Left)" },
  { "Next image (Right)", "Ảnh sau (Right)" },
  { "Zoom in (+ or scroll wheel)", "Phóng to (+ hoặc lăn chuột)" },
  { "Zoom out (- or scroll wheel)", "Thu nhỏ (- hoặc lăn chuột)" },
  { "Actual size at 100% (0/1)", "Kích thước thật 100% (0/1)" },
  { "Rotate left (Shift+R)", "Xoay trái (Shift+R)" },
  { "Rotate right (R)", "Xoay phải (R)" },
  { "Flip horizontally (H)", "Lật ngang (H)" },
  { "Flip vertically (V)", "Lật dọc (V)" },
  { "Toggle thumbnail filmstrip (T)", "Bật/tắt dải hình thu nhỏ (T)" },
  // context: WorkspaceSwitcher
  { "Browser", "Duyệt ảnh" },
  { "Browser workspace: folders and thumbnails (Ctrl+1)", "Không gian duyệt ảnh: thư mục và hình thu nhỏ (Ctrl+1)" },
  { "Viewer", "Xem ảnh" },
  { "Viewer workspace: zoom, pan, rotate (Ctrl+2)", "Không gian xem ảnh: thu phóng, di chuyển, xoay (Ctrl+2)" },
  { "Editor", "Trình chỉnh sửa" },
  { "Editor workspace: non-destructive edits (Ctrl+3)", "Không gian chỉnh sửa: sửa ảnh không phá huỷ (Ctrl+3)" },
  { nullptr, nullptr },
};


static const Catalogue kTable_vi {
  "vi",
  kEntries_vi,
};


static const Catalogue* const kTables[] = {
  &kTable_vi,
  nullptr,
};

const Catalogue* const* catalogues()
{
  return kTables;
}

const Catalogue* catalogue(const QString& locale)
{
  // `vi_VN` and `vi` are the same catalogue; the region picks plural forms and
  // number formats, not a different set of strings.
  const QString language = locale.section(QLatin1Char('_'), 0, 0);
  for (const Catalogue* const* table = kTables; *table != nullptr; ++table) {
    if (language == QLatin1String((*table)->locale)) {
      return *table;
    }
  }
  return nullptr;
}

QString translate(const QString& locale, const char* source)
{
  if (source == nullptr || *source == '\0') {
    return QString();
  }
  const Catalogue* found = catalogue(locale);
  if (found == nullptr) {
    return QString::fromUtf8(source);
  }
  // One hash per catalogue, filled on first use: the dialogs ask for the same
  // handful of labels every time they open.
  static QHash<const Catalogue*, QHash<QString, QString>> lookups;
  const QString key = QString::fromUtf8(source);
  auto cached = lookups.find(found);
  if (cached == lookups.end()) {
    QHash<QString, QString> entries;
    for (const Entry* entry = found->entries; entry->source != nullptr; ++entry) {
      entries.insert(QString::fromUtf8(entry->source), QString::fromUtf8(entry->translation));
    }
    cached = lookups.insert(found, entries);
  }
  return cached->value(key, key);
}

} // namespace kogaview::i18n
