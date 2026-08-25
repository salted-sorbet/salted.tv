#!/usr/bin/env python3
"""salted.tv bridge — IPTV channel browser for the salted.tv shell plugin.

Pure stdlib. Invoked as:  salted-tv-bridge.py '{"cmd":"ping"}'
Prints a single JSON object to stdout.

Channel data comes from public community indexes: iptv-org and Free-TV.

Commands:
  ping                        tool check
  sources                     grouped source list for the dropdown
  channels source [q]         list/search channels for a source
  add name url                save a favorite
  remove url                  delete a favorite
  play url [name]             play a stream in detached mpv
  stop                        kill mpv
  status                      is something playing?

Source forms:
  favorites | <country code or name> | global:index | global:freetv
  category:<name> | language:<code> | region:<code> | url:<m3u URL>
"""

import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "salted.tv"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "salted.tv"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"
URLS_FILE = CONFIG_DIR / "urls.json"
STATE_FILE = CONFIG_DIR / "state.json"
MAX_SAVED_URLS = 20
PID_FILE = RUNTIME / "play.pid"
LOG_FILE = RUNTIME / "play.log"

IPTV_ORG = "https://iptv-org.github.io/iptv"
COUNTRIES_API = "https://iptv-org.github.io/api/countries.json"
CATEGORIES_API = "https://iptv-org.github.io/api/categories.json"
LANGUAGES_API = "https://iptv-org.github.io/api/languages.json"
REGIONS_API = "https://iptv-org.github.io/api/regions.json"
FREE_TV_URL = "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8"
CACHE_TTL = 24 * 3600
MAX_RESULTS = 2000

POPULAR_CATEGORIES = [
    "news", "sports", "movies", "series", "music", "kids",
    "documentary", "entertainment", "comedy", "lifestyle",
    "culture", "religious", "travel", "business", "science",
]

POPULAR_LANGUAGES = [
    "ara", "eng", "fra", "spa", "deu", "por", "ita",
    "rus", "tur", "hin", "zho", "ind", "fas", "tam",
]

REGION_LABELS = {
    "afr": "Africa", "ame": "Americas", "asia": "Asia",
    "eur": "Europe", "latn": "Latin America", "mena": "MENA",
}


def out(obj):
    s = json.dumps(obj)
    if len(s) > 16 * 1024 * 1024:
        s = json.dumps(err("response too large"))
    print(s)
    sys.stdout.flush()


def err(msg):
    return {"ok": False, "error": msg}


def which(name):
    return shutil.which(name)


MAX_RESPONSE_BYTES = 32 * 1024 * 1024


