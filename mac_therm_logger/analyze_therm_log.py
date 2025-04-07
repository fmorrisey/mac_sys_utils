import re
from datetime import datetime
import statistics
import csv
import sys



# Path to your therm log
TODAY = datetime.now().strftime("%Y-%m-%d")
# LOG_FILE = f'log/mac_therm_log_{TODAY}.log'
LOG_FILE = sys.argv[1] if len(sys.argv) > 1 else f'log/mac_therm_log_{TODAY}.log'
CSV_OUTPUT = "mac_therm_log_summary.csv"
print(f"Processing log file: {LOG_FILE}")


# Prepare containers
entries = []
kernel_usages = []
warnings = []

# Pattern matchers
timestamp_pattern = re.compile(r"^=== (.+) ===$")
kernel_pattern = re.compile(r"kernel_task\s+([\d\.]+)")
thermal_warn_pattern = re.compile(r"thermal warning level has been recorded")
performance_warn_pattern = re.compile(r"performance warning level has been recorded")

with open(LOG_FILE, "r") as f:
    lines = f.readlines()

current_entry = {}
for line in lines:
    timestamp_match = timestamp_pattern.match(line)
    kernel_match = kernel_pattern.search(line)

    if timestamp_match:
        # Save old entry if exists
        if current_entry:
            entries.append(current_entry)
            current_entry = {}

        timestamp_str = timestamp_match.group(1)
        try:
            current_entry["timestamp"] = datetime.strptime(timestamp_str, "%a %b %d %H:%M:%S %Z %Y")
        except ValueError:
            current_entry["timestamp"] = timestamp_str  # fallback
    elif kernel_match:
        cpu_usage = float(kernel_match.group(1))
        current_entry["kernel_task_cpu"] = cpu_usage
        kernel_usages.append(cpu_usage)
    elif "No thermal warning level has been recorded" not in line and "thermal warning level has been recorded" in line:
        current_entry["thermal_warning"] = True
        warnings.append(("thermal", current_entry.get("timestamp")))
    elif "No performance warning level has been recorded" not in line and "performance warning level has been recorded" in line:
        current_entry["performance_warning"] = True
        warnings.append(("performance", current_entry.get("timestamp")))


# Append last entry
if current_entry:
    entries.append(current_entry)

# Generate summary
print("📊 THERMAL LOG SUMMARY")
print(f"Entries parsed: {len(entries)}")
print(f"Avg kernel_task CPU: {statistics.mean(kernel_usages):.2f}%")
print(f"Max kernel_task CPU: {max(kernel_usages):.2f}%")
print(f"Thermal or performance warnings: {len(warnings)}")

for w_type, ts in warnings:
    print(f"⚠️  {w_type.title()} warning at {ts}")

# # Optional CSV export
# with open(CSV_OUTPUT, "w", newline="") as csvfile:
#     writer = csv.DictWriter(csvfile, fieldnames=["timestamp", "kernel_task_cpu", "thermal_warning", "performance_warning"])
#     writer.writeheader()
#     for entry in entries:
#         writer.writerow(entry)

# print(f"✅ CSV exported to: {CSV_OUTPUT}")
