#!/usr/bin/env python3
"""salted.TV bridge — SoapySDR tuner control for the salted.TV shell plugin.

Pure stdlib. Invoked as:  salted-tv-bridge.py '{"cmd":"ping"}'
Prints a single JSON object to stdout.

Commands:
  ping                       probe tools + SDR devices
  status                     is a stream running?
  channels                   list saved channels {fm:[], tv:[]}
  add    band name freq      save a channel
  remove band freq           delete a channel
  scan                       power-scan the FM band (slow)
  play   band freq [gain]    start detached rx pipeline -> mpv
  stop                       kill the running pipeline
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "salted.TV"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "salted.TV"
CHANNELS_FILE = CONFIG_DIR / "channels.json"
PID_FILE = RUNTIME / "play.pid"
LOG_FILE = RUNTIME / "play.log"

FM_BAND = (87.5, 108.0)
FM_STEP_KHZ = 100
SCAN_TIMEOUT = 90

TOOLS = {
    "soapy": "SoapySDRUtil",
    "rx_fm": "rx_fm",
    "rx_sdr": "rx_sdr",
    "rx_power": "rx_power",
    "leandvb": "leandvb",
    "mpv": "mpv",
}


def out(obj):
    print(json.dumps(obj))
    sys.stdout.flush()


def err(msg):
    return {"ok": False, "error": msg}


def which(name):
    return shutil.which(name)


def tools_report():
    return {k: bool(which(v)) for k, v in TOOLS.items()}


def list_devices():
    soapy = which(TOOLS["soapy"])
    if not soapy:
        return []
    try:
        p = subprocess.run(
            [soapy, "--find="],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    drivers = []
    for line in (p.stdout + p.stderr).splitlines():
        line = line.strip()
        if line.startswith("driver="):
            drivers.append(line.split("=", 1)[1].split()[0])
    return sorted(set(drivers))


def load_channels():
    try:
        with open(CHANNELS_FILE) as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {
                "fm": list(data.get("fm", [])),
                "tv": list(data.get("tv", [])),
            }
    except (OSError, ValueError):
        pass
    return {"fm": [], "tv": []}


def save_channels(ch):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CHANNELS_FILE.with_suffix(".json.new")
    with open(tmp, "w") as f:
        json.dump(ch, f, indent=2)
    os.replace(tmp, CHANNELS_FILE)


def read_pid():
    try:
        return int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return None


def is_running(pid):
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def fm_pipeline(freq_mhz, gain):
    cmd = ["rx_fm", "-f", f"{freq_mhz}M", "-M", "fm", "-s", "230k",
           "-A", "std", "-l", "0", "-r", "48k"]
    if gain is not None:
        cmd += ["-g", str(gain)]
    player = [
        "mpv", "--force-window=immediate", "--no-terminal", "--really-quiet",
        "--demuxer=rawaudio", "--demuxer-rawaudio-format=s16le",
        "--demuxer-rawaudio-rate=48000", "--demuxer-rawaudio-channels=1",
        f"--title=salted.TV • FM {freq_mhz} MHz", "-",
    ]
    return " ".join(_q(c) for c in cmd) + " | " + " ".join(_q(c) for c in player)


def dvbt_pipeline(freq_mhz, gain):
    cmd = ["rx_sdr", "-f", f"{freq_mhz}M", "-s", "2400000", "-F", "cs16"]
    if gain is not None:
        cmd += ["-g", str(gain)]
    demod = ["leandvb", "--standard", "DVB-T", "--in-BW", "8", "--out", "ts"]
    player = [
        "mpv", "--force-window=immediate", "--no-terminal", "--really-quiet",
        f"--title=salted.TV • DVB-T {freq_mhz} MHz", "-",
    ]
    chain = " ".join(_q(c) for c in cmd) + " | " + " ".join(_q(c) for c in demod)
    return chain + " | " + " ".join(_q(c) for c in player)


def _q(part):
    s = str(part)
    if not s or any(c in s for c in " |&;<>()$`\\\"'*?[]#~=%{}\n"):
        return "'" + s.replace("'", "'\\''") + "'"
    return s


def do_play(params):
    band = params.get("band", "fm")
    freq = params.get("freq")
    gain = params.get("gain")
    try:
        freq = round(float(freq), 3)
    except (TypeError, ValueError):
        return err("invalid frequency")

    lo, hi = FM_BAND if band == "fm" else (47.0, 860.0)
    if not (lo <= freq <= hi):
        return err(f"{band.upper()} frequency out of range ({lo}-{hi} MHz)")

    missing = [t for t in ("mpv", "rx_fm" if band == "fm" else "rx_sdr")
               if not which(TOOLS[t])]
    if not which(TOOLS["soapy"]):
        missing.append(TOOLS["soapy"])
    if band == "tv" and not which(TOOLS["leandvb"]):
        missing.append(TOOLS["leandvb"])
    if missing:
        return err("missing tools: " + ", ".join(missing))

    if is_running(read_pid()):
        kill_pipeline()

    RUNTIME.mkdir(parents=True, exist_ok=True)
    script = fm_pipeline(freq, gain) if band == "fm" else dvbt_pipeline(freq, gain)
    with open(LOG_FILE, "ab") as log:
        log.write(f"\n=== {time.strftime('%F %T')} {band} {freq} ===\n".encode())
        log.flush()
        proc = subprocess.Popen(
            ["bash", "-c", script],
            stdout=log, stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    PID_FILE.write_text(str(proc.pid) + "\n")
    return {"ok": True, "band": band, "freq": freq, "pid": proc.pid}


def kill_pipeline():
    pid = read_pid()
    if pid is None:
        return False
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        PID_FILE.unlink()
    except OSError:
        pass
    return True


def do_scan(params):
    if not which(TOOLS["rx_power"]):
        return err("rx_power not found (install rx-tools)")
    lo, hi = FM_BAND
    step_hz = FM_STEP_KHZ * 1000
    span = f"{lo}M:{hi}M:{step_hz // 1000}k"
    try:
        p = subprocess.run(
            [TOOLS["rx_power"], "-f", span, "-i", "1"],
            capture_output=True, text=True, timeout=SCAN_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return err("scan timed out")
    except OSError as e:
        return err(f"rx_power failed: {e}")

    points = []
    for line in p.stdout.splitlines():
        cols = line.split(",")
        for col in cols[2:]:
            if ":" not in col:
                continue
            freq_s, _, pow_s = col.partition(":")
            try:
                points.append((float(freq_s) / 1e6, float(pow_s)))
            except ValueError:
                continue
    if not points:
        return err("no scan data — is an SDR device connected?")

    powers = sorted(pw for _, pw in points)
    floor = powers[len(powers) // 2]
    threshold = floor + 6.0

    stations = []
    cluster = []
    for freq, pw in points + [(1e9, -999)]:
        if pw >= threshold:
            cluster.append((freq, pw))
            continue
        if cluster:
            best = max(cluster, key=lambda c: c[1])
            stations.append({
                "freq": round(best[0], 3),
                "power": round(best[1], 1),
                "noiseFloor": round(floor, 1),
            })
            cluster = []
    return {"ok": True, "stations": stations, "noiseFloor": round(floor, 1)}


def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    try:
        req = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    except ValueError:
        out(err("bad JSON request"))
        return
    cmd = req.get("cmd", "")

    if cmd == "ping":
        out({"ok": True, "tools": tools_report(), "devices": list_devices()})
    elif cmd == "status":
        pid = read_pid()
        playing = is_running(pid)
        out({"ok": True, "playing": playing, "pid": pid})
    elif cmd == "channels":
        out({"ok": True, "channels": load_channels()})
    elif cmd == "add":
        ch = load_channels()
        band = req.get("band", "fm")
        try:
            entry = {"name": str(req.get("name") or f"{float(req['freq'])} MHz"),
                     "freq": round(float(req["freq"]), 3)}
        except (KeyError, TypeError, ValueError):
            out(err("add needs band, freq")); return
        lst = ch.setdefault(band, [])
        lst[:] = [c for c in lst if abs(c.get("freq", 0) - entry["freq"]) > 0.001]
        lst.append(entry)
        lst.sort(key=lambda c: c["freq"])
        save_channels(ch)
        out({"ok": True, "channels": ch})
    elif cmd == "remove":
        ch = load_channels()
        band = req.get("band", "fm")
        try:
            freq = round(float(req["freq"]), 3)
        except (TypeError, ValueError):
            out(err("remove needs freq")); return
        lst = ch.setdefault(band, [])
        before = len(lst)
        lst[:] = [c for c in lst if abs(c.get("freq", 0) - freq) > 0.001]
        save_channels(ch)
        out({"ok": True, "removed": before - len(lst), "channels": ch})
    elif cmd == "scan":
        out(do_scan(req))
    elif cmd == "play":
        out(do_play(req))
    elif cmd == "stop":
        out({"ok": True, "stopped": kill_pipeline()})
    else:
        out(err(f"unknown cmd: {cmd!r}"))


if __name__ == "__main__":
    main()
