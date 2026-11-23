import QtQuick
import QtQuick.Dialogs

/// Unified facade for system dialogs (Open files, Open folder, Save file, Color).
///
/// Prefers XDG Desktop Portal via C++ `Platform` (`requestOpenFile`,
/// `requestOpenFolder`, `requestSaveFile`) so every workspace and modal form
/// opens the desktop's own portal chooser, falling back to Qt's `FileDialog` /
/// `FolderDialog` only when no portal is available (e.g. headless QML tests or
/// non-portal sessions).
Item {
    id: root
    visible: false

    property var _pendingCallback: null
    property string _pendingKind: ""

    function _toLocalPath(url) {
        var text = "" + (url || "")
        if (text.indexOf("file://") === 0) {
            return decodeURIComponent(text.substring(7))
        }
        return text
    }

    function _portalAvailable() {
        return typeof Platform !== "undefined" && Platform !== null && Platform.portalAvailable
    }

    function openFiles(title, onChosen) {
        root._pendingCallback = onChosen || null
        root._pendingKind = "files"
        if (root._portalAvailable() && Platform.requestOpenFile(title)) {
            return true
        }
        openFilesFallback.title = title
        openFilesFallback.open()
        return false
    }

    function openFolder(title, onChosen) {
        root._pendingCallback = onChosen || null
        root._pendingKind = "folder"
        if (root._portalAvailable() && Platform.requestOpenFolder(title)) {
            return true
        }
        openFolderFallback.title = title
        openFolderFallback.open()
        return false
    }

    function saveFile(title, currentName, onChosen) {
        root._pendingCallback = onChosen || null
        root._pendingKind = "save"
        if (root._portalAvailable() && Platform.requestSaveFile(title, currentName || "")) {
            return true
        }
        saveFileFallback.title = title
        saveFileFallback.currentFile = currentName || ""
        saveFileFallback.open()
        return false
    }

    function pickColor(title, initialColor, onChosen) {
        root._pendingCallback = onChosen || null
        root._pendingKind = "color"
        colorFallback.title = title
        colorFallback.selectedColor = initialColor
        colorFallback.open()
    }

    Connections {
        target: typeof Platform !== "undefined" ? Platform : null
        ignoreUnknownSignals: true

        function onFilesSelected(paths) {
            if (root._pendingKind !== "files" || !root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(paths)
        }
        function onFolderSelected(path) {
            if (root._pendingKind !== "folder" || !root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(path)
        }
        function onSaveFileSelected(path) {
            if (root._pendingKind !== "save" || !root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(path)
        }
    }

    FileDialog {
        id: openFilesFallback
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            if (!root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            var out = []
            for (var i = 0; i < selectedFiles.length; ++i) {
                out.push(root._toLocalPath(selectedFiles[i]))
            }
            cb(out)
        }
        onRejected: {
            root._pendingCallback = null
            root._pendingKind = ""
        }
    }

    FolderDialog {
        id: openFolderFallback
        onAccepted: {
            if (!root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(root._toLocalPath(selectedFolder))
        }
        onRejected: {
            root._pendingCallback = null
            root._pendingKind = ""
        }
    }

    FileDialog {
        id: saveFileFallback
        fileMode: FileDialog.SaveFile
        onAccepted: {
            if (!root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(root._toLocalPath(selectedFile))
        }
        onRejected: {
            root._pendingCallback = null
            root._pendingKind = ""
        }
    }

    ColorDialog {
        id: colorFallback
        onAccepted: {
            if (!root._pendingCallback) return
            var cb = root._pendingCallback
            root._pendingCallback = null
            root._pendingKind = ""
            cb(selectedColor)
        }
        onRejected: {
            root._pendingCallback = null
            root._pendingKind = ""
        }
    }
}
