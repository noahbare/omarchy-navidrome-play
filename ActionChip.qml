// Small labeled pill button. Used where a row needs more than one action
// (an artist's "Mix" vs "All albums"), so a single whole-row click can't
// disambiguate which one the user meant.
//
// hasCursor follows the same panel-cursor convention as ResultRow/
// PanelActionButton: hover reports itself via hovered(), the owner decides
// whether that becomes the highlighted state.
import QtQuick
import qs.Commons

Rectangle {
  id: chip
  property string label: ""
  property bool hasCursor: false
  property color foreground
  property color dim
  property string fontFamily
  signal clicked()
  signal hovered(bool isHovered)

  readonly property bool _hot: chip.hasCursor || chipMouse.containsMouse

  implicitWidth: chipText.implicitWidth + Style.space(14)
  implicitHeight: chipText.implicitHeight + Style.space(6)
  radius: height / 2
  color: _hot ? Util.alpha(foreground, 0.14) : Util.alpha(foreground, 0.07)
  border.width: chip.hasCursor ? 1 : 0
  border.color: Util.alpha(foreground, 0.4)

  Text {
    id: chipText
    anchors.centerIn: parent
    text: chip.label
    textFormat: Text.PlainText
    color: chip._hot ? chip.foreground : chip.dim
    font.family: chip.fontFamily
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: chipMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.clicked()
    onContainsMouseChanged: chip.hovered(chipMouse.containsMouse)
  }
}
