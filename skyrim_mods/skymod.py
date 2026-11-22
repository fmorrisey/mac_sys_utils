#!/usr/bin/env python3
"""skymod — manifest-driven mod installer for Skyrim SE running under Wine on macOS.

There is no Mod Organizer / Vortex on the Mac side, so mods are installed as loose
files straight into the game's Data folder. This script makes that safe:

  * mods.json lists every mod, in install/load order, with the archive it ships in
  * each install records the files it wrote (state/<id>.json) so it can be removed
  * files that existed before and belong to nobody are backed up and restored on uninstall
  * Plugins.txt is generated from the manifest order (`*Name.esp` = enabled)

Commands
  status                  what is installed, which archives are waiting, game/SKSE versions
  inspect ARCHIVE|ID      show an archive's folder tree so you can write its include rules
  install ID [ID...]      install one or more mods (or --all for every mod whose archive is present)
  uninstall ID [ID...]    remove a mod's files (and restore what it overwrote)
  plugins                 (re)write Plugins.txt from the manifest order
  verify                  check that every recorded file is still there
  order [--dry-run]       restore the manifest's overwrite order after installing a mod out of sequence
  res [WxH|auto]          show or set the game resolution in SkyrimPrefs.ini (no launcher dialog with SKSE); auto = match the display

Only standard library + /usr/bin/bsdtar (reads .7z/.zip/.rar). Python 3.9+.
"""
import argparse
import fnmatch
import re
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA_MARKERS = {"textures", "meshes", "interface", "scripts", "skse", "sound", "strings", "seq",
                "music", "shadersfx", "grass", "lodsettings", "facegendata", "dyndolod", "video"}
PLUGIN_EXT = (".esp", ".esm", ".esl")
ARCHIVE_EXT = (".7z", ".zip", ".rar")
JUNK = {".ds_store", "__macosx", "thumbs.db"}
DOC_EXT = (".txt", ".md", ".url", ".pdf", ".html", ".htm", ".rtf", ".docx")


def expand(p):
    return Path(os.path.expandvars(os.path.expanduser(str(p))))


