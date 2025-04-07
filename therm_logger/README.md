# 🖥️ Mac Thermal Logger & Analyzer

This is a simple, effective CLI tool to monitor and analyze your Mac's thermal performance over time.

Perfect for diagnosing issues like `kernel_task` CPU spikes, thermal throttling, or sluggish performance under dev-heavy workflows (Docker, VSCode, Spotify, Chrome, etc.).

## 🔧 What It Does
- Logs thermal data using `pmset` and `top`
- Captures CPU throttling & kernel_task load
- Automatically analyzes the log with Python when you stop the script
- Outputs warnings, CPU usage, and summary stats
- Optional: exports to CSV for long-term tracking

## 📦 Requirements
- macOS (tested on Intel MBP)
- Python 3+
- Bash

## 🚀 Quick Start

```bash
chmod +x log_thermals.sh
./log_thermals.sh
# Press Ctrl+C when you're done. It auto-runs the parser.
