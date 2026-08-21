import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "salted.TV"

    visible: true
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property string setupScript: Qt.resolvedUrl("salted-tv-setup.sh").toString().replace(/^file:\/\//, "")
    readonly property string pendingOpenMarker: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/salted.TV/.pending-open"
    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool userClickedInstall: false
    property bool shellRestartQueued: false
    property bool notificationsEnabled: false

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.setupOutput = "";
        setupProc.command = ["bash", root.setupScript];
        setupProc.running = true;
    }

    function injectPanel() {
        var target = panelLoader.item;
        if (!target) return;
        if ("bar" in target) target.bar = root.bar;
        if ("settings" in target) target.settings = root.settings;
        if ("anchorItem" in target) target.anchorItem = button;
        if ("hostWidget" in target) target.hostWidget = root;
    }

    function togglePanel() {
        if (panelLoader.status === Loader.Error) {
            notify("salted.TV — Panel Load Error", "Failed to load Panel.qml — check logs", "critical");
            return;
        }
        if (!panelLoader.item) {
            notify("salted.TV — Panel Not Ready", "Loader status=" + panelLoader.status, "critical");
            return;
        }
        if (!root.bridgeReady) {
            root.userClickedInstall = true;
            touchProc.command = ["touch", root.pendingOpenMarker];
            touchProc.running = true;
            root.ensureBridge();
        }
        if (panelLoader.item && panelLoader.item.toggle) {
            panelLoader.item.toggle();
        } else if (panelLoader.item && panelLoader.item.openFromHotkey) {
            if (root.opened) panelLoader.item.close();
            else panelLoader.item.openFromHotkey();
        }
    }

    function consumePendingOpen() {
        markerProc.out = "";
        markerProc.command = ["bash", "-c", "m=\"$1\"; [ -f \"$m\" ] && rm -f \"$m\" && echo OPEN", "_", root.pendingOpenMarker];
        markerProc.running = true;
    }
    function open() {
        if (panelLoader.item && panelLoader.item.openFromHotkey)
            panelLoader.item.openFromHotkey();
    }
    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
            panelLoader.item.closeForPopoutSwitch();
    }

    function notify(title, body, urgency) {
        if (!root.notificationsEnabled) return
        var u = urgency || "normal";
        var t = title || "salted.TV";
        var b = body || "";
        notifyProc.command = ["notify-send", "-a", "salted.TV", "-u", u, "-i", "video-display", t, b];
        notifyProc.running = true;
    }

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Process {
        id: setupProc
        property string setupOutput: ""
        property string errorOutput: ""
        stdout: SplitParser {
            onRead: function(data) { setupProc.setupOutput += data + "\n" }
        }
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onExited: function(exitCode) {
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge setup failed";
                notify("salted.TV — Setup failed", root.bridgeError, "critical");
                return;
            }
            var out = setupProc.setupOutput;
            var restartScheduled = out.indexOf("SALTEDTV_RESTART_SHELL=1") !== -1;
            if (restartScheduled) {
                if (!root.shellRestartQueued) {
                    root.shellRestartQueued = true;
                    notify("salted.TV — Installed", "Restarting Omarchy shell once …", "normal");
                    restartProc.command = ["bash", "-c", "command -v omarchy-restart-shell >/dev/null 2>&1 && exec omarchy-restart-shell || echo 'omarchy-restart-shell not found; skipping'"];
                    restartProc.running = true;
                }
                return;
            }
            if (root.userClickedInstall) {
                root.userClickedInstall = false;
                touchProc.command = ["rm", "-f", root.pendingOpenMarker];
                touchProc.running = true;
                Qt.callLater(root.togglePanel);
            }
        }
    }

    Process {
        id: markerProc
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { markerProc.out += data }
        }
        onExited: function(exitCode) {
            if (markerProc.out.indexOf("OPEN") !== -1)
                Qt.callLater(root.togglePanel);
        }
    }

    Process {
        id: touchProc
    }

    Process {
        id: notifyProc
    }

    Process {
        id: restartProc
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("salted.TV Panel failed to load:", source);
                root.notify("salted.TV — Loader Error", "Panel.qml failed to load (status Error)", "critical");
            }
        }
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: ""
        slotSize: Style.bar.statusSlot
        iconComponent: Component {
            Item {
                anchors.fill: parent

                Text {
                    id: frame
                    anchors.centerIn: parent
                    text: "\uf26c"
                    font.family: Style.font.family
                    font.pixelSize: Style.bar.iconFont
                    color: button.active && button.useActiveColor ? button.activeColor : button.foreground
                }

                Text {
                    anchors.horizontalCenter: frame.horizontalCenter
                    y: frame.y + frame.height * 0.22
                    text: "\uf04b"
                    font.family: Style.font.family
                    font.pixelSize: Style.bar.iconFont * 0.34
                    color: Color.accent
                }

            }
        }
        tooltipText: root.installing ? "salted.TV • installing bridge …" :
                     (root.bridgeReady ? "salted.TV • IPTV — free-to-air channels via iptv-org → mpv" :
                      (root.bridgeError || "salted.TV • bridge not ready; click to retry"))
        onPressed: root.togglePanel()
    }

    Component.onCompleted: {
        root.consumePendingOpen();
        root.ensureBridge();
    }
}
