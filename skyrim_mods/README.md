# skyrim_mods

Manifest-driven mod installer for Skyrim Special Edition running under Wine
(Porting Kit / Wineskin wrappers in `/Applications/Ported Games`). There is no
Mod Organizer or Vortex on the Mac side, so mods go in as loose files; this
script keeps that reversible and keeps the plugin load order in one place.

```
./skymod.py status                 # game + SKSE version, which mods are installed / downloaded / missing
./skymod.py inspect ID|ARCHIVE     # folder tree of an archive from its listing, instant (--extract to test auto-detection)
./skymod.py install ID ...         # or --all, or --nexus <modid> (what the nxm handler calls)
./skymod.py uninstall ID ...       # removes the mod's files, restores anything it overwrote
./skymod.py plugins                # rewrite Plugins.txt from the manifest order
./skymod.py verify                 # every recorded file still present?
./skymod.py res [WxH|auto]         # game resolution in SkyrimPrefs.ini; the SKSE swap removes the launcher's Options dialog
```

Downloads are looked for in `~/Games/Skyrim Mods/downloads` and `~/Downloads`
(Nexus archives are matched by the `-<modid>-` in their filename, so the files
can keep their original names). Install state lives in `~/Games/Skyrim Mods/state`
(one JSON per mod + backups of overwritten originals), not in this repo.

## Where things are in this install

| thing | path |
|---|---|
| game folder (shared by both wrappers; the DXVK wrapper's copy is a symlink) | `Steambuild 32 64bit Metal.app/.../steamapps/common/Skyrim Special Edition` |
| the game runs in | `Steambuild 32 64bit DXVK.app` (D3DMetal crashes it, see memory) |
| `Plugins.txt` (load order, `*` = enabled) | `Steambuild 32 64bit DXVK.app/.../drive_c/users/Wineskin/AppData/Local/Skyrim Special Edition/` |
| `Skyrim.ini`, `SkyrimPrefs.ini`, `SkyrimCustom.ini`, saves | `~/Documents/My Games/Skyrim Special Edition/` (the prefix maps Documents to the Mac home) |

## SKSE under Steam-in-Wine

Steam's Play button runs `SkyrimSELauncher.exe`. The `skse` entry's post step
backs that file up and replaces it with `skse64_loader.exe`, so Play launches
SKSE. `uninstall skse` puts the stock launcher back. A game update from Steam
will also put it back (and break SKSE until a matching build exists).

The display-mode agent runs `skymod.py res auto` after every display change, so
the game resolution follows the TV (2560x1440) or the desk ultrawide (3440x1440)
by itself; it cannot write while Skyrim is running (the game rewrites the INI on
exit), so it applies at the next launch.

## Game version 1.7.104 (August 2026 update)

Bethesda shipped 1.7.104 on 2026-08-27. Consequences:

- SKSE 2.3.1 is the matching build and is distributed only via Nexus now.
- Address Library needs the "All in One (1.7.104.0)" file, v13 or newer.
- Any mod that ships a `.dll` in `SKSE/Plugins` must have a 1.7.104 build.
  Engine Fixes 7.0.21 (GitHub) does; many others do not yet. The manifest
  deliberately contains no other DLL mods. Script/ESP/texture mods are
  version-independent.

## Manifest fields

`id`, `name`, `nexus` (mod id), `file_id` (the file the batch downloader fetches),
`pick` (human hint shown by `status`), `archive` (filename globs; without it the
Nexus id is matched as a standalone number in the filename), `include` (list of
`{"from": "<folder in archive>" | "from_marker": "<file>", "to": "Data" | "",
"exclude": [globs]}`; without it the Data root is auto-detected), `plugins`
(list of esp/esm/esl names in load order, or `"auto"` to take whatever landed at
the Data root), `post` (`skse_launcher_swap`), `enabled`, `notes`.

Downloading: `nexus_nxm_handler` feeds single files (Mod Manager Download button)
or, with a Premium account, `nxm-fetch.py --batch` fetches every `file_id` and
then runs `install --all`.

## Adding a mod

1. Add an entry to `mods.json` in load-order position: `id`, `name`, `nexus`
   (mod id), `plugins` (esp/esm/esl names, in the order they should load).
2. Download the archive (manual download on Nexus, "slow download" is fine).
3. `./skymod.py inspect <id>`. If it says it found a Data root, go ahead. If the
   archive is a FOMOD installer with option folders (`00 Core`, `01 ...`), add
   `include` rules: `{"from": "00 Core", "to": "Data"}` per folder you want.
4. `./skymod.py install <id>`. Plugins.txt is rewritten automatically.

Only standard library Python 3.9 + `/usr/bin/bsdtar` are needed. RAR5 archives
need `brew install sevenzip` (bsdtar reads 7z, zip and RAR4).
