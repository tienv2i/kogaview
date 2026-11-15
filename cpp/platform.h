#pragma once

#include <QFont>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

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

signals:
  void filesSelected(const QStringList& paths);
  void folderSelected(const QString& path);
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
  bool m_requestActive = false;
  bool m_dismissing = false;
  QString m_requestPath;
  QString m_connectionService;
  QTimer* m_timeout = nullptr;
};
