// Bar button + popout: search Navidrome, start playback (song, album, or an
// artist's similar-music mix) through a local mpv instance this plugin owns,
// then control it. Structure follows the sibling ky.navidrome-remote plugin,
// the working reference for this machine's bar-widget contract.
//
// Keyboard model matches every other Omarchy panel (see network/bluetooth):
// Up/Down/j/k move a cursor through one flat list of rows, Left/Right/h/l
// move a sub-cursor within a row that has more than one action (an artist's
// Mix/All-albums chips, or the transport button strip), Enter/Space activate
// whatever the cursor is on, and Tab switches to the next/previous bar
// widget's panel entirely -- it never moves the cursor in-panel, matching
// the system-wide convention. Mouse hover and the keyboard cursor share the
// same state, so switching input methods mid-session never leaves two
// different rows looking highlighted.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "nbare.navidrome-play"
  ipcTarget: "nbare.navidrome-play"
  manageIpc: false

  // Always visible: unlike ky.navidrome-remote (a status display that hides
  // when there's nothing to show), this is an action launcher -- the icon is
  // how you get to the search box in the first place.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color background: Color.bar.background
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  NavidromePlayService {
    id: svc
    statusRefreshSec: root.setting("statusRefreshSec", 2)
    mixCount: root.setting("mixCount", 40)
  }

  function fmtTime(sec) {
    if (!sec || sec < 0) sec = 0
    var m = Math.floor(sec / 60), x = Math.floor(sec % 60)
    return m + ":" + (x < 10 ? "0" : "") + x
  }

  // ---- keyboard/mouse cursor model ----------------------------------------
  //
  // "results" is one flat list covering whichever of (recently played) or
  // (artists, then albums, then songs) is currently on screen -- exactly the
  // order they're rendered in below. "buttons" is the now-playing transport
  // strip (star, previous, play/pause, next, stop), reached by going past
  // the last result row.
  property bool cursorActive: false
  property string focusSection: "results"   // "results" | "buttons"
  property int selectedIndex: 0             // index into navRows
  property int chipIndex: 0                 // artist rows only: 0=Mix, 1=All albums
  property int buttonIndex: 0               // 0..4: star, previous, play/pause, next, stop
  readonly property var buttonNames: ["star", "previous", "playpause", "next", "stop"]

  readonly property bool showingRecent: searchField.text.trim() === ""
  readonly property var navRows: {
    var rows = []
    if (showingRecent) {
      for (var i = 0; i < svc.recentAlbums.length; i++) rows.push({kind: "album", data: svc.recentAlbums[i]})
    } else {
      for (var a = 0; a < svc.artists.length; a++) rows.push({kind: "artist", data: svc.artists[a]})
      for (var b = 0; b < svc.albums.length; b++) rows.push({kind: "album", data: svc.albums[b]})
      for (var c = 0; c < svc.songs.length; c++) rows.push({kind: "song", data: svc.songs[c]})
    }
    return rows
  }
  readonly property int albumsOffset: showingRecent ? 0 : svc.artists.length
  readonly property int songsOffset: showingRecent ? 0 : svc.artists.length + svc.albums.length

  onNavRowsChanged: {
    if (selectedIndex >= navRows.length) selectedIndex = Math.max(0, navRows.length - 1)
  }

  function rowHasCursor(flatIndex) {
    return cursorActive && focusSection === "results" && selectedIndex === flatIndex
  }
  function chipHasCursor(flatIndex, chip) {
    return rowHasCursor(flatIndex) && chipIndex === chip
  }
  function buttonHasCursor(n) {
    return cursorActive && focusSection === "buttons" && buttonIndex === n
  }

  // Mouse hover writes into the same state keyboard navigation reads, so the
  // two input methods can never disagree about which row is highlighted.
  function setResultCursor(flatIndex) {
    cursorActive = true
    focusSection = "results"
    selectedIndex = flatIndex
  }
  function setChipCursor(flatIndex, chip) {
    setResultCursor(flatIndex)
    chipIndex = chip
  }
  function setButtonCursor(n) {
    cursorActive = true
    focusSection = "buttons"
    buttonIndex = n
  }

  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "results") {
      if (delta > 0) {
        if (selectedIndex < navRows.length - 1) { selectedIndex += 1; chipIndex = 0; return }
        if (svc.loaded) { focusSection = "buttons"; buttonIndex = 0 }
        return
      }
      if (selectedIndex > 0) { selectedIndex -= 1; chipIndex = 0; return }
      // Top of the list: hand focus back to the search field.
      cursorActive = false
      searchField.forceActiveFocus()
      return
    }
    // focusSection === "buttons"
    if (delta < 0) {
      focusSection = "results"
      selectedIndex = Math.max(0, navRows.length - 1)
      chipIndex = 0
    }
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "results") {
      var row = navRows[selectedIndex]
      if (row && row.kind === "artist") chipIndex = delta > 0 ? 1 : 0
      return
    }
    buttonIndex = Math.max(0, Math.min(buttonNames.length - 1, buttonIndex + delta))
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "results") {
      var row = navRows[selectedIndex]
      if (!row) return
      if (row.kind === "artist") svc.play(chipIndex === 1 ? "artist" : "mix", row.data.id)
      else svc.play(row.kind, row.data.id)
      return
    }
    var action = buttonNames[buttonIndex]
    if (action === "star") svc.toggleStar(svc.track.id, !!svc.track.starred)
    else svc.control(action)
  }

  onOpenedChanged: {
    if (opened) {
      svc.loadRecent()
      cursorActive = false
      focusSection = "results"
      selectedIndex = 0
      chipIndex = 0
      buttonIndex = 0
      Qt.callLater(function() {
        if (root.opened) searchField.forceActiveFocus()
      })
    } else {
      searchField.text = ""
      svc.search("")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "♪"  // eighth note -- plain Unicode, not a Nerd Font glyph
    dimmed: !svc.loaded
    tooltipText: svc.loaded
      ? (svc.track.title || "") + (svc.track.artist ? " — " + svc.track.artist : "")
      : "Navidrome Play — search & play music"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) svc.refreshStatus()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns input while it has focus; Down below hands
      // navigation back to us.
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "Navidrome Play"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Search artists, albums, songs…"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (searchField.text !== "") { searchField.text = "" }
                else root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                if (root.navRows.length > 0) {
                  root.setResultCursor(0)
                  keyCatcher.forceActiveFocus()
                }
                event.accepted = true
              }
            }
            onTextChanged: searchDebounce.restart()
          }

          Timer {
            id: searchDebounce
            interval: 350
            onTriggered: svc.search(searchField.text.trim())
          }

          Text {
            Layout.fillWidth: true
            visible: svc.searchError !== ""
            text: "Search failed — " + svc.searchError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: svc.actionError !== ""
            text: "Command failed — " + svc.actionError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: searchField.text.trim() !== "" && !svc.searching && svc.searchError === ""
                     && svc.artists.length === 0 && svc.albums.length === 0 && svc.songs.length === 0
            text: "No matches."
            color: root.dim
            font.family: root.fontFamily
          }

          // ---- recently played: the default view before you type anything ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.recentAlbums.length > 0
            spacing: Style.space(2)

            PanelSectionHeader { text: "Recently Played" }

            Repeater {
              model: svc.recentAlbums
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.name
                subtitle: modelData.artist
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(index)
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("album", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(index) }
              }
            }
          }

          // ---- artists: two actions each -- mix, or the whole discography ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: svc.artists.length > 0
            spacing: Style.space(2)

            PanelSectionHeader { text: "Artists" }

            Repeater {
              model: svc.artists
              delegate: Rectangle {
                id: artistRow
                required property var modelData
                required property int index
                readonly property bool rowBusy: svc.busy === "play/" + modelData.id
                readonly property bool cursorOnRow: root.rowHasCursor(index)
                Layout.fillWidth: true
                height: artistContent.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: cursorOnRow ? 1 : 0
                border.color: Util.alpha(root.foreground, 0.25)

                RowLayout {
                  id: artistContent
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
                      text: artistRow.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      text: artistRow.modelData.albumCount + (artistRow.modelData.albumCount === 1 ? " album" : " albums")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    visible: artistRow.rowBusy
                    text: "working…"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  RowLayout {
                    visible: !artistRow.rowBusy
                    spacing: Style.space(4)

                    ActionChip {
                      label: "Mix"
                      foreground: root.foreground
                      dim: root.dim
                      fontFamily: root.fontFamily
                      hasCursor: root.chipHasCursor(artistRow.index, 0)
                      onClicked: svc.play("mix", artistRow.modelData.id)
                      onHovered: function(isHovered) { if (isHovered) root.setChipCursor(artistRow.index, 0) }
                    }
                    ActionChip {
                      label: "All albums"
                      foreground: root.foreground
                      dim: root.dim
                      fontFamily: root.fontFamily
                      hasCursor: root.chipHasCursor(artistRow.index, 1)
                      onClicked: svc.play("artist", artistRow.modelData.id)
                      onHovered: function(isHovered) { if (isHovered) root.setChipCursor(artistRow.index, 1) }
                    }
                  }
                }
              }
            }
          }

          // ---- albums: play the whole album in track order ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: svc.albums.length > 0
            spacing: Style.space(2)

            PanelSectionHeader { text: "Albums" }

            Repeater {
              model: svc.albums
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.name
                subtitle: modelData.artist
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(root.albumsOffset + index)
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("album", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.albumsOffset + index) }
              }
            }
          }

          // ---- songs: play just this one track ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: svc.songs.length > 0
            spacing: Style.space(2)

            PanelSectionHeader { text: "Songs" }

            Repeater {
              model: svc.songs
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.title
                subtitle: modelData.artist + (modelData.album ? " · " + modelData.album : "")
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(root.songsOffset + index)
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("song", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.songsOffset + index) }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- now playing ----
          Text {
            Layout.fillWidth: true
            visible: !svc.loaded
            text: "Nothing playing. Search above and pick something to start it."
            color: root.dim
            font.family: root.fontFamily
            wrapMode: Text.WordWrap
          }

          ColumnLayout {
            Layout.fillWidth: true
            visible: svc.loaded
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Image {
                visible: !!svc.track.cover
                source: svc.track.cover ? "file://" + svc.track.cover : ""
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Style.space(64)
                Layout.preferredHeight: Style.space(64)
                sourceSize.width: Style.space(128)
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  Layout.fillWidth: true
                  text: svc.track.title || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: !!svc.track.artist
                  text: svc.track.artist + (svc.track.album ? " · " + svc.track.album : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: svc.queueCount > 1
                  text: "Track " + (svc.queuePos + 1) + " of " + svc.queueCount
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              height: Style.space(4)
              radius: height / 2
              color: Qt.darker(root.foreground, 3.0)
              Rectangle {
                height: parent.height
                radius: parent.radius
                color: svc.paused ? root.dim : root.accent
                width: svc.duration > 0
                       ? parent.width * Math.min(1, svc.livePos() / svc.duration)
                       : 0
                Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                text: root.fmtTime(svc.livePos()) + " / " + root.fmtTime(svc.duration)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Item { Layout.fillWidth: true }

              PanelActionButton {
                iconText: svc.track.starred ? "󰋑" : "󰋕"
                tooltipText: svc.track.starred ? "Remove from favourites" : "Add to favourites"
                foreground: svc.track.starred ? root.urgent : root.dim
                hoverColor: root.urgent
                hasCursor: root.buttonHasCursor(0)
                enabled: svc.busy === "" && !!svc.track.id
                onClicked: svc.toggleStar(svc.track.id, !!svc.track.starred)
                onHovered: function(isHovered) { if (isHovered) root.setButtonCursor(0) }
              }
              PanelActionButton {
                iconText: "󰒮"
                tooltipText: "Previous"
                foreground: root.dim
                hoverColor: root.accent
                hasCursor: root.buttonHasCursor(1)
                enabled: svc.busy === ""
                onClicked: svc.control("previous")
                onHovered: function(isHovered) { if (isHovered) root.setButtonCursor(1) }
              }
              PanelActionButton {
                iconText: svc.paused ? "󰐊" : "󰏤"
                tooltipText: svc.paused ? "Play" : "Pause"
                foreground: root.foreground
                hoverColor: root.accent
                hasCursor: root.buttonHasCursor(2)
                enabled: svc.busy === ""
                onClicked: svc.control("playpause")
                onHovered: function(isHovered) { if (isHovered) root.setButtonCursor(2) }
              }
              PanelActionButton {
                iconText: "󰒭"
                tooltipText: "Next"
                foreground: root.dim
                hoverColor: root.accent
                hasCursor: root.buttonHasCursor(3)
                enabled: svc.busy === ""
                onClicked: svc.control("next")
                onHovered: function(isHovered) { if (isHovered) root.setButtonCursor(3) }
              }
              PanelActionButton {
                iconText: "󰓛"
                tooltipText: "Stop"
                foreground: root.dim
                hoverColor: root.urgent
                hasCursor: root.buttonHasCursor(4)
                enabled: svc.busy === ""
                onClicked: svc.control("stop")
                onHovered: function(isHovered) { if (isHovered) root.setButtonCursor(4) }
              }
            }
          }
        }
      }
    }
  }
}
