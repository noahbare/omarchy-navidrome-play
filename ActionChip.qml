// Small labeled pill button. Used where a row needs more than one action
// (an artist's "Mix" vs "All albums"), so a single whole-row click can't
// disambiguate which one the user meant.
import QtQuick
import qs.Commons

Rectangle {
  id: chip
  property string label: ""
  property color foreground
  property color dim
  property string fontFamily
  signal clicked()

  implicitWidth: chipText.implicitWidth + Style.space(14)
  implicitHeight: chipText.implicitHeight + Style.space(6)
  radius: height / 2
  color: chipMouse.containsMouse ? Util.alpha(foreground, 0.14) : Util.alpha(foreground, 0.07)

  Text {
    id: chipText
    anchors.centerIn: parent
    text: chip.label
    color: chipMouse.containsMouse ? chip.foreground : chip.dim
    font.family: chip.fontFamily
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: chipMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.clicked()
  }
}
