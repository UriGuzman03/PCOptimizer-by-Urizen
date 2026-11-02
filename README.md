# PCOptimizer-by-Urizen
<div align="center">

# ⚡ PC Optimizer Pro
### *The Ultimate Windows Debloating & Performance Utility for Gamers*

[![GitHub release](https://img.shields.io/badge/version-3.5.4-red.svg)](https://github.com/UriGuzman03/PCOptimizer-by-Urizen/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)](https://github.com/UriGuzman03/PCOptimizer-by-Urizen)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

**PC Optimizer** is a lightweight, powerful, and safe open-source tool designed to squeeze every last drop of performance out of your hardware. Built specifically for gamers and power users who want to eliminate micro-stutters, reduce input lag, and maximize FPS without messing around with complicated registry tweaks manually.

---

## 🔥 Key Features for Maximum Gaming Performance

* **🎮 Gaming & Performance Tweaks:** Unlock hidden system potential with *Ultimate Performance* power plans, enable Windows Game Mode, activate HAGS (Hardware-Accelerated GPU Scheduling), and reduce network throttling for lower ping.
* **🧹 Intelligent Debloat:** Strip away resource-hogging background apps, telemetry, preinstalled Xbox features, and sponsored bloatware that drain your CPU and RAM.
* **🧠 Real-Time RAM & Memory Manager:** Instantly free up active working sets and purge Windows Standby Lists to keep your memory clean during heavy gaming sessions.
* **⚡ One-Click Optimization Profile:** Instantly apply pre-configured, battle-tested settings tailored specifically for high FPS gaming[cite: 1].
* **🛡️ Built-in Safety:** Automatically creates a Windows System Restore Point before applying any changes so you can always roll back safely[cite: 1].

---

## 🚀 Quick Start (How to Run)

You can run **PC Optimizer** instantly via PowerShell without needing to manually install bulky software. Open **PowerShell as Administrator** and run the following command[cite: 1]:

```powershell
Invoke-WebRequest -Uri "[https://raw.githubusercontent.com/UriGuzman03/PCOptimizer-by-Urizen/main/PCOptimizer.exe](https://raw.githubusercontent.com/UriGuzman03/PCOptimizer-by-Urizen/main/PCOptimizer.exe)" -OutFile "$env:TEMP\PCOptimizer.exe"; Start-Process "$env:TEMP\PCOptimizer.exe"
