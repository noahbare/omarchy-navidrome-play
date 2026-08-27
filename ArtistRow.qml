// Artist row with two actions: start the similar-artist mix, or queue every
// song across every album. Reused by the live "Artists" search section and
// the Recent Artists / Favorite Artists home sections -- each of those has
// a different idea of what the subtitle should say (album count vs. "seen
// in N recent albums" vs. "N favourite songs"), so it's a plain string
// rather than something this component derives itself.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Rectangle {
  id: artistRow
  property string name: ""
  property string subtitle: ""
  property bool busy: false
  property bool cursorOnRow: false
  property int chipCursor: -1     // 0 = Mix has the cursor, 1 = All albums, -1 = neither
  property color foreground
  property color dim
  property string fontFamily
  signal mixActivated()
  signal allAlbumsActivated()
  signal rowHovered(bool isHovered)
  signal chipHovered(int chip, bool isHovered)

  Layout.fillWidth: true
  height: content.implicitHeight + Style.space(10)
  radius: Style.cornerRadius
  color: "transparent"
  border.width: cursorOnRow ? 1 : 0
  border.color: Util.alpha(foreground, 0.25)

  RowLayout {
    id: content
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
        text: artistRow.name
        color: artistRow.foreground
        font.family: artistRow.fontFamily
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        visible: artistRow.subtitle !== ""
        text: artistRow.subtitle
        color: artistRow.dim
        font.family: artistRow.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      visible: artistRow.busy
      text: "working…"
      color: artistRow.dim
      font.family: artistRow.fontFamily
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      visible: !artistRow.busy
      spacing: Style.space(4)

      ActionChip {
        label: "Mix"
        foreground: artistRow.foreground
        dim: artistRow.dim
        fontFamily: artistRow.fontFamily
        hasCursor: artistRow.chipCursor === 0
        onClicked: artistRow.mixActivated()
        onHovered: function(isHovered) { if (isHovered) artistRow.chipHovered(0, true) }
      }
      ActionChip {
        label: "All albums"
        foreground: artistRow.foreground
        dim: artistRow.dim
        fontFamily: artistRow.fontFamily
        hasCursor: artistRow.chipCursor === 1
        onClicked: artistRow.allAlbumsActivated()
        onHovered: function(isHovered) { if (isHovered) artistRow.chipHovered(1, true) }
      }
    }
  }
}
