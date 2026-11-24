//@ pragma UseQApplication

import QtQuick
import Quickshell
import "upstream" as Gokko

// Lightweight standalone Spotlight launcher for Ryoku.
// Shares ~/.config/macbar/settings.json and precompiled shaders without loading MacBar.
Scope {
    id: root

    property bool openRequested: false
    property bool perfNoFocus: false
    property string monitor: ""
    property bool closing: false
    readonly property bool shown: root.openRequested || root.closing

    readonly property var hostScreen: {
        const list = Quickshell.screens;
        if (root.monitor) {
            for (const screen of list) {
                if (screen.name === root.monitor)
                    return screen;
            }
        }
        return Quickshell.primaryScreen ?? (list.length > 0 ? list[0] : null);
    }

    FontLoader { source: Qt.resolvedUrl("upstream/assets/fonts/OpenRunde-Regular.otf") }
    FontLoader { source: Qt.resolvedUrl("upstream/assets/fonts/OpenRunde-Semibold.otf") }

    Gokko.GokkoSpotlight {
        id: spotlight
        hostScreen: root.hostScreen
        perfNoFocus: root.perfNoFocus
        openRequested: root.openRequested
        onDismissed: root.dismissedBySurface()
        onOpenModeRequested: {
            root.closing = false;
            root.openRequested = true;
        }
    }

    function show(mon) {
        if (mon)
            root.monitor = mon;
        root.closing = false;
        root.openRequested = true;
    }

    function hide() {
        if (!root.openRequested && !root.closing)
            return;
        root.closing = true;
        root.openRequested = false;
    }

    function toggle(mon) {
        if (root.openRequested || root.closing)
            root.hide();
        else
            root.show(mon);
    }

    function stateDump() {
        return { open: root.openRequested, query: spotlight.spQuery };
    }
    function debugResults(q) {
        return spotlight.homeItems(q);
    }

    function dismissedBySurface() {
        if (!root.openRequested)
            return;
        root.closing = true;
        root.openRequested = false;
    }

    Timer {
        id: closeSettler
        interval: 260
        onTriggered: root.closing = false
    }

    onClosingChanged: {
        if (root.closing)
            closeSettler.restart();
        else
            closeSettler.stop();
    }
}
