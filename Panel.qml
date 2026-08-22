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
    readonly property string bridge: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/salted.tv/salted-tv-bridge.py"

    property string sourceCode: ""
    property string loadedLabel: ""
    property string searchText: ""
    property bool viewingFavorites: false
    property var countries: []
    property var sources: []
    property var favMap: ({})
    property string selName: ""
    property string selUrl: ""
    property bool busy: false
    property string busyLabel: ""
    property string statusText: "IPTV — favorites shown by default; pick a source or paste a playlist URL"
    property bool playing: false
    property int loadGen: 0
    property int statusGen: 0

    property var pending: []
    property var cbChain: null

    moduleName: "salted.tv"
    implicitWidth: 640
    implicitHeight: 470

    Process {
        id: bridgeProc

        property string collected: ""

        onExited: function(code, status) {
            console.log("[salted.tv] bridge exited code=" + code + " bytes=" + bridgeProc.collected.length);
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
                if (bridgeProc.collected.length < 33554432)
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

    Timer {
        id: searchTimer

        interval: 380
        repeat: false
        onTriggered: if (root.sourceCode || root.viewingFavorites) root.loadChannels()
    }

    ListModel {
        id: channelModel
    }

    function request(cmd, params, cb) {
        params = params || {
        };
        if (bridgeProc.running) {
            if (cmd === "status") {
                for (var i = 0; i < root.pending.length; i++)
                    if (root.pending[i].cmd === "status")
                        return ;
            }
            if (root.pending.length >= 16)
                return ;
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
        console.log("[salted.tv] _start " + cmd);
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

    function sanitize(s) {
        var t = String(s === undefined || s === null ? "" : s);
        var prev = "";
        for (var i = 0; i < 4 && t !== prev; i++) {
            prev = t;
            t = t.replace(/&#(\d+);/g, function(m, d) {
                return String.fromCodePoint(parseInt(d, 10));
            });
            t = t.replace(/&#x([0-9a-fA-F]+);/g, function(m, h) {
                return String.fromCodePoint(parseInt(h, 16));
            });
            t = t.replace(/&quot;/g, '"').replace(/&apos;/g, "'")
                 .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
                 .replace(/&amp;/g, "&");
            t = t.replace(/<[^>]*>/g, " ");
        }
        return t.replace(/\s+/g, " ").trim();
    }

    function applyChannels(resp) {
        channelModel.clear();
        var lst = (resp && resp.channels) ? resp.channels : [];
        for (var i = 0; i < lst.length; i++)
            channelModel.append({
                "name": sanitize(lst[i].name) || "Unnamed",
                "group": sanitize(lst[i].group),
                "url": String(lst[i].url || "")
            });
        if (resp && resp.country)
            root.loadedLabel = resp.country;
    }

    function loadFavorites() {
        request("channels", {
            "source": "favorites"
        }, function(resp) {
            var map = {
            };
            if (resp && resp.ok)
                for (var i = 0; i < resp.channels.length; i++)
                    map[resp.channels[i].url] = true;
            root.favMap = map;
        });
    }

    function loadChannels() {
        var src = root.viewingFavorites ? "favorites" : root.sourceCode.trim();
        var dbg = src.lastIndexOf("url:", 0) === 0 ? "url:<redacted>" : src;
        console.log("[salted.tv] loadChannels src=" + dbg + " q=" + root.searchText);
        if (!src) {
            statusText = "Pick a country first";
            return ;
        }
        var gen = ++root.loadGen;
        setBusy("Loading " + src + " …");
        request("channels", {
            "source": src,
            "q": root.searchText.trim()
        }, function(resp) {
            if (gen !== root.loadGen)
                return ;

            setBusy("");
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Load failed";
                return ;
            }
            applyChannels(resp);
            var scope = resp.total !== resp.count ? " • filtered " + resp.count + " of " + resp.total : " • " + resp.count + " channels";
            statusText = resp.country + scope;
            rememberSource(root.viewingFavorites ? "favorites" : root.sourceCode);
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

    function playChannel(idx) {
        if (idx < 0 || idx >= channelModel.count)
            return ;
        var ch = channelModel.get(idx);
        if (!ch.url)
            return ;
        root.selName = ch.name;
        root.selUrl = ch.url;
        setBusy("Opening " + ch.name + " …");
        request("play", {
            "url": ch.url,
            "name": ch.name
        }, function(resp) {
            setBusy("");
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Play failed";
                return ;
            }
            root.playing = true;
            statusText = "Playing " + ch.name + " in mpv";
        });
    }

    function stopPlayback() {
        request("stop", {}, function(resp) {
            root.playing = false;
            statusText = (resp && resp.ok) ? "Stopped" : "Stop failed";
        });
    }

    function isFav(url) {
        return root.favMap[url] === true;
    }

    function toggleFav(idx) {
        if (idx < 0 || idx >= channelModel.count)
            return ;
        var ch = channelModel.get(idx);
        var wasFav = isFav(ch.url);
        var cmd = wasFav ? "remove" : "add";
        request(cmd, {
            "url": ch.url,
            "name": ch.name
        }, function(resp) {
            if (!resp || !resp.ok)
                return ;
            var map = Object.assign({
            }, root.favMap);
            if (wasFav)
                delete map[ch.url];
            else
                map[ch.url] = true;
            root.favMap = map;
            statusText = (wasFav ? "Removed " : "Saved ") + ch.name + (wasFav ? "" : " to favorites");
            if (root.viewingFavorites && wasFav)
                loadChannels();
        });
    }

    function loadSources() {
        request("sources", {}, function(resp) {
            var opts = (resp && resp.ok) ? (resp.sources || []) : [];
            request("urls", {}, function(u) {
                if (u && u.ok && u.urls) {
                    for (var i = 0; i < u.urls.length; i++) {
                        opts.push({
                            "value": "url:" + u.urls[i].url,
                            "label": "⏵ " + sanitize(u.urls[i].name || u.urls[i].url)
                        });
                    }
                }
                root.sources = opts;
                defaultToFavorites();
            });
        });
    }

    function defaultToFavorites() {
        if (root.sourceCode || root.viewingFavorites)
            return ;
        request("state", {}, function(s) {
            var last = (s && s.ok && s.state) ? String(s.state.lastSource || "") : "";
            if (!root.sourceCode && !root.viewingFavorites) {
                if (last && last !== "favorites") {
                    root.sourceCode = last;
                    root.viewingFavorites = false;
                    countryDropdown.value = last;
                } else {
                    root.viewingFavorites = true;
                    countryDropdown.value = "favorites";
                }
                loadChannels();
            }
        });
    }

    function rememberSource(src) {
        request("state", {"source": src}, function() {
        });
    }

    function loadCustom(urlSource) {
        var gen = ++root.loadGen;
        setBusy("Loading custom playlist …");
        request("channels", {
            "source": urlSource,
            "q": ""
        }, function(resp) {
            if (gen !== root.loadGen)
                return ;

            setBusy("");
            if (!resp || !resp.ok) {
                statusText = (resp && resp.error) ? resp.error : "Load failed";
                return ;
            }
            applyChannels(resp);
            statusText = resp.country + " • " + resp.count + " channels";
            root.viewingFavorites = false;
            root.sourceCode = urlSource;
            countryDropdown.value = urlSource;
            rememberSource(urlSource);
            loadSources();
        });
    }

    function refreshCurrent() {
        defaultToFavorites();
        loadFavorites();
        loadChannels();
        pollStatus();
    }

    function openFromHotkey() {
        refreshCurrent();
        root.controller.show();
    }

    function close() {
        root.controller.hide();
    }

    function toggle() {
        if (root.opened)
            close();
        else
            openFromHotkey();
    }

    function closeForPopoutSwitch() {
        close();
    }

    Component.onCompleted: {
        loadFavorites();
        loadSources();
        pollStatus();
    }

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
                            text: "salted.tv"
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
                            text: root.loadedLabel ? "IPTV • " + root.loadedLabel : "IPTV"
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
                                text: root.busy ? root.busyLabel : "Playing"
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

                SearchableDropdown {
                    id: countryDropdown

                    Layout.preferredWidth: 240
                    label: ""
                    showLabel: false
                    placeholderText: "Source — ★ Favorites or paste a URL below"
                    options: root.sources
                    onChanged: function(value) {
                        root.viewingFavorites = value === "favorites";
                        if (!root.viewingFavorites)
                            root.sourceCode = value;
                        root.searchText = "";
                        searchField.text = "";
                        root.loadChannels();
                    }
                }

                TextField {
                    id: searchField

                    Layout.fillWidth: true
                    placeholderText: "Filter channels …"
                    onTextChanged: {
                        root.searchText = text;
                        searchTimer.restart();
                    }
                    Keys.onEscapePressed: if (hasFocus) root.close()
                }

                Button {
                    text: root.playing ? "■ Stop" : "▶ Play"
                    selected: true
                    enabled: !root.busy && (root.playing || root.selUrl !== "")
                    onClicked: root.playing ? root.stopPlayback() : root.playChannel(channelModel.count > 0 ? 0 : -1)
                }

            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "\uf0c1"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Qt.darker(Color.foreground, 1.35)
                }

                TextField {
                    id: customUrlField

                    Layout.fillWidth: true
                    placeholderText: "…or paste any M3U playlist URL (http…) and load it"
                    Keys.onEscapePressed: if (hasFocus) clear()
                }

                Button {
                    text: "Load URL"
                    enabled: !root.busy && customUrlField.text.trim() !== ""
                    onClicked: {
                        var u = "url:" + customUrlField.text.trim();
                        root.viewingFavorites = false;
                        root.sourceCode = "";
                        countryDropdown.value = "";
                        root.loadCustom(u);
                    }
                }

            }

            ListView {
                id: channelList

                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                cacheBuffer: 300
                boundsBehavior: Flickable.StopAtBounds
                maximumFlickVelocity: 3500
                reuseItems: true
                model: channelModel

                ScrollBar.vertical: ScrollBar {
                }

                Text {
                    anchors.centerIn: parent
                    visible: channelModel.count === 0 && !root.busy
                    text: {
                        if (root.viewingFavorites) return "No favorites yet — tap ☆ next to any channel";
                        return "Pick a country above and the channel list appears here";
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.5)
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.busy
                    text: root.busyLabel
                    textFormat: Text.PlainText
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Color.accent
                }

                delegate: RowLayout {
                    width: channelList.width
                    spacing: 6

                    Button {
                        Layout.fillWidth: true
                        text: model.name + (model.group ? "   •   " + model.group : "")
                        leftAlign: true
                        fontSize: Style.font.caption
                        selected: model.url === root.selUrl
                        enabled: !root.busy
                        onClicked: root.playChannel(index)
                    }

                    Button {
                        text: root.isFav(model.url) ? "★" : "☆"
                        tooltipText: root.isFav(model.url) ? "Remove from favorites" : "Save to favorites"
                        fontSize: Style.font.caption
                        horizontalPadding: 8
                        verticalPadding: 4
                        enabled: !root.busy
                        onClicked: root.toggleFav(index)
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
                    text: "Streams by iptv-org • click a channel to play • ★ saves it"
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption - 2
                    color: Qt.darker(Color.foreground, 1.4)
                }

            }

        }

    }

}
