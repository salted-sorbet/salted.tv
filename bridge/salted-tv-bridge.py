#!/usr/bin/env python3
"""salted.TV bridge — IPTV channel browser for the salted.TV shell plugin.

Pure stdlib. Invoked as:  salted-tv-bridge.py '{"cmd":"ping"}'
Prints a single JSON object to stdout.

Channel data comes from the iptv-org index (public, community-maintained).

Commands:
  ping                        tool check
  countries                   list countries from iptv-org API (cached)
  channels source [q]         list/search channels for a country code/name
                              or "favorites"
  add name url                save a favorite
  remove url                  delete a favorite
  play url [name]             play a stream in detached mpv
  stop                        kill mpv
  status                      is something playing?
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "salted.TV"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "salted.TV"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"
PID_FILE = RUNTIME / "play.pid"
LOG_FILE = RUNTIME / "play.log"
COUNTRIES_API = "https://iptv-org.github.io/api/countries.json"
COUNTRIES_CACHE = RUNTIME / "countries.json"
COUNTRIES_TTL = 7 * 24 * 3600
PLAYLIST_URL = "https://iptv-org.github.io/iptv/countries/{}.m3u"
MAX_RESULTS = 400


def out(obj):
    print(json.dumps(obj))
    sys.stdout.flush()


def err(msg):
    return {"ok": False, "error": msg}


def which(name):
    return shutil.which(name)


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "salted.TV/0.2"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def load_countries():
    if COUNTRIES_CACHE.exists() and time.time() - COUNTRIES_CACHE.stat().st_mtime < COUNTRIES_TTL:
        try:
            return json.loads(COUNTRIES_CACHE.read_text())
        except ValueError:
            pass
    try:
        data = json.loads(fetch(COUNTRIES_API))
    except Exception as e:
        if COUNTRIES_CACHE.exists():
            try:
                return json.loads(COUNTRIES_CACHE.read_text())
            except ValueError:
                pass
        raise e
    COUNTRIES_CACHE.write_text(json.dumps(data))
    return data


def resolve_country(query):
    """Accept a 2-letter code or a unique prefix of a country name."""
    q = query.strip().lower()
    countries = load_countries()
    for c in countries:
        if c["code"].lower() == q:
            return c
    matches = [c for c in countries if c["name"].lower().startswith(q)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        names = ", ".join(m["name"] for m in matches[:6])
        raise ValueError(f"ambiguous country {query!r}: {names} …")
    raise ValueError(f"unknown country {query!r}")


def playlist_path(code):
    return RUNTIME / f"playlist-{code.lower()}.m3u"


def get_playlist(code):
    """Download once per day, then parse from cache."""
    path = playlist_path(code)
    fresh = path.exists() and time.time() - path.stat().st_mtime < 24 * 3600
    if not fresh:
        data = fetch(PLAYLIST_URL.format(code.lower()), timeout=60)
        RUNTIME.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".m3u.new")
        tmp.write_bytes(data)
        os.replace(tmp, path)
    return parse_m3u(path)


def parse_m3u(path):
    channels = []
    attrs_re = re.compile(r'([a-zA-Z0-9-]+)="([^"]*)"')
    pending = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("#EXTINF:"):
                _, _, title = line.partition(",")
                attrs = dict(attrs_re.findall(line))
                pending = {
                    "name": title.strip(),
                    "group": attrs.get("group-title", ""),
                    "logo": attrs.get("tvg-logo", ""),
                    "url": "",
                }
            elif line and not line.startswith("#") and pending is not None:
                pending["url"] = line
                if pending["name"]:
                    channels.append(pending)
                pending = None
    return channels


def load_favorites():
    try:
        favs = json.loads(FAVORITES_FILE.read_text())
        if isinstance(favs, list):
            return favs
    except (OSError, ValueError):
        pass
    return []


def save_favorites(favs):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = FAVORITES_FILE.with_suffix(".json.new")
    tmp.write_text(json.dumps(favs, indent=2))
    os.replace(tmp, FAVORITES_FILE)


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


def do_channels(params):
    source = str(params.get("source", "")).strip()
    query = str(params.get("q", "")).strip().lower()

    if source.lower() in ("favorites", "favorite", "fav", "starred"):
        chans = [
            {"name": f.get("name", ""), "group": "favorite",
             "logo": "", "url": f.get("url", "")}
            for f in load_favorites() if f.get("url")
        ]
        total = len(chans)
        label = "Favorites"
    else:
        if not source:
            return err("no source given — pass a country code or 'favorites'")
        try:
            country = resolve_country(source)
        except ValueError as e:
            return err(str(e))
        except Exception as e:
            return err(f"could not reach iptv-org: {e}")
        try:
            chans = get_playlist(country["code"])
        except Exception as e:
            return err(f"playlist download failed: {e}")
        total = len(chans)
        label = country["name"]

    if query:
        chans = [c for c in chans
                 if query in c["name"].lower()
                 or query in c["group"].lower()]
    return {"ok": True, "country": label, "total": total,
            "count": min(len(chans), MAX_RESULTS),
            "channels": chans[:MAX_RESULTS]}


def _q(part):
    s = str(part)
    if not s or any(c in s for c in " |&;<>()$`\\\"'*?[]#~=%{}\n"):
        return "'" + s.replace("'", "'\\''") + "'"
    return s


def do_play(params):
    url = str(params.get("url", "")).strip()
    name = str(params.get("name", "")).strip()
    if not re.match(r"^https?://", url):
        return err("invalid stream URL")
    if not which("mpv"):
        return err("mpv not found — install with: omarchy pkg add mpv")

    if is_running(read_pid()):
        kill_player()

    RUNTIME.mkdir(parents=True, exist_ok=True)
    cmd = ["mpv", "--force-window=immediate", "--no-terminal",
           "--really-quiet", f"--title=salted.TV • {name or 'IPTV'}", url]
    with open(LOG_FILE, "ab") as log:
        log.write(f"\n=== {time.strftime('%F %T')} play {name!r} ===\n".encode())
        log.flush()
        proc = subprocess.Popen(
            cmd, stdout=log, stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    PID_FILE.write_text(str(proc.pid) + "\n")
    return {"ok": True, "pid": proc.pid}


def kill_player():
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


def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    try:
        req = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    except ValueError:
        out(err("bad JSON request"))
        return
    cmd = req.get("cmd", "")

    if cmd == "ping":
        out({"ok": True,
             "tools": {"mpv": bool(which("mpv")), "python3": True}})
    elif cmd == "countries":
        try:
            cs = [{"name": c["name"], "code": c["code"]}
                  for c in load_countries()]
            out({"ok": True, "countries": cs})
        except Exception as e:
            out(err(f"iptv-org unreachable: {e}"))
    elif cmd == "channels":
        out(do_channels(req))
    elif cmd == "add":
        favs = load_favorites()
        entry = {"name": str(req.get("name", "")),
                 "url": str(req.get("url", ""))}
        if not entry["url"]:
            out(err("add needs url")); return
        favs[:] = [f for f in favs if f.get("url") != entry["url"]]
        favs.append(entry)
        save_favorites(favs)
        out({"ok": True})
    elif cmd == "remove":
        url = str(req.get("url", ""))
        favs = load_favorites()
        before = len(favs)
        favs[:] = [f for f in favs if f.get("url") != url]
        save_favorites(favs)
        out({"ok": True, "removed": before - len(favs)})
    elif cmd == "play":
        out(do_play(req))
    elif cmd == "stop":
        out({"ok": True, "stopped": kill_player()})
    elif cmd == "status":
        pid = read_pid()
        out({"ok": True, "playing": is_running(pid), "pid": pid})
    else:
        out(err(f"unknown cmd: {cmd!r}"))


if __name__ == "__main__":
    main()
