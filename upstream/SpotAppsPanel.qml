import QtQuick
import "I18n.js" as I18n
import "Fonts.js" as Fonts
import "." as MacParts

Item {
    id: appsPanel
    required property var host
    required property var pal
    required property color accent
    property alias queryInput: appsInput
    property string query: ""
    property var expanded: ({})

    height: Math.min(64 + appsCol.height + 14, 520)

    function toggleSection(name) {
        var o = {};
        for (var k in expanded) o[k] = expanded[k];
        o[name] = !o[name];
        expanded = o;
    }

    Item {
        x: 24; width: parent.width - 48; height: 64
        MacParts.MacGlyph { anchors.verticalCenter: parent.verticalCenter; width: 24; height: 24; kind: "appstore"; color: appsPanel.pal.fg2 }
        Text {
            x: 43; anchors.verticalCenter: parent.verticalCenter
            visible: appsInput.text === ""
            text: I18n.tr("Applications")
            color: appsPanel.pal.fg3
            font.family: Fonts.forWeight(Font.Normal, appsPanel.pal.fam); font.pixelSize: 24
        }
        TextInput {
            id: appsInput
            x: 40; width: parent.width - 88; anchors.verticalCenter: parent.verticalCenter
            clip: true; color: appsPanel.pal.fg
            selectionColor: appsPanel.accent; selectedTextColor: "white"
            font.family: Fonts.forWeight(Font.Normal, appsPanel.pal.fam); font.pixelSize: 24
            onTextChanged: appsPanel.query = text
            Keys.onPressed: ev => {
                if (ev.key === Qt.Key_Escape) { appsPanel.host.handleEscape(); ev.accepted = true; }
                else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
                    var r = appsPanel.host.searchApps(appsPanel.query);
                    if (r.length > 0) appsPanel.host.launchAndClose(r[0]);
                    ev.accepted = true;
                }
            }
        }
        Rectangle {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            width: 34; height: 34; radius: 17
            color: backMa.containsMouse ? appsPanel.pal.hover : (appsPanel.pal.dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.08))
            MacParts.MacGlyph { anchors.centerIn: parent; width: 16; height: 16; kind: "dots"; color: appsPanel.pal.fg }
            MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; onClicked: appsPanel.host.setMode("home") }
        }
    }

    Flickable {
        id: appsFlick
        y: 64; width: parent.width; height: parent.height - 70
        contentWidth: width; contentHeight: appsCol.height + 8
        clip: true; boundsBehavior: Flickable.StopAtBounds

        Column {
            id: appsCol
            x: 24; width: appsFlick.width - 48
            Repeater {
                id: appsRep
                model: appsPanel.query.trim() === "" ? appsPanel.host.appSections : appsPanel.host.appSearchSection(appsPanel.query)
                delegate: Column {
                    id: sec
                    required property var modelData
                    readonly property bool searching: appsPanel.query.trim() !== ""
                    readonly property bool isExp: searching || appsPanel.expanded[modelData.name] === true
                    readonly property int shown: isExp ? modelData.apps.length : Math.min(5, modelData.apps.length)
                    width: appsCol.width
                    Rectangle { width: parent.width; height: 1; color: appsPanel.pal.sep }
                    Item {
                        width: parent.width; height: 38
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.tr(sec.modelData.name)
                            color: appsPanel.pal.fg
                            font.family: Fonts.forWeight(Font.Bold, appsPanel.pal.fam); font.pixelSize: 13; font.weight: Font.Bold
                        }
                        Text {
                            visible: !sec.searching && sec.modelData.apps.length > 5
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: sec.isExp ? I18n.tr("Show Less") : I18n.tr("Show More")
                            color: appsPanel.accent
                            font.family: Fonts.forWeight(Font.Bold, appsPanel.pal.fam); font.pixelSize: 12; font.weight: Font.Bold
                            MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: appsPanel.toggleSection(sec.modelData.name) }
                        }
                    }
                    Grid {
                        columns: 5
                        Repeater {
                            model: sec.shown
                            delegate: Item {
                                id: cell
                                required property int index
                                readonly property var e: sec.modelData.apps[index]
                                width: appsCol.width / 5; height: 96
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: 2; radius: 16
                                    color: cma.containsMouse ? appsPanel.pal.hover : "transparent"
                                }
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter; y: 10
                                    width: 56; height: 56
                                    source: appsPanel.host.iconSrc(cell.e.icon)
                                    sourceSize: Qt.size(128, 128)
                                    fillMode: Image.PreserveAspectFit; asynchronous: true; smooth: true
                                }
                                Text {
                                    y: 72; x: 4; width: parent.width - 8
                                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                    text: cell.e.name; color: appsPanel.pal.fg
                                    font.family: Fonts.forWeight(Font.Normal, appsPanel.pal.fam); font.pixelSize: 12
                                }
                                MouseArea {
                                    id: cma; anchors.fill: parent; hoverEnabled: true
                                    onClicked: appsPanel.host.launchAndClose(cell.e)
                                }
                            }
                        }
                    }
                    Item { width: 1; height: 10 }
                }
            }
            Text {
                visible: appsPanel.query.trim() !== "" && appsRep.count === 0
                width: parent.width; height: 90
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                text: I18n.tr("No Results"); color: appsPanel.pal.fg2
                font.family: Fonts.forWeight(Font.Normal, appsPanel.pal.fam); font.pixelSize: 14
            }
        }
    }
}
