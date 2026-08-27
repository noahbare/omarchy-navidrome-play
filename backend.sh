#!/usr/bin/env bash
# Navidrome search + local playback -> one compact JSON line on stdout.
#
# The ONLY entry point into this plugin's network and process surface. Kept
# as scripts, not QML, so the whole thing can be run and diffed over SSH.
#
#   backend.sh search <query>                         search artists/albums/songs
#   backend.sh play song|album|mix|artist|playlist <id> [count]  replace the queue and play
#     song     -- just that track          mix      -- similar-artist radio (needs count)
#     album    -- that album, track order  artist   -- every album, in album order
#     playlist -- that playlist, in order
#   backend.sh control playpause|next|previous|stop
#   backend.sh star|unstar <songId>
#   backend.sh recent                                  recently played albums
#   backend.sh favorites                                starred albums
#   backend.sh playlists                                saved playlists
#   backend.sh status                                  what mpv is playing right now
#
# Playback happens LOCALLY: this plugin owns and drives its own mpv instance,
# streaming from Navidrome's Subsonic API. It does not remote-control any
# other client.
#
# Config: ~/.config/omarchy-navidrome/config.json
#   {"url":"http://host:4533","public_url":"https://navidrome.example.com",
#    "user":"...","password":"..."}
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${OMARCHY_NAVIDROME_CONFIG:-$HOME/.config/omarchy-navidrome/config.json}"

[ -r "$CFG" ] || { printf '{"ok":false,"error":"not configured"}\n'; exit 1; }
export OMARCHY_NAVIDROME_CONFIG="$CFG"

case "${1:-status}" in
  search)
    [ $# -eq 2 ] || { printf '{"ok":false,"error":"usage: search <query>"}\n'; exit 1; }
    exec python3 "$DIR/search.py" "$2"
    ;;
  play)
    [ $# -eq 3 ] || [ $# -eq 4 ] || { printf '{"ok":false,"error":"usage: play <song|album|mix|artist|playlist> <id> [count]"}\n'; exit 1; }
    exec python3 "$DIR/play.py" "${@:2}"
    ;;
  control)
    [ $# -eq 2 ] || { printf '{"ok":false,"error":"usage: control <playpause|next|previous|stop>"}\n'; exit 1; }
    exec python3 "$DIR/control.py" "$2"
    ;;
  star|unstar)
    [ $# -eq 2 ] || { printf '{"ok":false,"error":"usage: star|unstar <songId>"}\n'; exit 1; }
    exec python3 "$DIR/star.py" "$1" "$2"
    ;;
  recent)
    exec python3 "$DIR/recent.py"
    ;;
  favorites)
    exec python3 "$DIR/favorites.py"
    ;;
  playlists)
    exec python3 "$DIR/playlists.py"
    ;;
  status)
    exec python3 "$DIR/status.py"
    ;;
  *)
    printf '{"ok":false,"error":"unknown command"}\n'
    exit 1
    ;;
esac
