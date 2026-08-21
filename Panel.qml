import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root
    readonly property string bridge: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/salted.TV/salted-tv-bridge.py"

    property string band: "fm"
    property string freqText: "100.1"
    property string gainText: ""
    property var channels: ({
        "fm": [],
        "tv": []
    })
    property var stations: []
    property bool busy: false
    property string busyLabel: ""
    property string statusText: "SoapySDR tuner — pick a channel or type a frequency"
    property bool playing: false
    property int channelsGen: 0
    property int scanGen: 0
    property int statusGen: 0

    property var pending: []
    property var cbChain: null

    moduleName: "salted.TV"
    implicitWidth: 640
    implicitHeight: 470

    Process {
        id: bridgeProc

        property string collected: ""

        onExited: function(code, status) {
            var cb = root.cbChain;
            root.cbChain = null;
            var resp = null;
            try {
                resp = JSON.parse(bridgeProc.collected);
            } catch (e) {
            }
            bridgeProc.collected = "";
            if (cb)
                cb(resp, code);

            if (root.pending.length > 0) {
                var next = root.pending.shift();
                root._start(next.cmd, next.params, next.cb);
            }
        }

        stdout: SplitParser {
            onRead: function(data) {
                bridgeProc.collected += data;
            }
        }

    }

    Timer {
        id: statusTimer

        interval: 3000
        repeat: true
        running: root.opened
        onTriggered: root.pollStatus()
    }

    ListModel {
        id: channelModel
    }

    function request(cmd, params, cb) {
        params = params || {
        };
        if (bridgeProc.running) {
            root.pending.push({
                "cmd": cmd,
                "params": params,
                "cb": cb
            });
            return ;
        }
        root._start(cmd, params, cb);
    }

    function _start(cmd, params, cb) {
        bridgeProc.collected = "";
        root.cbChain = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = cmd;
        bridgeProc.command = ["python3", root.bridge, JSON.stringify(req)];
        bridgeProc.running = true;
    }

    function setBusy(label) {
        root.busy = !!label;
        root.busyLabel = label || "";
    }

    function applyChannels(ch) {
        if (!ch)
            return ;
        root.channels = ch;
        channelModel.clear();
        var lst = (band === "fm" ? ch.fm : ch.tv) || [];
        for (var i = 0; i < lst.length; i++)
            channelModel.append(lst[i]);
    }

    function loadChannels() {
        var gen = ++root.channelsGen;
        request("channels", {}, function(resp) {
            if (gen !== root.channelsGen || !resp || !resp.ok)
                return ;

            applyChannels(resp.channels);
        });
    }

    function pollStatus() {
        var gen = ++root.statusGen;
        request("status", {}, function(resp) {
            if (gen !== root.statusGen || !resp || !resp.ok)
                return ;

            root.playing = resp.playing === true;
        });
    }

    function validFreq() {
        var f = parseFloat(freqText.replace(",", "."));
        if (isNaN(f))
            return -1;
        if (band === "fm" && (f < 87.5 || f > 108))
            return -1;
        if (band === "tv" && (f < 47 || f > 860))
            return -1;
        return Math.round(f * 1000) / 1000;
    }

    function doPlay(freq) {
        var f = (freq !== undefined) ? freq : validFreq();
        if (f < 0) {
            statusText = band === "fm" ? "FM frequency must be 87.5–108 MHz" : "DVB-T frequency must be 47–860 MHz";
            return ;
        }
        var g = gainText.trim() === "" ? null : parseFloat(gainText);
        setBusy("Tuning " + f + " MHz …");
        request("play", {
            "band": band,
            "freq": f,
            "gain": g
        }, function(resp) {
            setBusy("");
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Play failed";
                return ;
            }
            root.playing = true;
            statusText = "Playing " + band.toUpperCase() + " " + f + " MHz in mpv";
        });
    }

    function doStop() {
        request("stop", {}, function(resp) {
            root.playing = false;
            statusText = (resp && resp.ok) ? "Stopped" : "Stop failed";
        });
    }

    function doScan() {
        if (root.busy)
            return ;
        var gen = ++root.scanGen;
        setBusy("Scanning FM band …");
        stations = [];
        request("scan", {}, function(resp) {
            if (gen !== root.scanGen)
                return ;

            setBusy("");
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Scan failed";
                return ;
            }
            root.stations = resp.stations || [];
            statusText = root.stations.length ? ("Found " + root.stations.length + " candidate station(s)") : "No stations found above noise floor";
        });
    }

    function addCurrent() {
        var f = validFreq();
        if (f < 0) {
            statusText = "Enter a valid frequency first";
            return ;
        }
        request("add", {
            "band": band,
            "freq": f,
            "name": f + " MHz"
        }, function(resp) {
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Save failed";
                return ;
            }
            applyChannels(resp.channels);
            statusText = "Saved " + f + " MHz to " + band.toUpperCase() + " channels";
        });
    }

    function removeChannel(freq) {
        request("remove", {
            "band": band,
            "freq": freq
        }, function(resp) {
            if (resp && resp.ok)
                applyChannels(resp.channels);
        });
    }

    function refreshCurrent() {
        loadChannels();
        pollStatus();
    }

    function openFromHotkey() {
        refreshCurrent();
        panel.openFromHotkey();
    }

    function close() {
        panel.close();
    }

    function toggle() {
        if (panel.opened)
            panel.close();
        else
            openFromHotkey();
    }

    function closeForPopoutSwitch() {
        if (panel.closeForPopoutSwitch)
            panel.closeForPopoutSwitch();
        else
            close();
    }

    Component.onCompleted: refreshCurrent()

    KeyboardPanel {
        id: panel

        readonly property bool isSmallScreen: panel.screenW > 0 && panel.screenW < 1366
        readonly property real uiScale: Math.min(1.4, Math.max(0.9, panel.screenW / 1920))

        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: true
        margin: Style.gapsOut
        gap: Style.gapsOut
        contentWidth: isSmallScreen ? panel.fittedContentWidth(panel.screenW * 0.78) : panel.fittedContentWidth(panel.screenW * 0.5)
        contentHeight: isSmallScreen ? panel.fittedContentHeight(panel.screenH * 0.84, panel.screenH * 0.94) : panel.fittedContentHeight(panel.screenH * 0.7, panel.screenH * 0.82)

        ColumnLayout {
            id: mainColumn

            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: 8

                        Text {
                            text: "\uf26c"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                            color: Color.accent
                        }

                        Text {
                            text: "salted.TV"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                            color: Color.foreground
                        }

                        Rectangle {
                            width: 1
                            height: 18
                            color: Color.foreground
                            opacity: 0.12
                            Layout.leftMargin: 4
                            Layout.rightMargin: 4
                        }

                        Text {
                            text: root.band === "fm" ? "FM Radio" : "DVB-T • experimental"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            color: Qt.darker(Color.foreground, 1.25)
                            font.capitalization: Font.AllUppercase
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        RowLayout {
                            spacing: 6
                            visible: root.busy || root.playing

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: Color.accent
                                opacity: 0.9
                                visible: root.busy

                                SequentialAnimation on opacity {
                                    running: root.busy
                                    loops: Animation.Infinite

                                    NumberAnimation {
                                        from: 0.4
                                        to: 1
                                        duration: 700
                                    }

                                    NumberAnimation {
                                        from: 1
                                        to: 0.4
                                        duration: 700
                                    }

                                }

                            }

                            Text {
                                textFormat: Text.PlainText
                                text: root.busy ? root.busyLabel : "On air"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Color.accent
                            }

                        }

                    }

                    Text {
                        textFormat: Text.PlainText
                        text: root.statusText
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption - 1
                        color: Qt.darker(Color.foreground, 1.35)
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        maximumLineCount: 1
                    }

                }

                Button {
                    text: "\u21bb"
                    tooltipText: "Refresh"
                    fontSize: Style.font.body
                    horizontalPadding: 10
                    verticalPadding: 5
                    onClicked: root.refreshCurrent()
                }

                Button {
                    text: "✕"
                    tooltipText: "Close"
                    fontSize: Style.font.body
                    horizontalPadding: 12
                    verticalPadding: 6
                    onClicked: root.close()
                }

            }

            PanelSeparator {
                Layout.fillWidth: true
                opacity: 0.5
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    text: "FM"
                    tooltipText: "Broadcast FM radio (87.5–108 MHz)"
                    selected: root.band === "fm"
                    enabled: !root.busy
                    onClicked: {
                        root.band = "fm";
                        root.freqText = "100.1";
                        root.loadChannels();
                    }
                }

                Button {
                    text: "DVB-T"
                    tooltipText: "Digital TV via leandvb software demodulation (experimental)"
                    selected: root.band === "tv"
                    enabled: !root.busy
                    onClicked: {
                        root.band = "tv";
                        root.freqText = "474";
                        root.loadChannels();
                    }
                }

                TextField {
                    id: freqField

                    Layout.preferredWidth: 110
                    placeholderText: root.band === "fm" ? "87.5–108" : "474"
                    text: root.freqText
                    onTextChanged: root.freqText = text
                    onAccepted: root.doPlay()
                    Keys.onEscapePressed: if (hasFocus) root.close()
                }

                Text {
                    text: "MHz"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                }

                TextField {
                    id: gainField

                    Layout.preferredWidth: 70
                    placeholderText: "auto"
                    text: root.gainText
                    onTextChanged: root.gainText = text
                }

                Item {
                    Layout.fillWidth: true
                }

                Button {
                    text: "Scan"
                    iconText: "\uf002"
                    tooltipText: "Power-scan the FM band with rx_power"
                    enabled: root.band === "fm" && !root.busy
                    onClicked: root.doScan()
                }

                Button {
                    text: "Save"
                    iconText: "\uf00c"
                    tooltipText: "Save current frequency to channels"
                    enabled: !root.busy
                    onClicked: root.addCurrent()
                }

                Button {
                    text: root.playing ? "■ Stop" : "▶ Play"
                    selected: true
                    enabled: !root.busy
                    onClicked: root.playing ? root.doStop() : root.doPlay()
                }

            }

            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: root.stations.length > 0 && root.band === "fm"

                Repeater {
                    model: root.stations

                    Button {
                        text: modelData.freq.toFixed(1) + " MHz"
                        fontSize: Style.font.caption
                        horizontalPadding: 10
                        verticalPadding: 4
                        onClicked: {
                            root.freqText = String(modelData.freq);
                            root.doPlay(modelData.freq);
                        }
                    }

                }

            }

            Text {
                Layout.fillWidth: true
                visible: root.stations.length > 0 && root.band === "fm"
                text: "Scan hits — click one to tune"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 2
                color: Qt.darker(Color.foreground, 1.5)
            }

            ListView {
                id: channelList

                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                cacheBuffer: 200
                boundsBehavior: Flickable.StopAtBounds
                maximumFlickVelocity: 3500
                reuseItems: true
                model: channelModel

                Text {
                    anchors.centerIn: parent
                    visible: channelModel.count === 0
                    text: {
                        if (root.busy) return root.busyLabel;
                        if (root.band === "tv") return "No DVB-T channels saved — type a frequency (e.g. 474) and Play";
                        return "No channels yet — Scan the FM band or type a frequency and Save";
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.5)
                }

                delegate: RowLayout {
                    width: channelList.width
                    spacing: 6

                    Button {
                        Layout.fillWidth: true
                        text: model.name + "   •   " + Number(model.freq).toFixed(1) + " MHz"
                        leftAlign: true
                        fontSize: Style.font.caption
                        enabled: !root.busy
                        onClicked: {
                            root.freqText = String(model.freq);
                            root.doPlay(model.freq);
                        }
                    }

                    Button {
                        text: "✕"
                        tooltipText: "Remove channel"
                        fontSize: Style.font.caption - 2
                        horizontalPadding: 8
                        verticalPadding: 4
                        enabled: !root.busy
                        onClicked: root.removeChannel(model.freq)
                    }

                }

            }

            PanelSeparator {
                Layout.fillWidth: true
                opacity: 0.5
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Layout.bottomMargin: 2

                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.playing ? "On air — mpv window is your player; Stop here ends the stream" : "Bridge: ~/.cache/salted.TV/salted-tv-bridge.py • SoapySDR → rx-tools → mpv"
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption - 2
                    color: Qt.darker(Color.foreground, 1.4)
                }

            }

        }

    }

}
