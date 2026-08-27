// Owns search, the play/control actions, and the mpv-status poll. Knows
// nothing about how any of it is drawn.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: svc

  property int statusRefreshSec: 2
  property int mixCount: 40
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- search state ----
  property bool searching: false
  property string searchError: ""
  property var artists: []
  property var albums: []
  property var songs: []

  // ---- home-screen sections (the default view before you type anything) ----
  property var recentAlbums: []
  property string recentError: ""
  property var favoriteSongs: []
  property string favoritesError: ""
  property var playlists: []
  property string playlistsError: ""

  // ---- now-playing state (mirrors status.py) ----
  property bool loaded: false
  property bool paused: true
  property real position: 0
  property real duration: 0
  property int queuePos: -1
  property int queueCount: 0
  property var track: ({})

  // "" | "search" | "play/<id>" | "control/<action>"
  property string busy: ""
  property string actionError: ""

  // Seconds since the last authoritative status poll, added to `position`
  // so the progress bar creeps every second instead of jumping by
  // statusRefreshSec. Reset on every poll; gated on active playback so an
  // idle bar costs nothing.
  property int tick: 0

  function livePos() {
    if (!loaded) return 0
    var p = position + (paused ? 0 : tick)
    return duration > 0 ? Math.min(p, duration) : p
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      onStreamFinished: {
        svc.searching = false
        var raw = this.text ? this.text.trim() : ""
        try {
          var d = JSON.parse(raw)
          if (d.ok) {
            svc.artists = d.artists || []
            svc.albums = d.albums || []
            svc.songs = d.songs || []
            svc.searchError = ""
          } else {
            svc.artists = []; svc.albums = []; svc.songs = []
            svc.searchError = d.error || "search failed"
          }
        } catch (e) {
          svc.artists = []; svc.albums = []; svc.songs = []
          svc.searchError = "unparseable"
        }
      }
    }
  }

  function search(query) {
    if (searchProc.running) searchProc.running = false
    if (!query) { artists = []; albums = []; songs = []; searchError = ""; searching = false; return }
    svc.searching = true
    searchProc.command = ["bash", pluginDir + "/backend.sh", "search", query]
    searchProc.running = true
  }

  Process {
    id: recentProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        try {
          var d = JSON.parse(raw)
          if (d.ok) { svc.recentAlbums = d.albums || []; svc.recentError = "" }
          else { svc.recentAlbums = []; svc.recentError = d.error || "failed" }
        } catch (e) {
          svc.recentAlbums = []; svc.recentError = "unparseable"
        }
      }
    }
  }

  function loadRecent() {
    if (recentProc.running) return
    recentProc.command = ["bash", pluginDir + "/backend.sh", "recent"]
    recentProc.running = true
  }

  Process {
    id: favoritesProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        try {
          var d = JSON.parse(raw)
          if (d.ok) { svc.favoriteSongs = d.songs || []; svc.favoritesError = "" }
          else { svc.favoriteSongs = []; svc.favoritesError = d.error || "failed" }
        } catch (e) {
          svc.favoriteSongs = []; svc.favoritesError = "unparseable"
        }
      }
    }
  }

  function loadFavorites() {
    if (favoritesProc.running) return
    favoritesProc.command = ["bash", pluginDir + "/backend.sh", "favorites"]
    favoritesProc.running = true
  }

  Process {
    id: playlistsProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        try {
          var d = JSON.parse(raw)
          if (d.ok) { svc.playlists = d.playlists || []; svc.playlistsError = "" }
          else { svc.playlists = []; svc.playlistsError = d.error || "failed" }
        } catch (e) {
          svc.playlists = []; svc.playlistsError = "unparseable"
        }
      }
    }
  }

  function loadPlaylists() {
    if (playlistsProc.running) return
    playlistsProc.command = ["bash", pluginDir + "/backend.sh", "playlists"]
    playlistsProc.running = true
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        try {
          var d = JSON.parse(raw)
          svc.loaded = !!d.loaded
          if (d.loaded) {
            svc.paused = !!d.paused
            svc.position = d.position || 0
            svc.duration = d.duration || 0
            svc.queuePos = d.queue_pos
            svc.queueCount = d.queue_count
            svc.track = d.track || {}
            svc.tick = 0
          } else {
            svc.track = ({})
          }
        } catch (e) {
          // A transient parse failure just skips this tick; the next poll
          // corrects it. Nothing here is worth surfacing as an error.
        }
      }
    }
  }

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = ["bash", pluginDir + "/backend.sh", "status"]
    statusProc.running = true
  }

  Process {
    id: playProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busy = ""
        svc.refreshStatus()
      }
    }
  }

  function play(kind, id) {
    if (playProc.running || busy !== "") return
    busy = "play/" + id
    actionError = ""
    var args = ["bash", pluginDir + "/backend.sh", "play", kind, String(id)]
    if (kind === "mix") args.push(String(svc.mixCount))
    playProc.command = args
    playProc.running = true
  }

  Process {
    id: controlProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busy = ""
        svc.refreshStatus()
      }
    }
  }

  function control(action) {
    if (controlProc.running || busy !== "") return
    busy = "control/" + action
    actionError = ""
    controlProc.command = ["bash", pluginDir + "/backend.sh", "control", action]
    controlProc.running = true
  }

  Process {
    id: starProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busy = ""
        svc.refreshStatus()
      }
    }
  }

  function toggleStar(songId, currentlyStarred) {
    if (starProc.running || busy !== "" || !songId) return
    busy = "star/" + songId
    actionError = ""
    starProc.command = ["bash", pluginDir + "/backend.sh", currentlyStarred ? "unstar" : "star", String(songId)]
    starProc.running = true
  }

  Timer {
    interval: Math.max(1, svc.statusRefreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: svc.refreshStatus()
  }

  Timer {
    interval: 1000
    running: svc.loaded && !svc.paused
    repeat: true
    onTriggered: svc.tick += 1
  }
}
