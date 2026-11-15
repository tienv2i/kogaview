#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

class QTimer;

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

  /// Decode an image file on a worker thread and place the pixels on the
  /// clipboard (image/png on Wayland).
  Q_INVOKABLE void copyImage(const QString& path);
  Q_INVOKABLE void copyText(const QString& text);
  Q_INVOKABLE void openExternally(const QString& path);
  Q_INVOKABLE void revealInFolder(const QString& path);

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
  void resetRequest();
  void finishWithError(const QString& message);

  bool m_portalAvailable = false;
  bool m_folderMode = false;
  bool m_requestActive = false;
  QString m_requestPath;
  QString m_connectionService;
  QTimer* m_timeout = nullptr;
};
