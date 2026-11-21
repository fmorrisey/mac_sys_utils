# 🖥️ mac_sys_utils

A lightweight collection of command-line tools and scripts for monitoring, diagnosing, and optimizing macOS system performance — on Apple Silicon (M1–M5) and Intel MacBooks, from dev-heavy workloads to Wine/GPTK gaming.

- [Therm_Logger](/mac_therm_logger/README.md): logs thermal pressure, fan RPM, die temperatures, clock speeds and power (Apple Silicon via `powermetrics`) or `CPU_Speed_Limit`/`kernel_task` (Intel), plus what was running — then summarizes every throttling episode. Perfect for "is it throttling, and why?"
- [Wifi_Autoswitch](/wifi_autoswitch/README.md): turns Wi-Fi **off** the moment any wired Ethernet link (Thunderbolt dock, USB adapter) comes up with an IP, and back **on** when it goes away. Event-driven Swift LaunchAgent: no polling, no sudo, port-agnostic, and a manual Wi-Fi toggle sticks until the next plug/unplug.
- [HDMI_Audio_Stereo](/hdmi_audio_stereo/README.md): keeps a TV / soundbar HDMI audio endpoint at a **consistent channel count (default 5.1)** and re-applies your Configure-Speakers assignment every time the display is plugged in or blinks, so surround channels stop landing in the wrong speakers. Event-driven Swift LaunchAgent; `--target 2` for TV-speaker nights; reversible, no sudo.
- [Display_Mode](/display_mode/README.md): keeps the TV on the mode you want on every plug-in. Event-driven Swift LaunchAgent with a preference list (default 2560x1440 @ 120 non-HiDPI, then the best the TV offers), a guard that waits for a running Wine game to quit, and a notification when the TV came up with its cut-down EDID (nothing above 60 Hz at 1440p) so you know a TV power-cycle is the only fix left. Also a CLI to list and switch modes by id.
- [Skyrim_Mods](/skyrim_mods/README.md): manifest-driven mod installer for Skyrim SE under Wine (no Mod Organizer on the Mac side). Tracks every file each mod wrote so installs are reversible, generates `Plugins.txt` load order, swaps Steam's Play button to the SKSE loader, and knows the 1.7.104 / SKSE 2.3.1 rules.
- [Nexus_NXM_Handler](/nexus_nxm_handler/README.md): makes Nexus Mods' **Mod Manager Download** button work without Vortex: an `nxm://` handler app fetches the archive through the Nexus API (free accounts fine) and hands it to Skyrim_Mods, which installs it and notifies you. No Dock icon, never steals focus from a game.

## ⚙️ Requirements

![Shell Script](https://img.shields.io/badge/script-bash-blue)
![Python 3](https://img.shields.io/badge/python-3.8%2B-yellow)
![Swift](https://img.shields.io/badge/swift-5%2B-orange)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)


## 🛠️ Setup

```bash
git clone https://github.com/fmorrisey/mac_sys_utils.git
cd mac_sys_utils
chmod +x mac_therm_logger/mac_therm_logger.sh
./mac_therm_logger/mac_therm_logger.sh      # Apple Silicon asks for sudo once (powermetrics)
./wifi_autoswitch/install.sh                  # builds + installs the Wi-Fi/Ethernet LaunchAgent (needs Xcode CLT)
./hdmi_audio_stereo/install.sh                # builds + installs the HDMI-audio-stereo LaunchAgent (needs Xcode CLT)
./display_mode/install.sh                     # builds + installs the display-mode LaunchAgent (needs Xcode CLT)
./skyrim_mods/skymod.py status                # Skyrim SE mod installer: what is installed / downloaded / missing
./nexus_nxm_handler/install.sh --key          # nxm:// handler app + Nexus API key in Keychain (needs Xcode CLT)
```
