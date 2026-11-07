# 🖥️ mac_sys_utils

A lightweight collection of command-line tools and scripts for monitoring, diagnosing, and optimizing macOS system performance — on Apple Silicon (M1–M5) and Intel MacBooks, from dev-heavy workloads to Wine/GPTK gaming.

- [Therm_Logger](/mac_therm_logger/README.md): logs thermal pressure, fan RPM, die temperatures, clock speeds and power (Apple Silicon via `powermetrics`) or `CPU_Speed_Limit`/`kernel_task` (Intel), plus what was running — then summarizes every throttling episode. Perfect for "is it throttling, and why?"
- [Wifi_Autoswitch](/wifi_autoswitch/README.md): turns Wi-Fi **off** the moment any wired Ethernet link (Thunderbolt dock, USB adapter) comes up with an IP, and back **on** when it goes away. Event-driven Swift LaunchAgent: no polling, no sudo, port-agnostic, and a manual Wi-Fi toggle sticks until the next plug/unplug.

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
```
