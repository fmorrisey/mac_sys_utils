# nexus_nxm_handler

Makes the **Mod Manager Download** button on nexusmods.com work on a Mac that
has no Vortex / Mod Organizer: the browser hands the `nxm://` link to a tiny
AppleScript app, which runs `nxm-fetch.py` in the background. The script asks
the Nexus API for the real download URL, saves the archive under `~/Games`, and
for Skyrim SE immediately runs `../skyrim_mods/skymod.py install --nexus <id>`
so the mod is installed by the time the notification pops. Free Nexus accounts
work: the `key`/`expires` pair in the link authorises the download, the API key
only identifies you.

```
./install.sh            # ~/Applications/NXM Handler.app + ~/.local/bin/nxm-fetch.py, registered for nxm://
./install.sh --key      # prompts for your personal API key and stores it in the login Keychain
nxm-fetch.py --check    # validates the stored key
nxm-fetch.py --batch [--dry-run]   # Premium accounts only: fetch every mods.json entry with a file_id, then install
./uninstall.sh
```

One-time setup
1. https://next.nexusmods.com/settings/api-keys → *Personal API Key* → Generate.
2. In Terminal (not through a chat tool, so the key stays out of logs):
   `./install.sh --key` and paste it.
3. On a mod page: Files → **Mod Manager Download** (free accounts get the
   slow-download countdown first). Firefox asks once which app should open
   `nxm` links: choose **NXM Handler** and tick *Always*.

Where files go
- `skyrimspecialedition` → `~/Games/Skyrim Mods/downloads/` (what skymod scans)
- any other game → `~/Games/Nexus Downloads/<game>/`
- log: `~/Library/Logs/nxm-handler.log`

Notes
- The app is `LSUIElement`, so it never shows in the Dock or steals focus from
  a full-screen game. You only see macOS notifications: started, installed, or
  "downloaded, not installed" with the reason (FOMOD archive needing include
  rules, Skyrim wrapper currently running, mod not in the manifest).
- Links expire a few minutes after Nexus issues them; the handler uses them
  immediately, so this only matters if the Mac was asleep.
- Default-handler registration uses `LSSetDefaultHandlerForURLScheme`; if macOS
  refuses, the browser's one-time "open with" prompt does the same job.

Free vs Premium
- Free account: the API refuses `download_link.json` without the `key`/`expires`
  pair that only the website's Mod Manager Download button produces
  (HTTP 403 "this is for premium users only"). So each file is one click on the
  site; the handler does everything after the click.
- Premium account: `nxm-fetch.py --batch` pulls the whole manifest with no
  browser at all (file ids live in `skyrim_mods/mods.json`), at full speed.
