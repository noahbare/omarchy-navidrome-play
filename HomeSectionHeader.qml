// Clickable, keyboard-activatable header for a collapsible home-screen
// section (Recently Played / Favorites / Playlists). Collapsed by default --
// these are discovery shortcuts, not something that should push the actual
// now-playing controls and search box off screen.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Rectangle {
  id: header
  property string label: ""
  property int count: 0
  property bool expanded: false
  property bool hasCursor: false
  property color foreground
  property color dim
  property string fontFamily
  signal toggled()
  signal hovered(bool isHovered)

  readonly property bool _hot: header.hasCursor || headerMouse.containsMouse

  Layout.fillWidth: true
  height: rowContent.implicitHeight + Style.space(8)
  radius: Style.cornerRadius
  color: _hot ? Util.alpha(foreground, 0.06) : "transparent"

  RowLayout {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(6)

    Text {
      text: header.expanded ? "▾" : "▸"
      color: header.dim
      font.family: header.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      text: header.label + (header.count > 0 ? " (" + header.count + ")" : "")
      textFormat: Text.PlainText
      color: header.dim
      font.family: header.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Item { Layout.fillWidth: true }
  }

  MouseArea {
    id: headerMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: header.toggled()
    onContainsMouseChanged: header.hovered(headerMouse.containsMouse)
  }
}
