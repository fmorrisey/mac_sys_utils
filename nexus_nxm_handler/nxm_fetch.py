#!/usr/bin/env python3
"""nxm-fetch — turn a Nexus Mods `nxm://` link into a downloaded archive, and (for Skyrim SE) an installed mod.

Called by "NXM Handler.app" when Firefox/Safari hands it a link from a Nexus "Mod Manager Download"
button. Can also be run by hand:

    nxm-fetch.py 'nxm://skyrimspecialedition/mods/12604/files/35407?key=...&expires=...'
    nxm-fetch.py --check          # validate the stored API key
    nxm-fetch.py --batch [--dry-run]   # Premium only: download+install every mods.json entry that has a file_id

API key lookup order: $NEXUS_API_KEY, macOS Keychain item (service com.fmorrisey.nexus-api),
~/.config/nexusmods/apikey. Free Nexus accounts work: the key+expires pair in the nxm link is what
authorises the download link; the API key only identifies you.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

APP, VER = "skymod-nxm", "1.0"
KEYCHAIN_SERVICE = "com.fmorrisey.nexus-api"
LOG = Path.home() / "Library/Logs/nxm-handler.log"
DOWNLOADS = {"skyrimspecialedition": Path.home() / "Games/Skyrim Mods/downloads"}
DEFAULT_DL = Path.home() / "Games/Nexus Downloads"
SKYMOD = Path.home() / "Code/mac_sys_utils/skyrim_mods/skymod.py"
QUIET = bool(os.environ.get("NXM_QUIET"))


def _stdout_is_logfile():
    try:
        a, b = os.fstat(1), LOG.stat()
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)
    except OSError:
        return False


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    if not _stdout_is_logfile():
        print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def notify(title, text):
    if QUIET:
        return
    subprocess.run(["/usr/bin/osascript", "-e",
                    f"display notification {json.dumps(text[:200])} with title {json.dumps(title)}"],
                   capture_output=True)


def api_key():
    k = os.environ.get("NEXUS_API_KEY", "").strip()
    if k:
        return k
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    f = Path.home() / ".config/nexusmods/apikey"
    if f.exists():
        return f.read_text().strip()
    return None


def api(path, key, params=None):
    url = "https://api.nexusmods.com/v1/" + path + (("?" + urllib.parse.urlencode(params)) if params else "")
    req = urllib.request.Request(url, headers={"apikey": key, "Application-Name": APP, "Application-Version": VER,
                                               "User-Agent": f"{APP}/{VER}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def parse(nxm):
    u = urllib.parse.urlparse(nxm)
    if u.scheme.lower() != "nxm":
        raise SystemExit(f"not an nxm link: {nxm}")
    m = re.match(r"^/mods/(\d+)/files/(\d+)", u.path)
    if not m:
        raise SystemExit(f"unexpected nxm path: {u.path}")
    q = dict(urllib.parse.parse_qsl(u.query))
    return u.netloc.lower(), int(m.group(1)), int(m.group(2)), q.get("key"), q.get("expires")


def clean_url(url):
    """Nexus CDN links contain literal spaces in the path; http.client refuses those."""
    u = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((u.scheme, u.netloc, urllib.parse.quote(u.path, safe="/%"),
                                    urllib.parse.quote(u.query, safe="=&%+/:,"), u.fragment))


def download(url, dest):
    tmp = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(clean_url(url), headers={"User-Agent": f"{APP}/{VER}"})
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got, last = 0, -1
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            if total:
                pct = got * 100 // total
                if pct // 10 != last // 10:
                    log(f"  {pct:3d}%  {got / 1048576:,.0f} / {total / 1048576:,.0f} MB")
                    last = pct
    tmp.rename(dest)
    return dest


def batch(key, dry=False):
    """Premium path: pull every manifest mod straight from the API, then run the installer once."""
    sys.path.insert(0, str(SKYMOD.parent))
    import skymod  # noqa: E402
    ctx = skymod.Ctx(SKYMOD.parent / "mods.json")
    if not key:
        raise SystemExit("no API key stored")
    me = api("users/validate.json", key)
    if not me.get("is_premium"):
        raise SystemExit(f"Nexus user {me.get('name')} is not Premium: the API only issues download links to Premium "
                         "accounts. Either go Premium for a month and re-run, or use Mod Manager Download on each page.")
    todo = []
    for mod in ctx.mods:
        if not mod.get("enabled", True) or not mod.get("file_id"):
            continue
        if ctx.installed(mod["id"]) or ctx.find_archive(mod):
            continue
        todo.append(mod)
    print(f"{len(todo)} files to fetch" + (" (dry run)" if dry else ""))
    failed = []
    for mod in todo:
        game = "skyrimspecialedition"
        info = api(f"games/{game}/mods/{mod['nexus']}/files/{mod['file_id']}.json", key)
        name = info.get("file_name")
        print(f"  {mod['id']:<28} {((info.get('size_kb') or 0) / 1024):7,.0f} MB  {name}")
        if dry:
            continue
        try:
            links = api(f"games/{game}/mods/{mod['nexus']}/files/{mod['file_id']}/download_link.json", key)
            dest = DOWNLOADS[game] / name
            DOWNLOADS[game].mkdir(parents=True, exist_ok=True)
            log(f"downloading {name}")
            download(links[0]["URI"], dest)
            log(f"saved {dest}")
        except Exception as e:  # noqa: BLE001
            log(f"FAILED {mod['id']}: {e}")
            failed.append(mod["id"])
    if failed:
        print("failed downloads: " + ", ".join(failed))
    if not dry and todo:
        r = subprocess.run(["/usr/bin/python3", str(SKYMOD), "install", "--all"], capture_output=True, text=True)
        print(r.stdout + r.stderr)
        notify("Nexus batch finished", f"{len(todo)} files fetched; see skymod output")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    arg = sys.argv[1]
    key = api_key()
    if arg == "--check":
        if not key:
            raise SystemExit("no API key stored. See nexus_nxm_handler/README.md")
        try:
            u = api("users/validate.json", key)
        except urllib.error.HTTPError as e:
            raise SystemExit(f"API key rejected: HTTP {e.code}")
        print(f"ok: Nexus user {u.get('name')} (premium={u.get('is_premium')})")
        return
    if arg == "--batch":
        return batch(key, dry="--dry-run" in sys.argv)
    game, mod, file, k, exp = parse(arg)
    log(f"nxm link: game={game} mod={mod} file={file} expires={exp}")
    if not key:
        notify("Nexus download failed", "No Nexus API key stored on this Mac. See nexus_nxm_handler/README.md")
        raise SystemExit("no API key")
    try:
        info = api(f"games/{game}/mods/{mod}/files/{file}.json", key)
        params = {"key": k, "expires": exp} if k and exp else None
        links = api(f"games/{game}/mods/{mod}/files/{file}/download_link.json", key, params)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        log(f"HTTP {e.code}: {body}")
        notify("Nexus download failed", f"HTTP {e.code} for mod {mod} file {file} (link expired? wrong key?)")
        raise SystemExit(1)
    if not links:
        notify("Nexus download failed", "API returned no download links")
        raise SystemExit("no links")
    name = info.get("file_name") or Path(urllib.parse.urlparse(links[0]["URI"]).path).name
    size_mb = (info.get("size_kb") or 0) / 1024
    dl = DOWNLOADS.get(game, DEFAULT_DL / game)
    dl.mkdir(parents=True, exist_ok=True)
    dest = dl / name
    log(f"downloading {name} ({size_mb:,.0f} MB) via {links[0].get('short_name')}")
    notify("Nexus download started", f"{info.get('name') or name} ({size_mb:,.0f} MB)")
    try:
        download(links[0]["URI"], dest)
    except Exception as e:  # noqa: BLE001
        log(f"download failed: {e}")
        notify("Nexus download failed", str(e))
        raise SystemExit(1)
    log(f"saved {dest}")
    if game == "skyrimspecialedition" and SKYMOD.exists():
        r = subprocess.run(["/usr/bin/python3", str(SKYMOD), "install", "--nexus", str(mod)],
                           capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        log(out)
        if r.returncode == 0:
            notify("Skyrim mod installed", info.get("name") or name)
        else:
            tail = [ln for ln in out.splitlines() if ln.strip()][-1:] or ["see ~/Library/Logs/nxm-handler.log"]
            notify("Downloaded, not installed", tail[0])
    else:
        notify("Nexus download finished", str(dest))


if __name__ == "__main__":
    main()
