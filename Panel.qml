// Bar button + popout: search Navidrome, start playback (song, album, an
// artist's similar-music mix, or a saved playlist) through a local mpv
// instance this plugin owns, then control it.
//
// Layout, top to bottom: title, now-playing (pinned here so you never have
// to scroll past search results to reach it), search box, then either the
// home screen (Recently Played / Favorites / Playlists, collapsed by
// default) or live search results.
//
// Keyboard model matches every other Omarchy panel (see network/bluetooth):
// Up/Down/j/k move a cursor through one flat list of rows, Left/Right/h/l
// move a sub-cursor within a row that has more than one action (an artist's
// Mix/All-albums chips, or the transport button strip), Enter/Space activate
// whatever the cursor is on (including expanding/collapsing a home section),
// and Tab switches to the next/previous bar widget's panel entirely -- it
// never moves the cursor in-panel, matching the system-wide convention.
// Mouse hover and the keyboard cursor share the same state, so switching
// input methods mid-session never leaves two different rows highlighted.
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

  // Always visible: this is an action launcher, not a status display -- the
  // icon is how you get to the search box in the first place.
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
  // "buttons" is the now-playing transport strip (star, previous, play/
  // pause, next, stop) -- present only while something is loaded, and first
  // in tab order since it's pinned at the top of the panel. "results" is one
  // flat list covering whichever of (Recently Played / Favorites /
  // Playlists, each with a toggle header) or (artists, then albums, then
  // songs) is currently on screen -- exactly the order they're rendered in
  // below.
  property bool cursorActive: false
  property string focusSection: "results"   // "results" | "buttons"
  property int selectedIndex: 0             // index into navRows
  property int chipIndex: 0                 // artist rows only: 0=Mix, 1=All albums
  property int buttonIndex: 0               // 0..4: star, previous, play/pause, next, stop
  readonly property var buttonNames: ["star", "previous", "playpause", "next", "stop"]
  readonly property var sectionOrder: svc.loaded ? ["buttons", "results"] : ["results"]

  property bool recentExpanded: false
  property bool recentArtistsExpanded: false
  property bool favoritesExpanded: false
  property bool favoriteArtistsExpanded: false
  property bool playlistsExpanded: false

  readonly property bool showingRecent: searchField.text.trim() === ""
  readonly property var navRows: {
    var rows = []
    if (showingRecent) {
      if (svc.recentAlbums.length > 0) {
        rows.push({kind: "header", section: "recent"})
        if (root.recentExpanded) for (var i = 0; i < svc.recentAlbums.length; i++)
          rows.push({kind: "album", data: svc.recentAlbums[i]})
      }
      if (svc.recentArtists.length > 0) {
        rows.push({kind: "header", section: "recentArtists"})
        if (root.recentArtistsExpanded) for (var ra = 0; ra < svc.recentArtists.length; ra++)
          rows.push({kind: "artist", data: svc.recentArtists[ra]})
      }
      if (svc.favoriteSongs.length > 0) {
        rows.push({kind: "header", section: "favorites"})
        if (root.favoritesExpanded) for (var f = 0; f < svc.favoriteSongs.length; f++)
          rows.push({kind: "song", data: svc.favoriteSongs[f]})
      }
      if (svc.favoriteArtists.length > 0) {
        rows.push({kind: "header", section: "favoriteArtists"})
        if (root.favoriteArtistsExpanded) for (var fa = 0; fa < svc.favoriteArtists.length; fa++)
          rows.push({kind: "artist", data: svc.favoriteArtists[fa]})
      }
      if (svc.playlists.length > 0) {
        rows.push({kind: "header", section: "playlists"})
        if (root.playlistsExpanded) for (var p = 0; p < svc.playlists.length; p++)
          rows.push({kind: "playlist", data: svc.playlists[p]})
      }
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

  // Flat-index lookups for the three collapsible home sections. Derived from
  // navRows itself (not hand-tracked running totals) so a header's position
  // can never drift out of sync with what's actually rendered as sections
  // are expanded/collapsed or come and go.
  function sectionHeaderIndex(section) {
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].kind === "header" && navRows[i].section === section) return i
    return -1
  }
  function sectionRowIndex(section, localIndex) {
    var h = sectionHeaderIndex(section)
    return h < 0 ? -1 : h + 1 + localIndex
  }

  function toggleSection(section) {
    if (section === "recent") recentExpanded = !recentExpanded
    else if (section === "recentArtists") recentArtistsExpanded = !recentArtistsExpanded
    else if (section === "favorites") favoritesExpanded = !favoritesExpanded
    else if (section === "favoriteArtists") favoriteArtistsExpanded = !favoriteArtistsExpanded
    else if (section === "playlists") playlistsExpanded = !playlistsExpanded
    // Keep the cursor pinned to this header regardless of how many rows
    // just appeared/disappeared above or below it in the flat list.
    Qt.callLater(function() {
      var idx = root.sectionHeaderIndex(section)
      if (idx >= 0) { root.cursorActive = true; root.focusSection = "results"; root.selectedIndex = idx }
    })
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

  function sectionLength(section) {
    return section === "buttons" ? buttonNames.length : navRows.length
  }

  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    var order = sectionOrder
    var sIdx = order.indexOf(focusSection)
    if (sIdx < 0) { focusSection = order[0]; sIdx = 0; selectedIndex = 0; buttonIndex = 0 }

    var idxProp = focusSection === "buttons" ? buttonIndex : selectedIndex
    var max = sectionLength(focusSection) - 1

    if (delta > 0) {
      if (idxProp < max) {
        if (focusSection === "buttons") buttonIndex += 1
        else { selectedIndex += 1; chipIndex = 0 }
        return
      }
      if (sIdx < order.length - 1) {
        focusSection = order[sIdx + 1]
        if (focusSection === "buttons") buttonIndex = 0
        else { selectedIndex = 0; chipIndex = 0 }
      }
      // else: already at the very bottom, stay put
      return
    }

    if (idxProp > 0) {
      if (focusSection === "buttons") buttonIndex -= 1
      else { selectedIndex -= 1; chipIndex = 0 }
      return
    }
    if (sIdx > 0) {
      focusSection = order[sIdx - 1]
      var newMax = sectionLength(focusSection) - 1
      if (focusSection === "buttons") buttonIndex = newMax
      else { selectedIndex = Math.max(0, newMax); chipIndex = 0 }
    } else {
      cursorActive = false
      searchField.forceActiveFocus()
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
      if (row.kind === "header") { toggleSection(row.section); return }
      if (row.kind === "artist") { svc.play(chipIndex === 1 ? "artist" : "mix", row.data.id); return }
      svc.play(row.kind, row.data.id)   // album, song, playlist
      return
    }
    var action = buttonNames[buttonIndex]
    if (action === "star") svc.toggleStar(svc.track.id, !!svc.track.starred)
    else svc.control(action)
  }

  onOpenedChanged: {
    if (opened) {
      svc.loadRecent()
      svc.loadFavorites()
      svc.loadPlaylists()
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

          // ---- now playing: pinned to the top ----
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
                  textFormat: Text.PlainText  // server-controlled: never interpret as rich/HTML text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: !!svc.track.artist
                  text: svc.track.artist + (svc.track.album ? " · " + svc.track.album : "")
                  textFormat: Text.PlainText  // server-controlled: never interpret as rich/HTML text
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

          PanelSeparator { Layout.fillWidth: true; visible: svc.loaded }

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
                var order = root.sectionOrder
                if (order.length > 0 && root.sectionLength(order[0]) > 0) {
                  root.cursorActive = true
                  root.focusSection = order[0]
                  if (order[0] === "buttons") root.buttonIndex = 0
                  else { root.selectedIndex = 0; root.chipIndex = 0 }
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
            textFormat: Text.PlainText  // may embed a server-supplied error message
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: svc.actionError !== ""
            text: "Command failed — " + svc.actionError
            textFormat: Text.PlainText  // may embed a server-supplied error message
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

          // ---- recently played: collapsed by default ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.recentAlbums.length > 0
            spacing: Style.space(2)

            HomeSectionHeader {
              label: "Recently Played"
              count: svc.recentAlbums.length
              expanded: root.recentExpanded
              hasCursor: root.rowHasCursor(root.sectionHeaderIndex("recent"))
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onToggled: root.toggleSection("recent")
              onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionHeaderIndex("recent")) }
            }

            Repeater {
              model: root.recentExpanded ? svc.recentAlbums : []
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.name
                subtitle: modelData.artist
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(root.sectionRowIndex("recent", index))
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("album", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionRowIndex("recent", index)) }
              }
            }
          }

          // ---- recent artists: derived from Recently Played, collapsed by default ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.recentArtists.length > 0
            spacing: Style.space(2)

            HomeSectionHeader {
              label: "Recent Artists"
              count: svc.recentArtists.length
              expanded: root.recentArtistsExpanded
              hasCursor: root.rowHasCursor(root.sectionHeaderIndex("recentArtists"))
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onToggled: root.toggleSection("recentArtists")
              onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionHeaderIndex("recentArtists")) }
            }

            Repeater {
              model: root.recentArtistsExpanded ? svc.recentArtists : []
              delegate: ArtistRow {
                required property var modelData
                required property int index
                readonly property int flatIndex: root.sectionRowIndex("recentArtists", index)
                name: modelData.name
                subtitle: modelData.count === 1 ? "1 recent album" : (modelData.count + " recent albums")
                busy: svc.busy === "play/" + modelData.id
                cursorOnRow: root.rowHasCursor(flatIndex)
                chipCursor: root.rowHasCursor(flatIndex) ? root.chipIndex : -1
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onMixActivated: svc.play("mix", modelData.id)
                onAllAlbumsActivated: svc.play("artist", modelData.id)
                onRowHovered: function(isHovered) { if (isHovered) root.setResultCursor(flatIndex) }
                onChipHovered: function(chip, isHovered) { if (isHovered) root.setChipCursor(flatIndex, chip) }
              }
            }
          }

          // ---- favorites: starred songs, collapsed by default ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.favoriteSongs.length > 0
            spacing: Style.space(2)

            HomeSectionHeader {
              label: "Favorites"
              count: svc.favoriteSongs.length
              expanded: root.favoritesExpanded
              hasCursor: root.rowHasCursor(root.sectionHeaderIndex("favorites"))
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onToggled: root.toggleSection("favorites")
              onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionHeaderIndex("favorites")) }
            }

            Repeater {
              model: root.favoritesExpanded ? svc.favoriteSongs : []
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.title
                subtitle: modelData.artist + (modelData.album ? " · " + modelData.album : "")
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(root.sectionRowIndex("favorites", index))
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("song", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionRowIndex("favorites", index)) }
              }
            }
          }

          // ---- favorite artists: derived from Favorites, collapsed by default ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.favoriteArtists.length > 0
            spacing: Style.space(2)

            HomeSectionHeader {
              label: "Favorite Artists"
              count: svc.favoriteArtists.length
              expanded: root.favoriteArtistsExpanded
              hasCursor: root.rowHasCursor(root.sectionHeaderIndex("favoriteArtists"))
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onToggled: root.toggleSection("favoriteArtists")
              onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionHeaderIndex("favoriteArtists")) }
            }

            Repeater {
              model: root.favoriteArtistsExpanded ? svc.favoriteArtists : []
              delegate: ArtistRow {
                required property var modelData
                required property int index
                readonly property int flatIndex: root.sectionRowIndex("favoriteArtists", index)
                name: modelData.name
                subtitle: modelData.count === 1 ? "1 favorite song" : (modelData.count + " favorite songs")
                busy: svc.busy === "play/" + modelData.id
                cursorOnRow: root.rowHasCursor(flatIndex)
                chipCursor: root.rowHasCursor(flatIndex) ? root.chipIndex : -1
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onMixActivated: svc.play("mix", modelData.id)
                onAllAlbumsActivated: svc.play("artist", modelData.id)
                onRowHovered: function(isHovered) { if (isHovered) root.setResultCursor(flatIndex) }
                onChipHovered: function(chip, isHovered) { if (isHovered) root.setChipCursor(flatIndex, chip) }
              }
            }
          }

          // ---- playlists: collapsed by default ----
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.showingRecent && svc.playlists.length > 0
            spacing: Style.space(2)

            HomeSectionHeader {
              label: "Playlists"
              count: svc.playlists.length
              expanded: root.playlistsExpanded
              hasCursor: root.rowHasCursor(root.sectionHeaderIndex("playlists"))
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onToggled: root.toggleSection("playlists")
              onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionHeaderIndex("playlists")) }
            }

            Repeater {
              model: root.playlistsExpanded ? svc.playlists : []
              delegate: ResultRow {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                title: modelData.name
                subtitle: modelData.songCount + (modelData.songCount === 1 ? " song" : " songs")
                busy: svc.busy === "play/" + modelData.id
                hasCursor: root.rowHasCursor(root.sectionRowIndex("playlists", index))
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onActivated: svc.play("playlist", modelData.id)
                onHovered: function(isHovered) { if (isHovered) root.setResultCursor(root.sectionRowIndex("playlists", index)) }
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
              delegate: ArtistRow {
                required property var modelData
                required property int index
                name: modelData.name
                subtitle: modelData.albumCount + (modelData.albumCount === 1 ? " album" : " albums")
                busy: svc.busy === "play/" + modelData.id
                cursorOnRow: root.rowHasCursor(index)
                chipCursor: root.rowHasCursor(index) ? root.chipIndex : -1
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onMixActivated: svc.play("mix", modelData.id)
                onAllAlbumsActivated: svc.play("artist", modelData.id)
                onRowHovered: function(isHovered) { if (isHovered) root.setResultCursor(index) }
                onChipHovered: function(chip, isHovered) { if (isHovered) root.setChipCursor(index, chip) }
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
        }
      }
    }
  }
}
