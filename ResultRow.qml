// Compact search-result row: clicking anywhere activates it. Shared by the
// artist/album/song sections in Panel.qml so each only states its label,
// subtitle, and what "activate" means for that kind.
//
// hasCursor mirrors the rest of this codebase's panel-cursor convention
// (see PanelActionButton, CursorSurface): mouse hover never paints its own
// highlight directly -- it reports itself via hovered() and the OWNER
// decides hasCursor, so keyboard and mouse can never disagree about which
// row is highlighted.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Rectangle {
  id: rowRoot
  property string title: ""
  property string subtitle: ""
  property bool busy: false
  property bool hasCursor: false
  property color foreground
  property color dim
  property string fontFamily
  signal activated()
  signal hovered(bool isHovered)

  readonly property bool _hot: rowRoot.hasCursor || rowMouse.containsMouse

  height: rowContent.implicitHeight + Style.space(10)
  radius: Style.cornerRadius
  color: _hot ? Util.alpha(foreground, 0.08) : "transparent"
  border.width: rowRoot.hasCursor ? 1 : 0
  border.color: Util.alpha(foreground, 0.35)

  RowLayout {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Text {
        Layout.fillWidth: true
        text: rowRoot.title
        textFormat: Text.PlainText  // server-controlled: never interpret as rich/HTML text
        color: rowRoot.foreground
        font.family: rowRoot.fontFamily
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        visible: rowRoot.subtitle !== ""
        text: rowRoot.subtitle
        textFormat: Text.PlainText  // server-controlled: never interpret as rich/HTML text
        color: rowRoot.dim
        font.family: rowRoot.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      visible: rowRoot.busy
      text: "working…"
      color: rowRoot.dim
      font.family: rowRoot.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      visible: !rowRoot.busy
      text: "▶"
      color: rowRoot._hot ? rowRoot.foreground : rowRoot.dim
      font.family: rowRoot.fontFamily
    }
  }

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    enabled: !rowRoot.busy
    onClicked: rowRoot.activated()
    onContainsMouseChanged: rowRoot.hovered(rowMouse.containsMouse)
  }
}
