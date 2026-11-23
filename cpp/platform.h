#pragma once

#include <QFont>
#include <QObject>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

namespace kogaview::i18n {
QString translate(const QString& locale, const char* source);
}

class QTimer;
class QUrl;

/// Desktop integration that must stay outside Core: XDG portal file dialogs,
/// clipboard access and handing files to the desktop's default handler.
///
/// Portal dialogs are preferred. When the portal service is unavailable the
/// invokables return false and QML falls back to a Qt dialog.
class PlatformHelper : public QObject
{
  Q_OBJECT
  Q_PROPERTY(bool portalAvailable READ portalAvailable CONSTANT)

public:
  explicit PlatformHelper(QObject* parent = nullptr);
  ~PlatformHelper() override;

  bool portalAvailable() const { return m_portalAvailable; }

  /// Start an XDG FileChooser request. Returns false when the portal cannot be
  /// used, so the caller can show a fallback dialog.
  Q_INVOKABLE bool requestOpenFile(const QString& title);
  Q_INVOKABLE bool requestOpenFolder(const QString& title);
  /// Ask where a file should be written (`FileChooser.SaveFile`).
  ///
  /// "Save as" is the same desktop dialog as "Open", with the desktop's own
  /// overwrite question; the Qt fallback was the only chooser that *did not*
  /// go through the portal, so the user met a different, cramped dialog with a
  /// file-type combo on one workspace and the desktop's own everywhere else.
  /// `currentName` is the file name the dialog opens on (no folder).
  Q_INVOKABLE bool requestSaveFile(const QString& title, const QString& currentName);
  /// Pick a screen colour via XDG `Screenshot.PickColor` portal. Returns false
  /// when the portal is unavailable or another portal request is active.
  Q_INVOKABLE bool requestPickColor();

  /// Close the file dialog that is still open. Used when the window goes away
  /// (and by the QA harness) so no portal request is left behind; the portal
  /// answers a closed request with response 1 on the subscription we installed
  /// up front.
  Q_INVOKABLE void dismissActiveDialog();

  /// Decode an image file on a worker thread and place the pixels on the
  /// clipboard (image/png on Wayland).
  Q_INVOKABLE void copyImage(const QString& path);
  Q_INVOKABLE void copyText(const QString& text);
  /// Hand the file to the desktop's default handler.
  Q_INVOKABLE void openExternally(const QString& path);
  /// Show the desktop's own "Open With" chooser for the file, so the user picks
  /// the application instead of getting the default one.
  Q_INVOKABLE void openWith(const QString& path);
  Q_INVOKABLE void revealInFolder(const QString& path);

  /// Width in pixels each of `labels` needs when drawn with `font`.
  ///
  /// A menu cannot measure its own entries: a `Menu`'s `font` follows its width,
  /// so a width binding that reads text metrics of the same menu loops. The
  /// measurement happens here, where it is a plain computation with no binding
  /// involved, and QML only receives the numbers.
  Q_INVOKABLE QVariantList textWidths(const QStringList& labels, const QFont& font);

  /// Pixel size an image file declares, read from its header only.
  ///
  /// `open FILE` from the shell sizes the window to the picture before the
  /// Viewer has decoded anything, so the user never sees 1280×820 followed by a
  /// jump to the image's shape. Reading the header costs a file open, not a
  /// decode, which is why this runs synchronously at startup. Returns an empty
  /// size for a file whose header cannot be read; the caller keeps its default.
  Q_INVOKABLE QSize imageSize(const QString& path) const;

  /// File-dialog filter for the image formats Core can decode
  /// (`kogaview_protocol::IMAGE_EXTENSIONS`). One definition for every chooser.
  Q_INVOKABLE QString imageNameFilter() const;

  /// "Name (*.png)" entries a save dialog offers, in the order `SAVE_FORMATS`
  /// declares them, translated like the rest of the UI.
  Q_INVOKABLE QStringList saveNameFilters() const;

  /// The locale the interface is in, for the labels this helper spells itself:
  /// `KOGAVIEW_UI_LANG`, else the installed translator, else empty (the
  /// desktop language, whose strings are English).
  QString interfaceLocale() const;

  /// The languages the interface can be shown in: `system`, `en`, `vi`. The
  /// labels are in the target language on purpose — a language picker you can
  /// only read in the language you do not speak yet is useless.
  Q_INVOKABLE QVariantList languages() const;

  /// Sync the Qt application palette and colour-scheme hint with KogaView's
  /// active `Theme` so popups (`Menu`, `ComboBox` dropdowns, `ToolTip`) and
  /// stock controls follow Light/Dark mode instead of the desktop's own theme.
  Q_INVOKABLE void applyThemePalette(const QVariantMap& colors, bool dark);

signals:
  void filesSelected(const QStringList& paths);
  void folderSelected(const QString& path);
  /// The answer to `requestSaveFile`: one path, already a local file path.
  void saveFileSelected(const QString& path);
  /// The answer to `requestPickColor`: `#rrggbb` hex colour picked from screen.
  void colorPicked(const QString& hex);
  void copyResult(bool ok, const QString& message);
  void dialogError(const QString& message);
  void info(const QString& message);

private slots:
  void onPortalResponse(uint response, const QVariantMap& results);

private:
  bool request(const QString& method, const QString& title, const QVariantMap& options);
  /// XDG `FileChooser` interface version, 0 when it cannot be read.
  uint fileChooserVersion() const;
  /// Subscribe to the `Response` signal of `handle` before the portal can emit
  /// it. Returns false when the subscription failed.
  bool listenTo(const QString& handle);
  void stopListening();
  /// Ask the portal to dismiss the dialog that is still open, so a timed-out or
  /// abandoned request does not leave a window behind.
  void closeOpenRequest();
  void resetRequest();
  /// Close the dialog and stop listening without reporting an error.
  void abandonRequest();
  void finishWithError(const QString& message);

  /// `parent_window` for portal calls: the X11 window handle when it can be
  /// expressed, otherwise empty (portals then open a non-modal dialog).
  static QString parentWindowIdentifier();
  /// The request object path the portal will use for `token`, derived from our
  /// own unique bus name. Portals may already have emitted `Response` by the
  /// time the method reply arrives, so this is subscribed to *first*.
  static QString predictedRequestPath(const QString& token);
  bool openUriWithPortal(const QUrl& url, bool directory);
  /// `org.freedesktop.portal.OpenURI.OpenFile` with `ask`, which is what makes
  /// the portal show its application chooser (version 2 and later).
  bool openFileWithChooser(const QUrl& url);
  /// Version of a portal interface, 0 when it cannot be read.
  uint portalInterfaceVersion(const QString& interface) const;
  /// Ask the desktop to show its "Open With" chooser through something other
  /// than the portal. False when the platform has no such route, so the caller
  /// can fall back to opening the file with the default application.
  bool openWithSystemChooser(const QString& path);

  bool m_portalAvailable = false;
  bool m_folderMode = false;
  bool m_saveMode = false;
  bool m_colorMode = false;
  bool m_requestActive = false;
  bool m_dismissing = false;
  QString m_requestPath;
  QString m_connectionService;
  QTimer* m_timeout = nullptr;
};