def fetch(url, timeout=60):
    deadline = time.monotonic() + timeout
    req = urllib.request.Request(url, headers={"User-Agent": "salted.tv/0.4"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        length = r.headers.get("Content-Length")
        if length is not None and length.isdigit() and int(length) > MAX_RESPONSE_BYTES:
            raise ValueError(f"remote response larger than {MAX_RESPONSE_BYTES} bytes")
        chunks = []
        total = 0
        while True:
            if time.monotonic() > deadline:
                raise TimeoutError(f"total download time exceeded {timeout}s")
            chunk = r.read1(64 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RESPONSE_BYTES:
                raise ValueError(f"remote response larger than {MAX_RESPONSE_BYTES} bytes")
            chunks.append(chunk)
    return b"".join(chunks)


def _open_regular(path):
    """Open for reading, refusing non-regular files (FIFOs etc.) and
    symlinks without ever blocking on them. O_NONBLOCK makes open()/read()
    return immediately even for FIFOs; O_NOFOLLOW refuses symlinked paths;
    fstat then verifies the fd itself, so there is no swap window between
    check and read."""
    path = Path(path)
    fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
                 | getattr(os, "O_CLOEXEC", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(f"{path.name} is not a regular file")
        return fd
    except ValueError:
        os.close(fd)
        raise


def atomic_write(path, data):
    """Write bytes to a random exclusive 0600 temp file in the target
    directory, then atomically replace the destination. Never follows a
    planted symlink at either the temp or final path."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".",
                               suffix=".tmp", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def capped_text(path):
    chunks = []
    total = 0
    with os.fdopen(_open_regular(path), "rb") as f:
        while True:
            chunk = f.read(64 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RESPONSE_BYTES:
                raise ValueError(f"{path.name} exceeds {MAX_RESPONSE_BYTES} byte limit")
            chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", "replace")


def cached_json(path, url, ttl):
    if path.exists() and time.time() - path.stat().st_mtime < ttl:
        try:
            return json.loads(capped_text(path))
        except (OSError, ValueError):
            pass
    data = json.loads(fetch(url))
    atomic_write(path, json.dumps(data).encode())
    return data


def load_countries():
    return cached_json(RUNTIME / "countries.json", COUNTRIES_API, 7 * CACHE_TTL)


def load_categories():
    cats = cached_json(RUNTIME / "categories.json", CATEGORIES_API, 7 * CACHE_TTL)
    known = {c["slug"] if isinstance(c, dict) and "slug" in c else str(c)
             for c in cats}
    return [c for c in POPULAR_CATEGORIES if c in known] or POPULAR_CATEGORIES[:1]


def load_language_names():
    try:
        langs = cached_json(RUNTIME / "languages.json", LANGUAGES_API, 7 * CACHE_TTL)
        return {l["code"].lower(): l["name"] for l in langs if isinstance(l, dict)}
    except Exception:
        return {}


def load_regions():
    try:
        regions = cached_json(RUNTIME / "regions.json", REGIONS_API, 7 * CACHE_TTL)
        return [(r["code"].lower(), r["name"]) for r in regions if isinstance(r, dict)]
    except Exception:
        return list(REGION_LABELS.items())


def resolve_country(query):
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


def cache_path(key):
    safe = re.sub(r"[^a-z0-9._-]", "_", key.lower())
    return RUNTIME / f"playlist-{safe}.m3u"


SOURCE_ROUTES = {
    "global:index": (f"{IPTV_ORG}/index.m3u", "Global • All iptv-org channels"),
    "global:freetv": (FREE_TV_URL, "Global • Free-TV collection"),
}


def resolve_source(src):
    """Return (url, cache_key, label)."""
    src = src.strip()
    low = src.lower()
    if low.startswith("category:"):
        cat = low.split(":", 1)[1].strip()
        if cat not in POPULAR_CATEGORIES:
            raise ValueError(f"unknown category {cat!r}")
        return f"{IPTV_ORG}/categories/{cat}.m3u", f"category:{cat}", f"{cat.title()} (all countries)"
    if low.startswith("language:"):
        lang = low.split(":", 1)[1].strip()
        name = load_language_names().get(lang, lang.upper())
        return f"{IPTV_ORG}/languages/{lang}.m3u", f"language:{lang}", f"{name} language (worldwide)"
    if low.startswith("region:"):
        reg = low.split(":", 1)[1].strip()
        label = dict(load_regions()).get(reg, reg.title())
        return f"{IPTV_ORG}/regions/{reg}.m3u", f"region:{reg}", f"{label} region"
    if low.startswith("url:"):
        raw = src[4:].strip()
        if not re.match(r"^https?://", raw):
            raise ValueError("custom URL must start with http(s)://")
        digest = hashlib.md5(raw.encode()).hexdigest()[:12]
        return raw, f"url:{digest}", "Custom playlist"
    if low in SOURCE_ROUTES:
        url, label = SOURCE_ROUTES[low]
        return url, low, label
    country = resolve_country(src)
    code = country["code"].lower()
    return f"{IPTV_ORG}/countries/{code}.m3u", f"country:{code}", country["name"]


def get_playlist(url, key):
    path = cache_path(key)
    fresh = path.exists() and time.time() - path.stat().st_mtime < CACHE_TTL
    if not fresh:
        data = fetch(url)
        RUNTIME.mkdir(parents=True, exist_ok=True)
        atomic_write(path, data)
    return parse_m3u(path)


def parse_m3u(path):
    channels = []
    attrs_re = re.compile(r'([a-zA-Z0-9-]+)="([^"]*)"')
    pending = None
    total = 0
    buf = b""

    def handle(raw):
        nonlocal pending
        line = raw.decode("utf-8", "replace").strip()
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

    with os.fdopen(_open_regular(path), "rb") as f:
        while True:
            chunk = f.read(64 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RESPONSE_BYTES:
                raise ValueError(f"{path.name} exceeds {MAX_RESPONSE_BYTES} byte limit")
            buf += chunk
            parts = buf.split(b"\n")
            buf = parts.pop()
            for raw in parts:
                handle(raw)
    if buf:
        handle(buf)
    return channels


def load_favorites():
    try:
        favs = json.loads(capped_text(FAVORITES_FILE))
        if isinstance(favs, list):
            return favs
    except (OSError, ValueError):
        pass
    return []


def save_favorites(favs):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(FAVORITES_FILE, json.dumps(favs, indent=2).encode())


def load_urls():
    try:
        data = json.loads(capped_text(URLS_FILE))
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def save_urls(items):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(URLS_FILE, json.dumps(items, indent=2).encode())


def url_label(u):
    try:
        from urllib.parse import urlparse
        p = urlparse(u)
        parts = [s for s in (p.path or "").split("/") if s]
        tail = ""
        if parts:
            tail = parts[-1]
            for ext in (".m3u8", ".m3u"):
                if tail.lower().endswith(ext):
                    tail = tail[: -len(ext)]
                    break
        host = (p.hostname or "").lower()
        if host.startswith("www."):
            host = host[4:]
        label = f"{host}/{tail}" if tail else host
        return label or u
    except Exception:
        return u


def remember_url(raw_url):
    raw_url = str(raw_url).strip()
    if not raw_url.lower().startswith(("http://", "https://")):
        return
    items = [i for i in load_urls() if isinstance(i, dict)]
    items = [i for i in items if i.get("url") != raw_url]
    items.insert(0, {"url": raw_url, "name": url_label(raw_url)})
    save_urls(items[:MAX_SAVED_URLS])


def do_urls():
    return {"ok": True, "urls": load_urls()}


def load_state():
    try:
        d = json.loads(capped_text(STATE_FILE))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(st):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(STATE_FILE, json.dumps(st, indent=2).encode())


def do_state(params):
    src = params.get("source", None)
    if src is not None:
        st = load_state()
        st["lastSource"] = str(src)[:2048]
        save_state(st)
    return {"ok": True, "state": load_state()}


def read_pid():
    try:
        return int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return None


def pid_is_ours(pid):
    """True only if /proc still says this pid is an mpv we started."""
    if pid is None or pid <= 1:
        return False
    try:
        proc = Path("/proc") / str(pid)
        if proc.joinpath("comm").read_text().strip() != "mpv":
            return False
        args = [a.decode("utf-8", "replace")
                for a in proc.joinpath("cmdline").read_bytes().split(b"\0") if a]
        return bool(args) and Path(args[0]).name == "mpv" \
            and any("salted.tv" in a for a in args)
    except OSError:
        return False


def is_running(pid):
    return pid_is_ours(pid)


def do_sources():
    opts = [{"value": "favorites", "label": "★ Favorites"}]
    return {"ok": True, "sources": opts}


def do_channels(params):
    source = str(params.get("source", "")).strip()
    query = str(params.get("q", "")).strip().lower()

    if not source:
        return err("no source given")

    if source.lower() in ("favorites", "favorite", "fav", "starred"):
        chans = [
            {"name": f.get("name", ""), "group": "favorite",
             "logo": "", "url": f.get("url", "")}
            for f in load_favorites() if f.get("url")
        ]
        total = len(chans)
        label = "Favorites"
    else:
        try:
            url, key, label = resolve_source(source)
        except ValueError as e:
            return err(str(e))
        except Exception as e:
            return err(f"could not reach index: {e}")
        try:
            chans = get_playlist(url, key)
        except Exception as e:
            return err(f"playlist download failed: {e}")
        total = len(chans)
        if source.lower().startswith("url:"):
            remember_url(source[4:].strip())

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
           "--really-quiet", f"--title=salted.tv • {name or 'IPTV'}", url]
    try:
        fd = os.open(str(LOG_FILE), os.O_WRONLY | os.O_APPEND | os.O_CREAT
                     | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
    except OSError as e:
        return err(f"log file unsafe: {e}")
    with os.fdopen(fd, "ab") as log:
        log.write(f"\n=== {time.strftime('%F %T')} play {name!r} ===\n".encode())
        log.flush()
        proc = subprocess.Popen(
            cmd, stdout=log, stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    atomic_write(PID_FILE, str(proc.pid).encode() + b"\n")
    return {"ok": True, "pid": proc.pid}


def kill_player():
    pid = read_pid()
    if not pid_is_ours(pid):
        try:
            PID_FILE.unlink()
        except OSError:
            pass
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
    elif cmd == "sources":
        out(do_sources())
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
    elif cmd == "urls":
        out(do_urls())
    elif cmd == "state":
        out(do_state(req))
    elif cmd == "urls_remove":
        u = str(req.get("url", "")).strip()
        items = [i for i in load_urls() if isinstance(i, dict) and i.get("url") != u]
        save_urls(items)
        out({"ok": True})
    elif cmd == "status":
        pid = read_pid()
        out({"ok": True, "playing": is_running(pid), "pid": pid})
    else:
        out(err(f"unknown cmd: {cmd!r}"))


if __name__ == "__main__":
    main()
