# salted.TV

IPTV for the Omarchy shell bar — browse thousands of free-to-air live channels
from the [iptv-org](https://github.com/iptv-org/iptv) index, filter them,
favorite the good ones, and play in mpv. No tuner hardware required.
GUI forked from [tenzin.animechy](../tenzin.animechy/) (GPL-3.0).

## What it does

- **Any country** — type a code (`us`, `de`, `ng`, `jp` …) or name and Load;
  the playlist is fetched from iptv-org and cached locally for a day.
- **Instant filtering** — type in the search field to narrow hundreds of
  channels down as you type.
- **Favorites** — tap ☆ on any channel; view them all with source
  `favorites`. Stored in `~/.config/salted.TV/favorites.json`.
- **mpv playback** — click a channel and it opens in a detached mpv window;
  Stop in the panel ends it.

## Dependencies

Just `python3` (already present) and `mpv`:

```
omarchy pkg add mpv
```

## Layout

```
BarWidget.qml          bar icon + bridge bootstrap (forked from animechy)
Panel.qml              channel browser: country picker, filter, favorites
bridge/salted-tv-bridge.py   stdlib Python CLI: ping/countries/channels/add/remove/play/stop/status
salted-tv-setup.sh     installs bridge to ~/.cache/salted.TV, verifies tools
```

The bridge never writes inside the plugin directory (omarchy watches it with
inotify and reloads on change). Runtime state lives in `~/.cache/salted.TV/`,
user data in `~/.config/salted.TV/`.

## Usage

Click the TV icon in the bar:

1. Type your country code and hit **Load**.
2. Filter with the search field, click a channel to watch.
3. ☆ saves it to favorites; browse those via source `favorites`.
4. **Stop** closes the stream.

## License

GPL-3.0 — see [LICENSE](LICENSE). Derived from tenzin.animechy, which is
itself powered by ani-cli. Channel data by the iptv-org community.
