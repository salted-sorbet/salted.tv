# salted.TV

**salted.TV is an IPTV player for the Omarchy shell bar.** Paste any M3U
playlist URL, filter hundreds of channels as you type, star the good ones,
and watch in mpv — all from a single icon in your status bar.
GUI forked from [tenzin.animechy](https://github.com/yesheytenzin) (GPL-3.0).

## What it does

- **Custom playlists** — paste any M3U/M3U8 playlist URL and load it;
  cached locally for a day after first fetch.
- **Instant filtering** — narrow channels by name or group as you type.
- **Favorites** — tap ☆ on any channel; browse them via ★ Favorites.
  Stored in `~/.config/salted.TV/favorites.json`.
- **mpv playback** — click a channel to open it in a detached mpv window;
  Stop in the panel ends playback.

## Requirements

- [Omarchy](https://omarchy.org/) (Hyprland + Quickshell shell)
- `python3` (preinstalled on Omarchy)
- `mpv` — install with:

```
omarchy pkg add mpv
```

## Installation

Install it the standard Omarchy way:

```bash
omarchy plugin add https://github.com/salted-sorbet/salted.TV.git --enable
```

This clones the plugin into `~/.config/omarchy/plugins/salted.TV` and, with
`--enable`, pins the TV icon into your bar (it asks which section; default
right). A TV icon appears in your bar. First click installs the bridge to
`~/.cache/salted.TV/` automatically — then paste a playlist URL and watch.

### Updating

```bash
omarchy plugin update salted.TV
```

The bridge reinstalls itself when the plugin version changes.

## Removal

```bash
omarchy plugin remove salted.TV

# optional: drop cached playlists and saved favorites too
rm -rf ~/.cache/salted.TV ~/.config/salted.TV
```

## Layout

```
BarWidget.qml          bar icon (TV frame + play composite) + bridge bootstrap
Panel.qml              channel browser: source dropdown, filter, favorites
bridge/salted-tv-bridge.py   stdlib Python CLI: sources/channels/add/remove/play/stop/status
salted-tv-setup.sh     installs bridge to ~/.cache/salted.TV, verifies tools
```

The bridge never writes inside the plugin directory (omarchy watches it with
inotify and reloads on change). Runtime state lives in `~/.cache/salted.TV/`,
user data in `~/.config/salted.TV/`.

## Usage

Click the TV icon in the bar:

1. Paste an M3U playlist URL and hit **Load URL** (or open ★ Favorites).
2. Filter with the search field, click a channel to watch.
3. ☆ saves it to favorites; browse those via the source dropdown.
4. **Stop** closes the stream.

Note: stream availability depends entirely on the playlist you provide —
dead or geo-blocked links are normal; ☆ keeps the ones that work for you.

## License

GPL-3.0 — see [LICENSE](LICENSE). Derived from tenzin.animechy, which is
itself powered by ani-cli.
