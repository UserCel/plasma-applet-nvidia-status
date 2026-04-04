# NVIDIA Status
<img src="screenshot.png" width="500" alt="NVIDIA Status Screenshot">
<img src="screenshot2.png" width="250" alt="NVIDIA Status Screenshot 2">

A premium KDE Plasma 6 widget to monitor your NVIDIA dGPU power state and active processes at a glance.

## 🚀 Key Features

- **Real-time Status Monitoring**: Instantly see if your GPU is `Suspended (D3cold)` or `Active (D0)`.
- **Advanced Process Tracking**: Displays all applications currently using the GPU, including their **GPU Load (SM %)** and **Memory Usage (%)**.
- **No-Wake Guardian**: Intelligent monitoring that never wakes up your GPU. It only queries detailed process info if the card is already active.
- **Robust Tool Discovery**: Automatically finds `nvidia-smi` in system paths and local user directories (`~/.local/bin/`).
- **Premium UI**: Features a modern, aligned process list, a persistent "Pin" toggle, and a quick-access Settings button.
- **Lightweight & Efficient**: Uses standard Linux `sysfs` for status monitoring, resulting in near-zero CPU overhead.
- **Plasma 6 Ready**: Optimized for the latest KDE environment and modern icon themes.

## 📋 Requirements

- **Hardware**: NVIDIA GPU with support for RTD3 power management.
- **Software**: 
  - KDE Plasma 6
  - NVIDIA proprietary driver
  - `kpackagetool6` (for installation)
  - `nvidia-smi` (for process monitoring)

## 🛠️ Installation

### From Source
1. Clone the repository:
   ```bash
   git clone https://github.com/UserCel/plasma-applet-nvidia-status.git
   ```
2. Install or Update the widget:
   ```bash
   # Use -i to install for the first time
   kpackagetool6 -t Plasma/Applet -i package/
   
   # Use -u to update an existing installation
   kpackagetool6 -t Plasma/Applet -u package/
   ```
3. Add the **NVIDIA Status** widget to your panel or desktop.

## ⚙️ Configuration

1. Right-click the widget and select **Configure NVIDIA Status...**.
2. **GPU Detection**: Your card should be automatically detected. If not, click **Detect** or manually enter the PCI ID (e.g., `0000:01:00.0`).
3. **Appearance**: Customize the status colors (Active, Suspended, Resuming) and toggle the text visibility in the panel.
4. **Interval**: Adjust the polling frequency (default 3s).

## 📄 License
Distributed under the **GPL-3.0-or-later** License. See `LICENSE` for more information.
