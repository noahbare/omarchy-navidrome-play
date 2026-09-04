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

  // Derived, not fetched: deduping the lists above by artist costs no extra
  // network round trip, and it's the only signal this server actually has --
  // Navidrome users star songs, essentially never whole artists, so a
  // "favourite artists" section built on getStarred2's (near-always-empty)
  // artist list would be dead space.
  readonly property var recentArtists: {
    var order = [], counts = {}, names = {}
    for (var i = 0; i < recentAlbums.length; i++) {
      var a = recentAlbums[i]
      if (!a.artistId) continue
      if (!(a.artistId in counts)) { order.push(a.artistId); names[a.artistId] = a.artist; counts[a.artistId] = 0 }
      counts[a.artistId] += 1
    }
    return order.map(function(id) { return {id: id, name: names[id], count: counts[id]} })
                .sort(function(x, y) { return y.count - x.count })
  }
  readonly property var favoriteArtists: {
    var order = [], counts = {}, names = {}
    for (var j = 0; j < favoriteSongs.length; j++) {
      var s = favoriteSongs[j]
      if (!s.artistId) continue
      if (!(s.artistId in counts)) { order.push(s.artistId); names[s.artistId] = s.artist; counts[s.artistId] = 0 }
      counts[s.artistId] += 1
    }
    return order.map(function(id) { return {id: id, name: names[id], count: counts[id]} })
                .sort(function(x, y) { return y.count - x.count })
  }

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

  // ---- backend process watchdog ----
  // Every backend.sh invocation ultimately execs a single python3 process
  // (no forked children -- mpv is the one deliberate exception, and it is
  // always started fully detached via start_new_session, so it is never a
  // child of these Process objects and this watchdog never touches it).
  // StdioCollector has no timeout or byte ceiling of its own, so without
  // this a stalled network call -- or a server that stalls just short of
  // its own per-request timeout on every one of an "artist" play's up to
  // 60 sequential requests -- could leave a Process (and svc.busy) wedged
  // indefinitely. Each launcher below arms a deadline before starting its
  // Process; this timer enforces it: SIGTERM first, then SIGKILL if the
  // process hasn't actually exited shortly after.
  readonly property int killGraceMs: 2000

  function armDeadline(proc, timeoutMs) {
    proc.deadlineAt = Date.now() + timeoutMs
    proc.killEscalate = false
  }

  function watchdogTick() {
    var now = Date.now()
    var procs = [searchProc, recentProc, favoritesProc, playlistsProc,
                 statusProc, playProc, controlProc, starProc]
    for (var i = 0; i < procs.length; i++) {
      var proc = procs[i]
      if (!proc.running) { proc.killEscalate = false; continue }
      if (proc.killEscalate) {
        if (now - proc.killedAt > svc.killGraceMs) {
          try { proc.signal(9) } catch (e) {}
          proc.running = false
          proc.killEscalate = false
        }
        continue
      }
      if (proc.deadlineAt && now > proc.deadlineAt) {
        try { proc.signal(15) } catch (e) {}
        proc.killedAt = now
        proc.killEscalate = true
      }
    }
  }

  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: svc.watchdogTick()
  }

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
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(searchProc, 20000)
    searchProc.running = true
  }

  Process {
    id: recentProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(recentProc, 20000)
    recentProc.running = true
  }

  Process {
    id: favoritesProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(favoritesProc, 20000)
    favoritesProc.running = true
  }

  Process {
    id: playlistsProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(playlistsProc, 20000)
    playlistsProc.running = true
  }

  Process {
    id: statusProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(statusProc, 15000)
    statusProc.running = true
  }

  Process {
    id: playProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    // Generous: an "artist" play can chain a getArtist call plus up to
    // ARTIST_BUILD_DEADLINE_SEC (45s, play.py) worth of getAlbum calls,
    // plus mpv startup -- this only needs to catch a genuine hang, since
    // play.py already bounds its own worst case well under this.
    svc.armDeadline(playProc, 60000)
    playProc.running = true
  }

  Process {
    id: controlProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(controlProc, 10000)
    controlProc.running = true
  }

  Process {
    id: starProc
    property real deadlineAt: 0
    property bool killEscalate: false
    property real killedAt: 0
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
    svc.armDeadline(starProc, 20000)
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
