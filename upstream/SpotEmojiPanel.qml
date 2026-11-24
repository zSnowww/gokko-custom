import QtQuick
import "EmojiData.js" as EmojiData
import "I18n.js" as I18n
import "." as MacParts

Item {
    id: emojiPanel
    required property var host
    required property var pal
    required property var glassSrc
    required property color accent
    required property color borderColor
    required property bool dark
    required property string emojiFont
    required property bool clipAutoPaste
    property alias queryInput: emojiInput
    property int sel: 0
    property int cat: 0
    property string query: ""
    readonly property int cols: 12
    readonly property int cell: 54
    readonly property int gridRows: 6
    readonly property var items: {
        var L = EmojiData.list, out = [], i;
        var q = (query || "").trim().toLowerCase();
        if (q !== "") {
            var hits = [];
            for (i = 0; i < L.length; i++) {
                var p = L[i][4].indexOf(q);
                if (p < 0) continue;
                var nm = L[i][1].toLowerCase();
                hits.push([nm === q ? 0 : (nm.indexOf(q) === 0 ? 1 : ((" " + L[i][2] + " ").indexOf(" " + q + " ") >= 0 ? 2 : 3)), i]);
            }
            hits.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
            for (i = 0; i < hits.length && i < 240; i++) out.push(L[hits[i][1]]);
            return out;
        }
        if (cat === 0) {
            var idx = {}, j;
            for (i = 0; i < L.length; i++) idx[L[i][0]] = L[i];
            var rec = host.emojiRecent || [];
            for (j = 0; j < rec.length; j++) if (idx[rec[j]]) out.push(idx[rec[j]]);
            return out;
        }
        for (i = 0; i < L.length; i++) if (L[i][3] === cat - 1) out.push(L[i]);
        return out;
    }
    readonly property var cur: items.length > 0 ? items[Math.min(sel, items.length - 1)] : null

    height: 64 + 42 + gridRows * cell + 46

    function moveKey(ev) {
        var k = ev.key, n = items.length;
        if (k === Qt.Key_Escape) { host.handleEscape(); ev.accepted = true; }
        else if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down) {
            var d = k === Qt.Key_Left ? -1 : (k === Qt.Key_Right ? 1 : (k === Qt.Key_Up ? -cols : cols));
            if (n > 0) sel = Math.max(0, Math.min(n - 1, Math.min(sel, n - 1) + d));
            ev.accepted = true;
        } else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            if (query.trim() === "") { cat = (cat + (k === Qt.Key_Tab ? 1 : 9)) % 10; sel = 0; }
            ev.accepted = true;
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (cur) host.pickEmoji(cur);
            ev.accepted = true;
        }
    }

    Item {
        x: 20; width: parent.width - 40; height: 64
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 34; height: 34; radius: 10; color: emojiPanel.accent
            MacParts.MacGlyph { anchors.centerIn: parent; width: 20; height: 20; kind: "smile"; color: "white" }
        }
        Text {
            id: emojiLbl
            x: 46; anchors.verticalCenter: parent.verticalCenter
            text: I18n.tr("Emoji"); color: emojiPanel.pal.fg
            font.family: emojiPanel.pal.fam; font.pixelSize: 24; font.weight: Font.Medium
        }
        TextInput {
            id: emojiInput
            x: emojiLbl.x + emojiLbl.width + 14
            width: parent.width - x
            anchors.verticalCenter: parent.verticalCenter
            clip: true; color: emojiPanel.pal.fg
            selectionColor: emojiPanel.accent; selectedTextColor: "white"
            font.family: emojiPanel.pal.fam; font.pixelSize: 24
            onTextChanged: { emojiPanel.query = text; emojiPanel.sel = 0; }
            Keys.onPressed: event => emojiPanel.moveKey(event)
        }
    }

    Row {
        x: 20; y: 64
        opacity: emojiPanel.query.trim() === "" ? 1 : 0.35
        Repeater {
            model: ["\uD83D\uDD58", "\uD83D\uDE00", "\uD83E\uDDD1", "\uD83D\uDC3B", "\uD83C\uDF54", "\u2708\uFE0F", "\u26BD", "\uD83D\uDCA1", "\uD83D\uDD23", "\uD83C\uDFF3\uFE0F"]
            delegate: Item {
                id: tab
                required property string modelData
                required property int index
                width: 68; height: 36
                Rectangle {
                    anchors.centerIn: parent; width: 48; height: 32; radius: 12; color: emojiPanel.accent
                    opacity: (emojiPanel.cat === tab.index && emojiPanel.query.trim() === "") ? 0.9 : (tabMa.containsMouse ? 0.25 : 0)
                }
                Text { anchors.centerIn: parent; text: tab.modelData; font.family: emojiPanel.emojiFont; font.pixelSize: 22 }
                MouseArea {
                    id: tabMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: { emojiInput.text = ""; emojiPanel.cat = tab.index; emojiPanel.sel = 0; emojiInput.forceActiveFocus(); }
                }
            }
        }
    }

    GridView {
        id: emojiGrid
        x: Math.round((parent.width - width) / 2); y: 106
        width: emojiPanel.cols * emojiPanel.cell
        height: emojiPanel.gridRows * emojiPanel.cell
        cellWidth: emojiPanel.cell; cellHeight: emojiPanel.cell
        clip: true; boundsBehavior: Flickable.StopAtBounds
        model: emojiPanel.items
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)
        delegate: Item {
            id: ec
            required property var modelData
            required property int index
            readonly property bool sel: index === Math.min(emojiPanel.sel, emojiPanel.items.length - 1)
            width: emojiPanel.cell; height: emojiPanel.cell
            Rectangle {
                anchors.centerIn: parent; width: parent.width - 4; height: parent.height - 4; radius: 14
                color: emojiPanel.accent; opacity: ec.sel ? 1 : 0
            }
            Text { anchors.centerIn: parent; text: ec.modelData ? ec.modelData[0] : ""; font.family: emojiPanel.emojiFont; font.pixelSize: 34 }
            MouseArea {
                anchors.fill: parent; hoverEnabled: true
                onEntered: emojiPanel.sel = ec.index
                onClicked: emojiPanel.host.pickEmoji(ec.modelData)
            }
        }
    }

    Text {
        visible: emojiPanel.items.length === 0
        x: 20; y: 106; width: parent.width - 40; height: emojiPanel.gridRows * emojiPanel.cell
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: emojiPanel.query.trim() !== "" ? I18n.tr("No Results") : I18n.tr("No recently used emoji")
        color: emojiPanel.pal.fg2; font.family: emojiPanel.pal.fam; font.pixelSize: 14
    }

    Item {
        x: 20; y: parent.height - 46; width: parent.width - 40; height: 46
        Rectangle { width: parent.width; height: 1; color: emojiPanel.pal.sep }
        Text {
            anchors.verticalCenter: parent.verticalCenter; width: parent.width - 180; elide: Text.ElideRight
            text: emojiPanel.cur ? (emojiPanel.cur[0] + "  " + emojiPanel.cur[1]) : ""
            color: emojiPanel.pal.fg2; font.family: emojiPanel.pal.fam; font.pixelSize: 13
        }
        Text {
            anchors.right: parent.right; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
            text: emojiPanel.clipAutoPaste ? I18n.tr("Return to insert") : I18n.tr("Return to copy")
            color: emojiPanel.pal.fg3; font.family: emojiPanel.pal.fam; font.pixelSize: 12
        }
    }
}
