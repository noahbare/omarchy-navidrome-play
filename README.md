# Navidrome Play

Omarchy bar widget: search your Navidrome library and start playback — a
song, an album, an artist's similar-music mix, or a saved playlist —
streamed locally through `mpv`, with transport controls and a live
progress bar right in the bar.

Unlike a "now playing" display, this widget *is* the player: it owns the
`mpv` process it streams into, so every transport button actually works,
every time.

## Install

```bash
omarchy plugin add https://github.com/noahbare/omarchy-navidrome-play.git --enable
```

## Setup

Create `~/.config/omarchy-navidrome/config.json`:

```json
{
  "url": "http://192.168.1.10:4533",
  "public_url": "https://navidrome.example.com",
  "user": "you",
  "password": "..."
}
```

`chmod 600` it.

| Key | Meaning |
|-----|---------|
| `url` | LAN address, tried first on every action. |
| `public_url` | Optional. Used only when the LAN address is unreachable, so search and playback keep working away from home. |
| `user` / `password` | Navidrome login. Sent as Subsonic token auth (`md5(password + salt)`, fresh salt per request), never as the password itself. |

If you already run [Navidrome Remote](https://github.com/Kyrunner/omarchy-navidrome-remote),
this is the same config file — one set of credentials, both widgets read it.

## Using it

| | |
|---|---|
| Click the ♪ | Open search |
| Type | Search artists, albums, and songs (debounced) |
| Empty search box | Home screen: Recently Played, Recent Artists, Favorites, Favorite Artists, Playlists — each collapsed by default |
| Click a song / album / playlist row | Replace the queue and play it |
| Click an artist's **Mix** chip | Play a similar-music radio mix (`getSimilarSongs2`) |
| Click an artist's **All albums** chip | Queue every album, in album order |
| ♥ | Star / unstar the currently playing track |
| ⏮ ⏸/▶ ⏭ ⏹ | Previous / play-pause / next / stop |
| `Up`/`Down`, `j`/`k` | Move the cursor through the row list |
| `Left`/`Right`, `h`/`l` | Move between an artist's chips, or between transport buttons |
| `Enter`/`Space` | Activate whatever the cursor is on, including expanding a home section |
| `Tab` | Switch to the next bar widget's panel |
| `Esc` | Clear the search box, then close |
| Middle-click the bar icon | Refresh now-playing immediately |

Playback always **replaces** the queue — this is a search-and-play launcher,
not a queue editor. `mpv` is started once, detached, and kept idle between
tracks; the bar polls it directly, so the now-playing view stays live even
if the panel is closed and reopened.

## Dependencies

| | |
|---|---|
| Navidrome | Any version with a standard Subsonic API (`search3`, `getAlbum`, `getSimilarSongs2`, `getPlaylist`, `star`/`unstar`). |
| `mpv` | Does the actual streaming and decoding. |
| `bash`, `python3` | Standard library only — nothing to `pip install`. |

## Debugging

`backend.sh` is the whole network and process surface, so it can be run over SSH:

```bash
./backend.sh search "aphex twin"
./backend.sh play album <albumId>
./backend.sh play mix <artistId> 40
./backend.sh play artist <artistId>
./backend.sh play playlist <playlistId>
./backend.sh control playpause
./backend.sh control next
./backend.sh star <songId>
./backend.sh recent
./backend.sh favorites
./backend.sh playlists
./backend.sh status
```

State lives in `~/.local/state/nbare-navidrome-play/`:

- `endpoint.json` — which endpoint (LAN/public) last worked. Delete to force a re-probe.
- `queue.json` — the current queue's metadata, read by `status.py` so the bar never has to touch the network for it.
- `covers/` — cover art cache, capped at 100 files, oldest evicted first.

The `mpv` IPC socket is `$XDG_RUNTIME_DIR/nbare-navidrome-play-mpv.sock`.

## Removing it

```bash
omarchy plugin remove nbare.navidrome-play
rm -rf ~/.local/state/nbare-navidrome-play
```

The plugin only ever writes inside `~/.local/state/nbare-navidrome-play/`.
It reads `~/.config/omarchy-navidrome/config.json` and never edits it. If
nothing else uses that config file, remove it too.

## Icon

The bar icon is a plain Unicode eighth note (♪) — no font or asset dependency.

## Related

[Navidrome Remote](https://github.com/Kyrunner/omarchy-navidrome-remote) is a
companion widget with a different job: it shows what's playing from *any*
Subsonic client on the network (a phone, a tablet, Kodi), not just this one.
Since this widget's playback never reports itself to Navidrome's shared
now-playing registry, the two don't overlap in the bar — run either, or
both.
