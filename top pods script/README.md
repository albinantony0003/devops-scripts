# Top Pods Script

A PowerShell script for monitoring the CPU usage of newly created Kubernetes pods during their warmup period. It tracks CPU millicores over the first 5 minutes of a pod's lifecycle, shows trends (↑, ↓, →), and logs the profile to a CSV file.

## Features
- **Live Monitoring**: Continuously polls new pods in a specified namespace given a label selector.
- **Visual Trends**: Highlights high CPU usage in Red/Yellow/Green and indicates CPU consumption trends.
- **CSV Profiling**: Automatically saves the warmup profile of the pods to a timestamped CSV file (`warmup_profile_<timestamp>.csv`), which includes timestamp, pod name, cpu_millicores, delta, trend, age, and status.

## Prerequisites
- Windows PowerShell or PowerShell Core.
- `kubectl` configured and authenticated to the target Kubernetes cluster.

## Usage
1. Open `script.ps1`.
2. Update the following variables at the top of the script according to your environment:
   - `$NAMESPACE = "your-namespace"`
   - `$SELECTOR  = "app=your-app"`
   - `$INTERVAL  = 10` (Poll interval in seconds)
3. Run the script:
   ```powershell
   .\script.ps1
   ```
4. The script will run continuously until stopped, outputting live metrics to the console and saving data to the CSV file.