class Ctx:
    def __init__(self, manifest_path, force=False, verbose=False):
        self.manifest_path = Path(manifest_path)
        self.m = json.loads(self.manifest_path.read_text())
        cfg = self.m["config"]
        self.game = expand(cfg["game_dir"])
        self.data = self.game / "Data"
        self.plugins_txt = expand(cfg["plugins_txt"])
        self.state = expand(cfg["state_dir"])
        self.downloads = [expand(d) for d in cfg.get("downloads", [])]
        self.wrapper_patterns = cfg.get("running_patterns", [])
        self.force = force
        self.verbose = verbose
        self.mods = self.m["mods"]
        self.by_id = {x["id"]: x for x in self.mods}
        (self.state / "backup").mkdir(parents=True, exist_ok=True)

    # ---------- state ----------
    def state_file(self, mid):
        return self.state / f"{mid}.json"

    def installed(self, mid):
        return self.state_file(mid).exists()

    def read_state(self, mid):
        return json.loads(self.state_file(mid).read_text()) if self.installed(mid) else None

    def owners(self):
        """rel path -> list of mod ids that wrote it (manifest order)."""
        own = {}
        for mod in self.mods:
            st = self.read_state(mod["id"])
            if st:
                for f in st["files"]:
                    own.setdefault(f.lower(), []).append(mod["id"])
        return own

    # ---------- archives ----------
    def find_archive(self, mod):
        pats = mod.get("archive", [])
        if isinstance(pats, str):
            pats = [pats]
        # Nexus names archives either "Name-<modid>-<ver>-<ts>.7z" (old) or "Name <modid> <ver> <date> <hash>.7z" (2026+)
        idre = re.compile(r"(^|[^0-9])%s([^0-9]|$)" % mod["nexus"]) if mod.get("nexus") else None
        hits = []
        for d in self.downloads:
            if not d.is_dir():
                continue
            for f in d.iterdir():
                if f.suffix.lower() not in ARCHIVE_EXT:
                    continue
                if pats:
                    ok = any(fnmatch.fnmatch(f.name.lower(), p.lower()) for p in pats)
                else:
                    ok = bool(idre and idre.search(f.stem))
                if ok:
                    hits.append(f)
        hits.sort(key=lambda f: f.stat().st_mtime, reverse=True)
        return hits[0] if hits else None

    def extract(self, archive, dest):
        r = subprocess.run(["/usr/bin/bsdtar", "-xf", str(archive), "-C", str(dest)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sz = shutil.which("7zz") or shutil.which("7z")
            if sz:
                r = subprocess.run([sz, "x", "-y", f"-o{dest}", str(archive)], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"extract failed for {archive.name}:\n{r.stderr.strip()}\n"
                             "(rar5 archives need `brew install sevenzip`)")

    # ---------- guards ----------
    def check_not_running(self):
        if not self.wrapper_patterns or self.force:
            return
        for pat in self.wrapper_patterns:
            r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
            if r.returncode == 0:
                raise SystemExit(f"a Skyrim wrapper is running (pgrep -f '{pat}' matched). Quit Steam in the wrapper first, or use --force.")


def walk_files(root):
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name.lower() not in JUNK and "__macosx" not in [q.lower() for q in p.parts]:
            yield p


def detect_data_root(root):
    """Return the directory inside an extracted archive that corresponds to Skyrim's Data folder."""
    cands = [root, root / "Data", root / "data"]
    kids = [k for k in root.iterdir() if k.name.lower() not in JUNK]
    if len(kids) == 1 and kids[0].is_dir():
        cands += [kids[0], kids[0] / "Data", kids[0] / "data"]
    for c in cands:
        if not c.is_dir():
            continue
        names = {k.name.lower() for k in c.iterdir()}
        if names & DATA_MARKERS or any(n.endswith(PLUGIN_EXT) or n.endswith(".bsa") for n in names):
            return c
    return None


def tree(root, depth=2, max_lines=120):
    lines = []
    root = Path(root)
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if len(rel.parts) > depth:
            continue
        if p.name.lower() in JUNK:
            continue
        if p.is_dir():
            n = sum(1 for _ in p.rglob("*") if _.is_file())
            lines.append("  " * (len(rel.parts) - 1) + f"{p.name}/  ({n} files)")
        elif len(rel.parts) <= depth:
            lines.append("  " * (len(rel.parts) - 1) + p.name)
        if len(lines) >= max_lines:
            lines.append("  …")
            break
    return "\n".join(lines)


def plan(ctx, mod, root):
    """Return list of (src Path, dest rel-to-game-dir str)."""
    out = []
    rules = mod.get("include")
    if not rules:
        droot = detect_data_root(root)
        if droot is None:
            raise SystemExit(f"{mod['id']}: could not find a Data root in the archive; run `inspect` and add include rules")
        rules = [{"from": str(droot.relative_to(root)) if droot != root else "", "to": "Data"}]
    for rule in rules:
        if rule.get("from_marker"):
            hit = next((q for q in root.rglob("*") if q.name.lower() == rule["from_marker"].lower()), None)
            if hit is None:
                raise SystemExit(f"{mod['id']}: marker file {rule['from_marker']} not in archive\n{tree(root)}")
            src = hit.parent
        else:
            src = root / rule.get("from", "") if rule.get("from") else root
        to = rule.get("to", "Data").strip("/")
        excl = [e.lower() for e in rule.get("exclude", [])]
        if not src.exists():
            raise SystemExit(f"{mod['id']}: include path not in archive: {rule.get('from')}\n{tree(root)}")
        files = [src] if src.is_file() else list(walk_files(src))
        for f in files:
            rel = f.relative_to(src if src.is_dir() else src.parent)
            parts = [x.lower() for x in rel.parts]
            if "fomod" in parts or parts[0] in ("docs", "bashtags", "readme", "readmes"):
                continue  # installer metadata and documentation, never game data
            if len(parts) == 1 and f.suffix.lower() in DOC_EXT:
                continue
            if any(fnmatch.fnmatch(str(rel).lower(), e) or fnmatch.fnmatch(f.name.lower(), e) for e in excl):
                continue
            if to.lower() == "data" and len(rel.parts) > 1 and rel.parts[0].lower() == "data":
                rel = Path(*rel.parts[1:])  # option folder that nests its own Data/ directory
            dest = str(Path(to) / rel) if to else str(rel)
            out.append((f, dest))
    return out


def cmd_status(ctx, args):
    exe = ctx.game / "SkyrimSE.exe"
    ver = "?"
    if exe.exists():
        d = exe.read_bytes()
        i = d.find(b"\xbd\x04\xef\xfe")
        if i > 0:
            import struct
            ms, ls = struct.unpack_from("<II", d, i + 8)
            ver = f"{ms >> 16}.{ms & 0xffff}.{ls >> 16}.{ls & 0xffff}"
    print(f"game dir : {ctx.game}\ngame exe : SkyrimSE.exe {ver}")
    skse = sorted(ctx.game.glob("skse64_*.dll"))
    print(f"SKSE     : {', '.join(p.name for p in skse) if skse else 'not installed'}")
    launcher = ctx.game / "SkyrimSELauncher.exe"
    bk = ctx.state / "backup" / "skse" / "SkyrimSELauncher.exe"
    if launcher.exists():
        print(f"launcher : {'SKSE loader (swapped; original backed up)' if bk.exists() else 'stock Bethesda launcher'}")
    print(f"plugins  : {ctx.plugins_txt}")
    print(f"downloads: {', '.join(str(d) for d in ctx.downloads)}\n")
    w = max(len(m["id"]) for m in ctx.mods)
    for mod in ctx.mods:
        st = ctx.read_state(mod["id"])
        arc = ctx.find_archive(mod)
        if st:
            s = f"INSTALLED  {len(st['files']):5d} files  {st.get('archive', '')}"
        elif arc:
            s = f"ready      archive: {arc.name}"
        else:
            s = "missing    " + (f"https://www.nexusmods.com/skyrimspecialedition/mods/{mod['nexus']}?tab=files" if mod.get("nexus") else mod.get("url", ""))
            if mod.get("pick"):
                s += f"\n  {'':<{w}}             pick: {mod['pick']}"
        flag = "" if mod.get("enabled", True) else " (disabled in manifest)"
        print(f"  {mod['id']:<{w}}  {s}{flag}")


def tree_from_listing(archive, depth=2, max_lines=120):
    """Fast tree from `bsdtar -tf` (no extraction): directories with recursive file counts, files up to `depth`."""
    r = subprocess.run(["/usr/bin/bsdtar", "-tf", str(archive)], capture_output=True, text=True)
    if r.returncode != 0:
        return None, []
    counts, files, plugins = {}, [], set()
    for line in r.stdout.splitlines():
        if not line or line.endswith("/"):
            continue
        parts = line.split("/")
        if parts[-1].lower() in JUNK:
            continue
        if parts[-1].lower().endswith(PLUGIN_EXT):
            plugins.add(parts[-1])
        for i in range(1, len(parts)):
            counts["/".join(parts[:i])] = counts.get("/".join(parts[:i]), 0) + 1
        if len(parts) <= depth:
            files.append(line)
    lines = []
    for d in sorted(counts):
        if d.count("/") < depth:
            lines.append("  " * d.count("/") + f"{d.split('/')[-1]}/  ({counts[d]} files)")
    for f in sorted(files):
        lines.append("  " * f.count("/") + f.split("/")[-1])
    if len(lines) > max_lines:
        lines = lines[:max_lines] + ["  …"]
    return "\n".join(lines), sorted(plugins)


def cmd_inspect(ctx, args):
    target = args.target
    p = Path(target)
    if not p.exists():
        mod = ctx.by_id.get(target)
        if not mod:
            raise SystemExit(f"no such file or mod id: {target}")
        p = ctx.find_archive(mod)
        if not p:
            raise SystemExit(f"{target}: archive not found in downloads")
    listing, plugins = tree_from_listing(p, depth=args.depth)
    if listing is not None and not args.extract:
        print(f"{p.name}  (listing only; add --extract to test Data-root detection)\n" + listing)
        if plugins:
            print("plugins in archive: " + ", ".join(plugins))
        return
    with tempfile.TemporaryDirectory(dir=ctx.state) as td:
        ctx.extract(p, Path(td))
        print(f"{p.name}\n" + tree(td, depth=args.depth))
        dr = detect_data_root(Path(td))
        print(f"\nauto-detected Data root: {dr.relative_to(td) if dr else 'NONE (needs include rules)'}")
        plugins = [q.name for q in Path(td).rglob("*") if q.suffix.lower() in PLUGIN_EXT]
        if plugins:
            print("plugins in archive: " + ", ".join(sorted(set(plugins))))


def post_install(ctx, mod, st):
    if mod.get("post") == "skse_launcher_swap":
        loader = ctx.game / "skse64_loader.exe"
        launcher = ctx.game / "SkyrimSELauncher.exe"
        bdir = ctx.state / "backup" / "skse"
        bdir.mkdir(parents=True, exist_ok=True)
        bk = bdir / "SkyrimSELauncher.exe"
        if not loader.exists():
            print("  ! skse64_loader.exe not found; launcher swap skipped")
            return
        if not bk.exists() and launcher.exists():
            shutil.copy2(launcher, bk)
        shutil.copy2(loader, launcher)
        st["launcher_swapped"] = True
        print("  launcher swap: SkyrimSELauncher.exe is now the SKSE loader (Steam's Play button launches SKSE)")


def undo_post(ctx, mod, st):
    if st.get("launcher_swapped"):
        bk = ctx.state / "backup" / "skse" / "SkyrimSELauncher.exe"
        if bk.exists():
            shutil.copy2(bk, ctx.game / "SkyrimSELauncher.exe")
            bk.unlink()
            print("  launcher swap undone (stock launcher restored)")


def cmd_install(ctx, args):
    ctx.check_not_running()
    explicit = False
    if args.all:
        mods = [m for m in ctx.mods if m.get("enabled", True)]
    elif getattr(args, "nexus", None):
        want = {str(n) for n in args.nexus}
        mods = [m for m in ctx.mods if str(m.get("nexus")) in want]
        if not mods:
            raise SystemExit(f"no manifest entry with nexus id {', '.join(sorted(want))}; the archive stays in downloads")
    else:
        explicit = True
        mods = []
        for mid in args.ids:
            if mid not in ctx.by_id:
                raise SystemExit(f"unknown mod id {mid}")
            mods.append(ctx.by_id[mid])
    if not mods:
        raise SystemExit("give mod ids, --nexus ID or --all")
    failures = []
    for mod in mods:
        try:
            _install_one(ctx, mod, args, explicit)
        except SystemExit as e:
            if len(mods) == 1:
                raise
            failures.append(mod["id"])
            print(f"{mod['id']}: FAILED - {e}")
    cmd_plugins(ctx, args)
    if failures:
        raise SystemExit("failed: " + ", ".join(failures))


def _install_one(ctx, mod, args, explicit):
    mid = mod["id"]
    arc = ctx.find_archive(mod)
    st_old = ctx.read_state(mid)
    if st_old and not args.reinstall:
        if arc and arc.name != st_old.get("archive"):
            print(f"{mid}: new archive {arc.name} (was {st_old.get('archive')}), reinstalling")
        else:
            print(f"{mid}: already installed (use --reinstall)")
            return
    if not arc:
        if explicit:
            raise SystemExit(f"archive not found in {[str(d) for d in ctx.downloads]}")
        print(f"{mid}: archive not downloaded yet, skipped")
        return
    if st_old:
        _uninstall_one(ctx, mod)
    print(f"{mid}: installing from {arc.name}")
    owners = ctx.owners()
    with tempfile.TemporaryDirectory(dir=ctx.state) as td:
        ctx.extract(arc, Path(td))
        items = plan(ctx, mod, Path(td))
        st = {"id": mid, "archive": arc.name, "installed_at": time.strftime("%Y-%m-%d %H:%M:%S"),
              "files": [], "backups": [], "overwrote": []}
        bdir = ctx.state / "backup" / mid
        written = set()
        for src, dest in items:
            target = ctx.game / dest
            if dest.lower() in written:
                shutil.copy2(src, target)  # later option folder overrides an earlier one from the same archive
                continue
            written.add(dest.lower())
            if target.exists():
                if dest.lower() in owners:
                    st["overwrote"].append(dest)
                else:
                    b = bdir / dest
                    b.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(target, b)
                    st["backups"].append(dest)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
            st["files"].append(dest)
            if ctx.verbose:
                print("   ", dest)
        if mod.get("plugins") == "auto":
            st["plugins"] = [Path(d).name for d in st["files"]
                             if Path(d).parent.name.lower() == "data" and d.lower().endswith(PLUGIN_EXT)]
        post_install(ctx, mod, st)
        ctx.state_file(mid).write_text(json.dumps(st, indent=1))
    print(f"  {len(st['files'])} files written, {len(st['overwrote'])} overwrote other mods, {len(st['backups'])} vanilla files backed up")


def _uninstall_one(ctx, mod):
    mid = mod["id"]
    st = ctx.read_state(mid)
    if not st:
        print(f"{mid}: not installed")
        return
    owners = ctx.owners()
    removed = kept = 0
    for dest in st["files"]:
        others = [o for o in owners.get(dest.lower(), []) if o != mid]
        target = ctx.game / dest
        if others:
            kept += 1  # another mod also provides this file; leave the file (it holds the last writer's version)
            continue
        if target.exists():
            target.unlink()
            removed += 1
        b = ctx.state / "backup" / mid / dest
        if b.exists():
            shutil.copy2(b, target)
    for dest in sorted({str(Path(d).parent) for d in st["files"]}, key=len, reverse=True):
        d = ctx.game / dest
        while d != ctx.game and d != ctx.data and d.is_dir() and not any(d.iterdir()):
            d.rmdir()
            d = d.parent
    undo_post(ctx, mod, st)
    shutil.rmtree(ctx.state / "backup" / mid, ignore_errors=True)
    ctx.state_file(mid).unlink()
    print(f"{mid}: removed {removed} files, left {kept} shared with other mods, restored {len(st['backups'])} originals")


def cmd_uninstall(ctx, args):
    ctx.check_not_running()
    for mid in args.ids:
        mod = ctx.by_id.get(mid)
        if not mod:
            raise SystemExit(f"unknown mod id {mid}")
        _uninstall_one(ctx, mod)
    cmd_plugins(ctx, args)


def cmd_plugins(ctx, args):
    header = ["# This file is used by Skyrim to keep track of your downloaded content.",
              "# Please do not modify this file."]
    managed = []
    for mod in ctx.mods:
        if ctx.installed(mod["id"]):
            plist = mod.get("plugins", [])
            if plist == "auto":
                plist = ctx.read_state(mod["id"]).get("plugins", [])
            for p in plist:
                if (ctx.data / p).exists():
                    managed.append(p)
                else:
                    print(f"  ! {mod['id']}: plugin {p} not found in Data, not listed")
    existing = []
    if ctx.plugins_txt.exists():
        for line in ctx.plugins_txt.read_text(errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            name = s.lstrip("*")
            if name.lower() not in {m.lower() for m in managed} and (ctx.data / name).exists():
                existing.append(s)  # e.g. Creations enabled from the in-game menu; keep them first
    lines = header + existing + [f"*{p}" for p in managed]
    ctx.plugins_txt.parent.mkdir(parents=True, exist_ok=True)
    ctx.plugins_txt.write_text("\r\n".join(lines) + "\r\n")
    print(f"Plugins.txt: {len(existing)} kept + {len(managed)} managed plugins -> {ctx.plugins_txt}")
    for p in managed:
        print("   *" + p)


def cmd_order(ctx, args):
    """Find files where a mod EARLIER in the manifest was installed AFTER a later mod that also provides the
    file (so the wrong copy is on top), and reinstall the later mods to restore the intended overwrite order."""
    sts = {m["id"]: ctx.read_state(m["id"]) for m in ctx.mods}
    sts = {k: v for k, v in sts.items() if v}
    order = [m["id"] for m in ctx.mods]
    owners = {}
    for mid, st in sts.items():
        for f in st["files"]:
            owners.setdefault(f.lower(), []).append(mid)
    fix = {}
    for mid, st in sts.items():
        for f in st["files"]:
            for o in owners[f.lower()]:
                if o != mid and order.index(o) > order.index(mid) and st["installed_at"] > sts[o]["installed_at"]:
                    fix.setdefault(o, []).append((f, mid))
    if not fix:
        print("overwrite order is consistent"); return
    for o, fs in fix.items():
        print(f"  {o}: {len(fs)} files currently shadowed by earlier mods (e.g. {fs[0][0]} from {fs[0][1]})")
    ids = [o for o in order if o in fix]
    if args.dry_run:
        print("would reinstall:", ", ".join(ids)); return
    args.ids, args.all, args.nexus, args.reinstall = ids, False, None, True
    cmd_install(ctx, args)
    # reinstalling a mod can shadow a mod later than it in turn; repeat until nothing is left to fix
    passes = getattr(args, "_passes", 0) + 1
    if passes < 4:
        args._passes = passes
        cmd_order(ctx, args)


def cmd_verify(ctx, args):
    bad = 0
    for mod in ctx.mods:
        st = ctx.read_state(mod["id"])
        if not st:
            continue
        missing = [f for f in st["files"] if not (ctx.game / f).exists()]
        print(f"  {mod['id']}: {len(st['files']) - len(missing)}/{len(st['files'])} files present")
        for f in missing[:10]:
            print("     missing", f)
        bad += len(missing)
    sys.exit(1 if bad else 0)


def cmd_res(ctx, args):
    """Set the game resolution in SkyrimPrefs.ini (the Bethesda launcher is replaced by the SKSE loader, so this is the knob)."""
    import re
    ini = expand(ctx.m["config"].get("prefs_ini", "~/Documents/My Games/Skyrim Special Edition/SkyrimPrefs.ini"))
    if subprocess.run(["pgrep", "-f", "SkyrimSE[.]exe"], capture_output=True).returncode == 0 and not ctx.force:
        raise SystemExit("Skyrim is running and rewrites SkyrimPrefs.ini on exit; quit it first (or --force to write anyway)")
    s = ini.read_text(encoding="utf-8", errors="surrogateescape")
    if args.size is None:
        w = re.search(r"(?m)^iSize W=(\d+)", s); h = re.search(r"(?m)^iSize H=(\d+)", s)
        b = re.search(r"(?m)^bBorderless=(\d)", s); f = re.search(r"(?m)^bFull Screen=(\d)", s)
        print(f"{w.group(1) if w else '?'}x{h.group(1) if h else '?'}  borderless={b.group(1) if b else '?'} fullscreen={f.group(1) if f else '?'}  ({ini})")
        return
    if args.size == "auto":
        dm = Path.home() / ".local/bin/display-mode"
        out = subprocess.run([str(dm)], capture_output=True, text=True).stdout if dm.exists() else ""
        cur = re.search(r"CURRENT:\s+io=\d+\s+(\d+)x(\d+)", out)
        if not cur:
            raise SystemExit("could not read the current display mode (is display-mode installed?)")
        args.size = f"{cur.group(1)}x{cur.group(2)}"
        print(f"display is {args.size}")
    m = re.match(r"^(\d+)x(\d+)$", args.size)
    if not m:
        raise SystemExit("give WxH (e.g. 3440x1440) or 'auto' to match the connected display")
    w, h = m.group(1), m.group(2)
    bak = ini.with_name(ini.name + ".bak-" + time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(ini, bak)
    s, n1 = re.subn(r"(?m)^iSize W=\d+", f"iSize W={w}", s)
    s, n2 = re.subn(r"(?m)^iSize H=\d+", f"iSize H={h}", s)
    if args.borderless is not None:
        # true borderless window = bBorderless=1 AND bFull Screen=0; with both at 1 Wine does a fullscreen
        # modeset and lands the desk monitor on 60 Hz for the session
        s = re.sub(r"(?m)^bBorderless=\d", f"bBorderless={1 if args.borderless else 0}", s)
        s = re.sub(r"(?m)^bFull Screen=\d", f"bFull Screen={0 if args.borderless else 1}", s)
    if not (n1 and n2):
        raise SystemExit("iSize W/H not found in " + str(ini))
    with open(ini, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(s)
    print(f"resolution set to {w}x{h} in {ini} (backup {bak.name})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=str(HERE / "mods.json"))
    ap.add_argument("--force", action="store_true", help="skip the 'wrapper is running' guard")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    i = sub.add_parser("inspect"); i.add_argument("target"); i.add_argument("--depth", type=int, default=2); i.add_argument("--extract", action="store_true", help="extract instead of listing (slow, tests auto-detection)"); i.set_defaults(fn=cmd_inspect)
    s = sub.add_parser("install"); s.add_argument("ids", nargs="*"); s.add_argument("--all", action="store_true"); s.add_argument("--nexus", nargs="+", help="select by Nexus mod id"); s.add_argument("--reinstall", action="store_true"); s.set_defaults(fn=cmd_install)
    u = sub.add_parser("uninstall"); u.add_argument("ids", nargs="+"); u.set_defaults(fn=cmd_uninstall)
    sub.add_parser("plugins").set_defaults(fn=cmd_plugins)
    r = sub.add_parser("res", help="show or set the game resolution (WxH) in SkyrimPrefs.ini"); r.add_argument("size", nargs="?"); r.add_argument("--borderless", type=int, choices=[0, 1], default=None); r.set_defaults(fn=cmd_res)
    sub.add_parser("verify").set_defaults(fn=cmd_verify)
    o = sub.add_parser("order", help="reinstall later mods whose files were shadowed by a mod installed afterwards"); o.add_argument("--dry-run", action="store_true"); o.set_defaults(fn=cmd_order)
    args = ap.parse_args()
    try:
        os.nice(10)  # never compete with a running game for CPU
    except OSError:
        pass
    ctx = Ctx(args.manifest, force=args.force, verbose=args.verbose)
    args.fn(ctx, args)


if __name__ == "__main__":
    main()
