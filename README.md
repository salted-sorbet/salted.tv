# salted.TV

Software-defined radio tuner for the Omarchy shell bar — scan and listen to
free-to-air broadcast radio, with experimental digital TV, all routed through
mpv. GUI forked from [tenzin.animechy](../tenzin.animechy/) (GPL-3.0).

## What it does

- **FM radio (solid)** — power-scan the 87.5–108 MHz band with `rx_power`,
  click a hit to tune, or type a frequency directly. Audio chain:
  `rx_fm` → raw PCM → `mpv`.
- **DVB-T TV (experimental)** — software-demodulated digital TV via
  `leandvb`: `rx_sdr` → `leandvb` → MPEG-TS → `mpv`. CPU-heavy; expect a
  warm laptop and mixed results.
- **Any SDR hardware** — everything goes through the SoapySDR abstraction,
  so RTL-SDR, Airspy, HackRF, SDRplay, `soapy_remote`, etc. all work.
- **Channel memory** — saved per band in `~/.config/salted.TV/channels.json`.

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| `soapysdr` | device abstraction + probe | `omarchy pkg add soapysdr` |
| Soapy module for your stick | e.g. `soapyrtlsdr`, `soapyairspy`, `soapyhackrf` | AUR / upstream |
| `rx-tools` (`rx_fm`, `rx_sdr`, `rx_power`) | tuned sample streaming | `paru -S rx-tools` |
| `mpv` | playback | `omarchy pkg add mpv` |
| `leandvb` | DVB-T demodulation (optional) | `paru -S leandvb` |

The setup script checks all of this on first click and reports what's missing.

## Layout

```
BarWidget.qml          bar icon + bridge bootstrap (forked from animechy)
Panel.qml              tuner panel: band toggle, frequency/gain, scan, channels
bridge/salted-tv-bridge.py   stdlib Python CLI: ping/status/channels/scan/play/stop
salted-tv-setup.sh     installs bridge to ~/.cache/salted.TV, verifies toolchain
```

The bridge never writes inside the plugin directory (omarchy watches it with
inotify and reloads on change). Runtime state lives in `~/.cache/salted.TV/`.

## Usage

Click the TV icon in the bar:

1. Pick **FM** or **DVB-T**.
2. **Scan** (FM) shows candidate stations as chips — click to tune — or type
   a frequency and hit **Play**.
3. **Save** stores the current frequency; ✕ removes it.
4. **Stop** tears down the pipeline.

## License

GPL-3.0 — see [LICENSE](LICENSE). Derived from tenzin.animechy, which is
itself powered by ani-cli.
