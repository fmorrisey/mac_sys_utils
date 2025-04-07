# 🖥️ Mac Thermal Logger & Analyzer

This is a simple, effective CLI tool to monitor and analyze your Mac's thermal performance over time.

Perfect for diagnosing issues like `kernel_task` CPU spikes, thermal throttling, or sluggish performance under dev-heavy workflows (Docker, VSCode, Spotify, Chrome, etc.).

** Pro-Tip: Take your mac to the Genius Bar and have them clean our your mac's fans

## 🔧 What It Does
- Logs thermal data using `pmset` and `top`
- Captures CPU throttling & kernel_task load
- Automatically analyzes the log with Python when you stop the script
- Outputs warnings, CPU usage, and summary stats
- Optional: exports to CSV for long-term tracking

## 📦 Requirements
![Shell Script](https://img.shields.io/badge/script-bash-blue)
![Python 3](https://img.shields.io/badge/python-3.8%2B-yellow)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

## 🚀 Quick Start

```bash
chmod +x mac_therm_logger.sh
./mac_therm_logger.sh
# Press Ctrl+C when you're done. It auto-runs the parser.
```

## 📝 Sample Log

```log
=== Sun Apr  6 20:50:47 CDT 2025 ===
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
2025-04-06 20:50:47 -0500 CPU Power notify
	CPU_Scheduler_Limit 	= 100
	CPU_Available_CPUs 	= 12
	CPU_Speed_Limit 	= 100
0      kernel_task      0.0 
-----------------------------
```
