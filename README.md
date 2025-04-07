# 🖥️ mac_sys_utils

A lightweight collection of command-line tools and scripts for monitoring, diagnosing, and optimizing macOS system performance — especially for Intel-based MacBooks under heavy development workloads.

- [Therm_Logger](/mac_therm_logger/README.md): Perfect for diagnosing issues like `kernel_task` CPU spikes, thermal throttling, or sluggish performance under dev-heavy workflows (Docker, VSCode, Spotify, Chrome, etc.).

## ⚙️ Requirements

- macOS (tested on Intel MBP, Sonoma)
- Python 3+
- Bash shell
- Optional: [Mac Fan Control](https://crystalidea.com/macs-fan-control) or [iStat Menus](https://bjango.com/mac/istatmenus/) for advanced fan/temp monitoring

## 🛠️ Setup

```bash
git clone https://github.com/yourusername/mac_sys_utils.git
cd mac_sys_utils
chmod +x log_thermals.sh
