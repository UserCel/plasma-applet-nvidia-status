# NVIDIA Status
<img src="screenshot.png" width="500" alt="NVIDIA Status Screenshot">
<img src="screenshot2.png" width="250" alt="NVIDIA Status Screenshot 2">

KDE Plasma 6 widget for monitoring NVIDIA GPU power state and active processes.

## Features
- **GPU Status**: Monitor `Suspended` or `Active` power states via sysfs.
- **Process Tracking**: List applications using the GPU with SM and Memory usage percentages.
- **Power Efficient**: Only calls `nvidia-smi` when the GPU is already active to prevent accidental wake-ups.
- **Dynamic Discovery**: Automatically locates `nvidia-smi` in standard and local bin paths.
- **Persistent Header**: Optional pinning to keep the popup open and shortcut to settings.

## Requirements
- KDE Plasma 6
- NVIDIA Proprietary Driver
- `nvidia-smi` (for process list)

## Installation
### From Source
1. Clone the repository:
   ```bash
   git clone https://github.com/UserCel/plasma-applet-nvidia-status.git
   ```
2. Install the widget:
   ```bash
   kpackagetool6 -t Plasma/Applet -i package/
   ```
   *To update an existing installation:*
   ```bash
   kpackagetool6 -t Plasma/Applet -u package/
   ```

## Configuration
- **PCI Address**: Automatically detected, but can be manually set if necessary.
- **Polling Interval**: Adjustable from settings (default: 3 seconds).
- **Appearance**: Customizable colors for different power states and toggleable panel text.

## License
GPL-3.0-or-later
