import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras

PlasmoidItem {
    id: root

    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    hideOnWindowDeactivate: !Plasmoid.configuration.pinned

    Layout.minimumWidth: root.isOnDesktop ? Kirigami.Units.gridUnit * 18 : -1
    Layout.minimumHeight: root.isOnDesktop ? Kirigami.Units.gridUnit * 16 : -1

    // --- Properties ---
    property string status: "unknown"
    property string statusText: i18n("Checking...")
    property var lastUpdate: new Date()
    property string sortField: (plasmoid.configuration && plasmoid.configuration.sortField) || "sm"
    property bool sortDescending: plasmoid.configuration && plasmoid.configuration.sortDescending !== undefined ? plasmoid.configuration.sortDescending : true
    property bool allowProcessTermination: plasmoid.configuration && plasmoid.configuration.allowProcessTermination !== undefined ? plasmoid.configuration.allowProcessTermination : true
    property bool showProcessIcons: plasmoid.configuration && plasmoid.configuration.showProcessIcons !== undefined ? plasmoid.configuration.showProcessIcons : true
    property var steamAppMap: ({})
    property string userHome: ""
    property double vramUsedMb: 0
    property double vramTotalMb: 0
    property int gpuTemp: 0
    property var gpuPowerDraw: null
    readonly property double vramPercent: vramTotalMb > 0 ? Math.min(100, Math.max(0, (vramUsedMb / vramTotalMb) * 100)) : 0
    property var processHistory: ({})
    property var rawGpuProcesses: []
    property var gpuProcesses: sortProcesses(rawGpuProcesses, sortField, sortDescending)
    property string nvidiaSmiPath: ""
    property bool hasNvidiaSmi: nvidiaSmiPath !== ""
    // Scope every nvidia-smi call to the configured card, so that on a multi-GPU
    // system each instance of the widget reports its own GPU instead of the
    // aggregate of all of them. nvidia-smi takes the PCI bus id in -i directly.
    // Note: for pmon the flag must come after the subcommand.
    readonly property string smiTarget: {
        const addr = root.configuredPciAddress;
        return addr ? " -i " + addr : "";
    }
    readonly property string getProcessCmd: root.buildProcessCmd(root.nvidiaSmiPath, root.configuredPciAddress)
    property bool showGpuModel: plasmoid.configuration && plasmoid.configuration.showGpuModel !== undefined ? plasmoid.configuration.showGpuModel : true
    property string gpuModelName: ""
    property string detectedPciAddress: ""
    readonly property string rawConfiguredPciAddress: (plasmoid.configuration && plasmoid.configuration.pciAddress) ? root.normalizePciAddress(plasmoid.configuration.pciAddress) : "0000:01:00.0"
    readonly property string configuredPciAddress: root.detectedPciAddress || root.rawConfiguredPciAddress || "0000:01:00.0"
    readonly property string shortPciAddress: {
        const addr = root.configuredPciAddress;
        return addr.replace(/^0000:/, "");
    }
    readonly property string cardDisplayName: (root.showGpuModel && root.gpuModelName) ? (root.gpuModelName + " (" + root.shortPciAddress + ")") : ("GPU (" + root.shortPciAddress + ")")
    readonly property string fuserCmd: root.buildFuserCmd(root.configuredPciAddress)
    property bool isBackingOff: false
    property var baselineFuserPids: []
    property int idleCooldownTicks: 0
    readonly property int maxCooldownTicks: 3
    property double lastSmiQueryTime: 0

    onRawConfiguredPciAddressChanged: {
        if (root.detectedPciAddress && root.detectedPciAddress !== root.rawConfiguredPciAddress) {
            root.detectedPciAddress = "";
        }
        root.refreshGpuIdentity();
    }

    onConfiguredPciAddressChanged: {
        const addr = root.configuredPciAddress;
        if (!addr) return;
        gpuStatusSource.disconnectSource("cat /sys/bus/pci/devices/" + addr + "/power/runtime_status");
        gpuStatusSource.connectSource("cat /sys/bus/pci/devices/" + addr + "/power/runtime_status");
        if (root.isViewActive && root.status === "active" && root.hasNvidiaSmi) {
            gpuProcessesSource.disconnectSource(root.getProcessCmd);
            gpuProcessesSource.connectSource(root.getProcessCmd);
        }
    }

    function normalizePciAddress(raw) {
        if (!raw) return "";
        let s = String(raw).trim().toLowerCase();
        s = s.split(/\s+/)[0].replace(/:$/, "");
        s = s.replace(/^([0-9a-f]{4,8}:[0-9a-f]{2})\.([0-9a-f]{2}\.[0-9a-f])$/, "$1:$2");
        s = s.replace(/^([0-9a-f]{2})\.([0-9a-f]{2}\.[0-9a-f])$/, "$1:$2");
        s = s.replace(/^0000([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f])$/, "$1");
        if (/^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$/.test(s)) {
            s = "0000:" + s;
        }
        return s;
    }

    function cleanGpuModelName(raw) {
        if (!raw) return "";
        return raw.replace(/^NVIDIA\s+/i, "")
                  .replace(/^GeForce\s+/i, "")
                  .replace(/\s+Laptop\s+GPU/i, "")
                  .replace(/\s+with\s+Max-Q\s+Design/i, " Max-Q")
                  .replace(/\s+Max-Q\s*\/\s*Mobile/i, "")
                  .replace(/\s+GPU$/i, "")
                  .trim();
    }

    function buildGpuDetectCmd(preferredAddr) {
        const addr = root.normalizePciAddress(preferredAddr) || "0000:01:00.0";
        return "addr=\"" + addr + "\"; " +
            "if [ ! -d \"/proc/driver/nvidia/gpus/$addr\" ] && [ ! -e \"/sys/bus/pci/drivers/nvidia/$addr\" ]; then " +
            "  for d in /proc/driver/nvidia/gpus/0000:* /sys/bus/pci/drivers/nvidia/0000:*; do " +
            "    if [ -e \"$d\" ]; then addr=$(basename \"$d\"); break; fi; " +
            "  done; " +
            "  if [ ! -d \"/proc/driver/nvidia/gpus/$addr\" ] && [ ! -e \"/sys/bus/pci/drivers/nvidia/$addr\" ]; then " +
            "    lspci_addr=$(lspci -d 10de:: -D 2>/dev/null | grep -E 'VGA|3D' | head -n 1 | awk '{print $1}'); " +
            "    [ -n \"$lspci_addr\" ] && addr=\"$lspci_addr\"; " +
            "  fi; " +
            "fi; " +
            "echo \"ADDR=$addr\"; " +
            "model=$(grep -s '^Model:' \"/proc/driver/nvidia/gpus/$addr/information\" 2>/dev/null | sed 's/Model:[ \\t]*//'); " +
            "[ -z \"$model\" ] && model=$(lspci -s \"$addr\" 2>/dev/null | sed -n 's/.*\\[\\(.*\\)\\].*/\\1/p'); " +
            "echo \"MODEL=$model\"";
    }

    function parseGpuDetectOutput(stdout) {
        const result = { address: "", model: "" };
        if (!stdout) return result;
        const lines = String(stdout).split(/\r?\n/);
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.indexOf("ADDR=") === 0) {
                result.address = root.normalizePciAddress(line.substring(5));
            } else if (line.indexOf("MODEL=") === 0) {
                result.model = root.cleanGpuModelName(line.substring(6));
            }
        }
        return result;
    }

    function refreshGpuIdentity() {
        const cmd = root.buildGpuDetectCmd(root.rawConfiguredPciAddress);
        gpuModelSource.disconnectSource(cmd);
        gpuModelSource.connectSource(cmd);
    }

    function buildProcessCmd(smiPath, pciAddr) {
        const addr = root.normalizePciAddress(pciAddr);
        const target = addr ? " -i " + addr : "";
        return smiPath + " pmon -c 1" + target + "; echo \"---PROCESSES---\"; " + smiPath + target + "; echo \"---TELEMETRY---\"; " + smiPath + target + " --query-gpu=memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits";
    }

    function buildFuserCmd(pciAddr) {
        const addr = root.normalizePciAddress(pciAddr) || "0000:01:00.0";
        return "dev=\"/dev/nvidia$(grep -s 'Device Minor:' /proc/driver/nvidia/gpus/" + addr + "/information 2>/dev/null | awk '{print $NF}')\"; [ -e \"$dev\" ] || dev=\"/dev/nvidia0\"; fuser \"$dev\" /dev/nvidiactl /dev/nvidia-modeset 2>/dev/null";
    }

    function parseTelemetryCsv(telemetryOut) {
        if (!telemetryOut) return null;
        const tFields = String(telemetryOut).trim().split(",");
        if (tFields.length < 3) return null;
        const usedMb = parseFloat(tFields[0].trim()) || 0;
        const totalMb = parseFloat(tFields[1].trim()) || 0;
        const tempC = parseInt(tFields[2].trim()) || 0;
        let powerW = null;
        if (tFields.length >= 4) {
            const rawPwr = tFields[3].trim();
            if (rawPwr && rawPwr !== "[N/A]" && !isNaN(parseFloat(rawPwr))) {
                powerW = Math.round(parseFloat(rawPwr) * 10) / 10;
            }
        }
        return { usedMb: usedMb, totalMb: totalMb, tempC: tempC, powerW: powerW };
    }

    function parseProcessData(pmonOut, smiOut, prevHistory) {
        const historyIn = prevHistory || {};
        // 1. Parse pmon data
        const pmonMap = {};
        const pmonLines = String(pmonOut || "").split("\n");
        for (let i = 2; i < pmonLines.length; i++) {
            const line = pmonLines[i].trim();
            if (!line || line.startsWith("#")) continue;
            const parts = line.split(/\s+/);
            if (parts.length >= 10) {
                const pid = parts[1];
                const type = parts[2];
                const sm = parts[3];
                const mem = parts[4];
                const name = parts.slice(9).join(" ").trim();
                if (name && name !== "-") {
                    pmonMap[pid] = { pid: pid, type: type, sm: sm, mem: mem, name: name };
                }
            }
        }

        // 2. Parse standard nvidia-smi process table data & overall GPU utilization
        let overallGpuUtil = null;
        const processMap = {};
        const smiLines = String(smiOut || "").split("\n");
        const procRegex = /\|\s*\d+\s+(?:N\/A|\d+)\s+(?:N\/A|\d+)\s+(\d+)\s+(\S+)\s+(.*?)\s+(\d+(?:\.\d+)?\s*(?:MiB|MB|GiB|GB))\s*\|/;

        for (let i = 0; i < smiLines.length; i++) {
            const line = smiLines[i];
            if (line.indexOf("MiB /") !== -1 || line.indexOf("GiB /") !== -1 || line.indexOf("MB /") !== -1) {
                const matchUtil = line.match(/\|\s*(\d+)%\s+(?:Default|Exclusive|Prohibited|Process)/);
                if (matchUtil) {
                    overallGpuUtil = parseFloat(matchUtil[1]);
                }
            }

            const match = line.match(procRegex);
            if (match) {
                const pid = match[1];
                const type = match[2];
                let name = match[3].trim();
                const vram = match[4].trim();

                if (name.lastIndexOf("\\") !== -1) {
                    name = name.substring(name.lastIndexOf("\\") + 1);
                } else if (name.lastIndexOf("/") !== -1) {
                    name = name.substring(name.lastIndexOf("/") + 1);
                }

                processMap[pid] = { pid: pid, type: type, name: name, vram: vram };
            }
        }

        // If smiOut didn't return process lines, fallback to pmon processes
        for (const pid in pmonMap) {
            if (!processMap[pid]) {
                processMap[pid] = {
                    pid: pid,
                    type: pmonMap[pid].type,
                    name: pmonMap[pid].name,
                    vram: pmonMap[pid].mem !== "-" ? pmonMap[pid].mem + "%" : "0 MB"
                };
            }
        }

        // Count active user processes
        let totalUserProcs = 0;
        for (const pid in processMap) {
            if (root.isUserProcess(processMap[pid])) {
                totalUserProcs++;
            }
        }

        // 3. Build merged process list with smoothing and overall GPU utilization fallback
        const newHistory = {};
        const finalProcesses = [];

        for (const pid in processMap) {
            const item = processMap[pid];
            const pmonItem = pmonMap[pid];

            let name = item.name;
            if (pmonItem && pmonItem.name && pmonItem.name.length > 0 && name.indexOf("...") !== -1) {
                name = pmonItem.name;
            }

            let rawSm = pmonItem ? pmonItem.sm : "-";
            let smVal = (rawSm === "-" || rawSm === undefined) ? null : parseFloat(rawSm);
            if (isNaN(smVal)) smVal = null;

            const key = pid;
            const prev = historyIn[key];

            let smGrace = 0;

            if (smVal !== null && smVal > 0) {
                smGrace = 0;
            } else if (prev && prev.sm > 0 && prev.smGrace < 30) {
                smVal = prev.sm;
                smGrace = prev.smGrace + 1;
            } else if (root.isUserProcess(item) && overallGpuUtil !== null && overallGpuUtil > 0) {
                smVal = (totalUserProcs > 1) ? Math.round(overallGpuUtil / totalUserProcs) : overallGpuUtil;
                smGrace = 0;
            }

            const finalSm = (smVal !== null && !isNaN(smVal)) ? smVal : 0;
            const finalMem = item.vram || (pmonItem && pmonItem.mem !== "-" ? pmonItem.mem + "%" : "0 MB");

            newHistory[key] = {
                sm: finalSm,
                smGrace: smGrace,
                vram: finalMem
            };

            finalProcesses.push({
                "pid": pid,
                "type": item.type,
                "sm": finalSm.toString(),
                "mem": finalMem,
                "name": name
            });
        }

        return {
            processes: finalProcesses,
            history: newHistory,
            overallGpuUtil: overallGpuUtil
        };
    }

    function formatVramMb(mb) {
        if (!mb || isNaN(mb)) return "0 MB";
        if (mb >= 1024) {
            return (mb / 1024).toFixed(2) + " GB";
        }
        return Math.round(mb) + " MB";
    }

    function isUserProcess(proc) {
        if (!proc) return false;
        const rawName = (proc.name || "").toLowerCase();
        let basename = rawName;
        const lastSlash = Math.max(rawName.lastIndexOf("/"), rawName.lastIndexOf("\\"));
        if (lastSlash !== -1) {
            basename = rawName.substring(lastSlash + 1);
        }

        if (basename === "kwin_wayland" || basename === "xwayland" || basename === "xorg" || basename === "systemd" || basename === "plasmashell" || basename === "kwin") {
            return false;
        }
        return true;
    }

    function resolveProcessIcon(procName) {
        if (!procName) return "application-x-executable";
        const rawName = (procName || "").toLowerCase().trim();
        let basename = rawName;
        const lastSlash = Math.max(rawName.lastIndexOf("/"), rawName.lastIndexOf("\\"));
        if (lastSlash !== -1) {
            basename = rawName.substring(lastSlash + 1);
        }
        if (basename.endsWith(".exe")) {
            basename = basename.substring(0, basename.length - 4);
        }
        if (basename.endsWith(".bin")) {
            basename = basename.substring(0, basename.length - 4);
        }
        if (basename.endsWith("-bin")) {
            basename = basename.substring(0, basename.length - 4);
        }

        const iconMap = {
            "firefox": "org.mozilla.firefox",
            "chrome": "com.google.Chrome",
            "google-chrome": "com.google.Chrome",
            "chromium": "org.chromium.Chromium",
            "brave": "com.brave.Browser",
            "edge": "msedge",
            "steam": "steam",
            "steamwebhelper": "steam",
            "blender": "org.blender.Blender",
            "obs": "com.obsproject.Studio",
            "obs64": "com.obsproject.Studio",
            "code": "com.visualstudio.code",
            "vscodium": "com.vscodium.codium",
            "discord": "com.discordapp.Discord",
            "spotify": "com.spotify.Client",
            "vlc": "org.videolan.VLC",
            "mpv": "io.mpv.Mpv",
            "gimp": "org.gimp.GIMP",
            "inkscape": "org.inkscape.Inkscape",
            "kwin_wayland": "kwin",
            "plasmashell": "plasma",
            "xwayland": "xorg",
            "xorg": "xorg",
            "alacritty": "alacritty",
            "kitty": "kitty",
            "konsole": "utilities-terminal",
            "heroic": "com.heroicgameslauncher.hgl",
            "lutris": "net.lutris.Lutris",
            "dolphin": "system-file-manager",
            "glxgears": "utilities-system-monitor",
            "vkmark": "utilities-system-monitor",
            "furmark": "preferences-system-performance",
            "gputest": "preferences-system-performance",
            "nvtop": "utilities-terminal",
            "htop": "utilities-terminal",
            "btop": "utilities-terminal"
        };

        if (iconMap[basename]) {
            return iconMap[basename];
        }

        const clean = basename.replace(/[^a-z0-9]/g, "");

        // 1. Check if direct extracted .exe icon exists in cache for Windows binaries
        if (rawName.endsWith(".exe") && root.userHome) {
            const cachePath = "file://" + root.userHome + "/.cache/nvidia_status_applet_icons/" + clean + ".png";
            return cachePath;
        }

        // 2. Check Steam appmanifest librarycache logo
        if (root.steamAppMap && root.steamAppMap[clean]) {
            const appId = root.steamAppMap[clean];
            if (root.userHome) {
                return "file://" + root.userHome + "/.local/share/Steam/appcache/librarycache/" + appId + "/logo.png";
            }
        }

        return basename;
    }

    function extractExeIcon(procName) {
        if (!procName || !root.showProcessIcons) return;
        const rawName = (procName || "").trim();
        if (!rawName.toLowerCase().endsWith(".exe")) return;
        
        let basename = rawName;
        const lastSlash = Math.max(rawName.lastIndexOf("/"), rawName.lastIndexOf("\\"));
        if (lastSlash !== -1) {
            basename = rawName.substring(lastSlash + 1);
        }
        const cleanName = basename.toLowerCase().replace(/[^a-z0-9]/g, "");
        if (!cleanName || !root.userHome) return;

        const iconPath = root.userHome + "/.cache/nvidia_status_applet_icons/" + cleanName + ".png";
        
        const cmd = "mkdir -p ~/.cache/nvidia_status_applet_icons && [ ! -f \"" + iconPath + "\" ] && " +
            "exePath=$(ps aux | grep -i \"" + basename + "\" | grep -o \"/.*" + basename + "\" | awk -F'waitforexitandrun ' '{print $NF}' | tail -n 1) && " +
            "[ -f \"$exePath\" ] && wrestool -x -t14 \"$exePath\" > /tmp/tmp_icon_" + cleanName + ".ico 2>/dev/null && " +
            "icotool -x -o /tmp/ /tmp/tmp_icon_" + cleanName + ".ico 2>/dev/null && " +
            "highestPng=$(ls -S /tmp/tmp_icon_" + cleanName + "*.png /tmp/*_*.png 2>/dev/null | head -n 1) && " +
            "[ -f \"$highestPng\" ] && cp \"$highestPng\" \"" + iconPath + "\" 2>/dev/null; " +
            "rm -f /tmp/tmp_icon_" + cleanName + "* /tmp/*_*.png 2>/dev/null";

        exeIconExtractorSource.disconnectSource(cmd);
        exeIconExtractorSource.connectSource(cmd);
    }

    function resolveProcessFallbackIcon(procName) {
        if (!procName) return "application-x-executable";
        const rawName = (procName || "").toLowerCase().trim();
        let basename = rawName;
        const lastSlash = Math.max(rawName.lastIndexOf("/"), rawName.lastIndexOf("\\"));
        if (lastSlash !== -1) {
            basename = rawName.substring(lastSlash + 1);
        }
        if (basename.endsWith(".exe")) {
            basename = basename.substring(0, basename.length - 4);
        }
        if (basename.endsWith(".bin")) {
            basename = basename.substring(0, basename.length - 4);
        }
        if (basename.endsWith("-bin")) {
            basename = basename.substring(0, basename.length - 4);
        }

        const clean = basename.replace(/[^a-z0-9]/g, "");
        if (root.steamAppMap && root.steamAppMap[clean]) {
            const appId = root.steamAppMap[clean];
            return "steam_icon_" + appId;
        }

        const fallbackMap = {
            "vlc": "vlc",
            "firefox": "firefox",
            "chrome": "google-chrome",
            "google-chrome": "google-chrome",
            "chromium": "chromium",
            "brave": "brave-browser",
            "obs": "obs",
            "obs64": "obs",
            "code": "vscode",
            "vscodium": "vscodium",
            "discord": "discord",
            "spotify": "spotify",
            "gimp": "gimp",
            "inkscape": "inkscape",
            "blender": "blender"
        };

        if (fallbackMap[basename]) {
            return fallbackMap[basename];
        }

        if (rawName.endsWith(".exe") || basename === "gamescope" || basename.startsWith("proton")) {
            return "steam";
        }
        if (basename.startsWith("wine")) {
            return "wine";
        }
        return "application-x-executable";
    }

    function killProcess(pid, force) {
        if (!pid) return;
        const cmd = force ? ("kill -9 " + pid) : ("kill " + pid);
        processActionSource.disconnectSource(cmd);
        processActionSource.connectSource(cmd);
    }

    function parseVramInMb(memStr) {
        if (!memStr) return 0;
        const str = memStr.toString().trim();
        const val = parseFloat(str);
        if (isNaN(val)) return 0;
        if (str.indexOf("GiB") !== -1 || str.indexOf("GB") !== -1) {
            return val * 1024;
        }
        return val;
    }

    function sortProcesses(procList, field, descending) {
        if (!procList || !procList.length) return [];
        const listCopy = procList.slice();
        listCopy.sort((a, b) => {
            let valA, valB;
            if (field === "name") {
                valA = (a.name || "").toLowerCase();
                valB = (b.name || "").toLowerCase();
                if (valA < valB) return descending ? 1 : -1;
                if (valA > valB) return descending ? -1 : 1;
                return 0;
            } else if (field === "mem") {
                valA = parseVramInMb(a.mem);
                valB = parseVramInMb(b.mem);
            } else { // "sm" / GPU usage (default)
                valA = parseFloat(a.sm) || 0;
                valB = parseFloat(b.sm) || 0;
            }
            if (valA === valB) {
                return (a.name || "").localeCompare(b.name || "");
            }
            return descending ? (valB - valA) : (valA - valB);
        });
        return listCopy;
    }

    property color statusColor: {
        const cfg = plasmoid.configuration;
        if (status === "active") return cfg.activeColor || "#76b900";
        if (status === "suspended") return cfg.suspendedColor || "#888888";
        if (status === "resuming" || status === "suspending") return cfg.resumingColor || "#3daee9";
        return cfg.unknownColor || "#ffaa00";
    }

    // --- Tooltip ---
    toolTipMainText: (root.showGpuModel && root.gpuModelName) ? (root.gpuModelName + " (" + root.shortPciAddress + ")") : i18n("NVIDIA GPU Status (%1)", root.shortPciAddress)
    toolTipSubText: i18n("Current State: %1", statusText)

    // --- Desktop / Panel Representation Helper ---
    readonly property bool isOnDesktop: Plasmoid.location === PlasmaCore.Types.Floating || Plasmoid.location === PlasmaCore.Types.Desktop || Plasmoid.formFactor === PlasmaCore.Types.Planar
    readonly property bool isViewActive: root.expanded || isOnDesktop

    // --- Representations ---
    preferredRepresentation: isOnDesktop ? fullRepresentation : compactRepresentation

    compactRepresentation: MouseArea {
        id: compactRoot
        
        readonly property bool isVertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        
        Layout.preferredWidth:  isVertical ? -1 : layout.implicitWidth
        Layout.preferredHeight: isVertical ? layout.implicitHeight : -1
        
        hoverEnabled: true

        onPressed: (mouse) => {}
        
        onClicked: (mouse) => {
            root.expanded = !root.expanded;
        }

        RowLayout {
            id: layout
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.alignment: Qt.AlignCenter
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium

                source: root.status === "active"
                    ? Qt.resolvedUrl("../assets/nvidia-active.svg")
                    : Qt.resolvedUrl("../assets/nvidia-suspended.svg")

                isMask: true
                color: root.statusColor
            }

            PlasmaComponents3.Label {
                visible: (plasmoid.configuration && plasmoid.configuration.showTextInCompact) || false
                text: root.statusText
                color: root.statusColor
                font.bold: true
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        id: fullRep
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        implicitWidth: Kirigami.Units.gridUnit * 22
        implicitHeight: Kirigami.Units.gridUnit * 20

        header: PlasmaExtras.PlasmoidHeading {
            contentHeight: headerLayout.implicitHeight
            RowLayout {
                id: headerLayout
                anchors.fill: parent
                PlasmaExtras.Heading {
                    Layout.fillWidth: true
                    text: i18n("NVIDIA Status")
                    level: 2
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "configure-symbolic"
                    display: PlasmaComponents3.ToolButton.IconOnly
                    PlasmaComponents3.ToolTip.text: i18n("Settings")
                    onClicked: Plasmoid.internalAction("configure").trigger()
                }
                PlasmaComponents3.ToolButton {
                    visible: !root.isOnDesktop
                    icon.name: "window-pin-symbolic"
                    display: PlasmaComponents3.ToolButton.IconOnly
                    checkable: true
                    checked: Plasmoid.configuration.pinned
                    PlasmaComponents3.ToolTip.text: checked ? i18n("Unpin") : i18n("Pin Open")
                    onToggled: Plasmoid.configuration.pinned = checked
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            // Dynamic Status Card & Telemetry
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    implicitWidth: Kirigami.Units.iconSizes.huge
                    implicitHeight: Kirigami.Units.iconSizes.huge
                    source: root.status === "active"
                        ? Qt.resolvedUrl("../assets/nvidia-active.svg")
                        : Qt.resolvedUrl("../assets/nvidia-suspended.svg")
                    isMask: true
                    color: root.statusColor
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        PlasmaComponents3.Label {
                            text: root.statusText
                            color: root.statusColor
                            font.bold: true
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
                        }

                        // Telemetry Badges (Temp & Power)
                        RowLayout {
                            visible: root.status === "active" && root.gpuTemp > 0
                            spacing: Kirigami.Units.smallSpacing

                            Rectangle {
                                implicitWidth: tempLabel.implicitWidth + Kirigami.Units.smallSpacing
                                implicitHeight: tempLabel.implicitHeight + Kirigami.Units.smallSpacing / 4
                                radius: 4
                                color: Kirigami.Theme.highlightColor
                                opacity: 0.15
                            }
                            PlasmaComponents3.Label {
                                id: tempLabel
                                text: "🌡️ " + root.gpuTemp + "°C"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.bold: true
                            }

                            PlasmaComponents3.Label {
                                text: "⚡ " + root.gpuPowerDraw + " W"
                                visible: root.gpuPowerDraw !== null
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.bold: true
                                opacity: 0.85
                            }
                        }
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents3.Label {
                            opacity: 0.8
                            font.bold: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: root.cardDisplayName
                            Layout.maximumWidth: root.width - Kirigami.Units.gridUnit * 10
                            elide: Text.ElideRight
                        }
                        PlasmaComponents3.Label {
                            opacity: 0.5
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: "• " + i18n("Updates every %1s", plasmoid.configuration.updateInterval)
                        }
                    }
                }
            }

            // Total VRAM Usage Bar (Active State)
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.status === "active" && root.vramTotalMb > 0
                spacing: Kirigami.Units.smallSpacing / 2

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents3.Label {
                        text: i18n("VRAM Allocation")
                        font.bold: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.8
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents3.Label {
                        text: root.formatVramMb(root.vramUsedMb) + " / " + root.formatVramMb(root.vramTotalMb) + " (" + root.vramPercent.toFixed(1) + "%)"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.bold: true
                    }
                }

                PlasmaComponents3.ProgressBar {
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    value: root.vramPercent
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // Process List Section
            ListView {
                id: processList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                headerPositioning: ListView.OverlayHeader
                header: Item {
                    id: headerItem
                    width: processList.width
                    height: Kirigami.Units.gridUnit * 1.5
                    visible: root.gpuProcesses.length > 0
                    
                    readonly property int colWidth: Kirigami.Units.gridUnit * 4.5
                    readonly property int actionWidth: Kirigami.Units.iconSizes.medium
                    readonly property int margin: Kirigami.Units.largeSpacing

                    function getSortIndicator(field) {
                        if (root.sortField !== field) return "";
                        return root.sortDescending ? " ▼" : " ▲";
                    }

                    // Memory Column Header
                    MouseArea {
                        id: headerMemArea
                        width: parent.colWidth
                        height: parent.height
                        anchors.right: parent.right
                        anchors.rightMargin: root.allowProcessTermination ? (parent.margin + parent.actionWidth + parent.margin) : parent.margin
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (plasmoid.configuration.sortField === "mem") {
                                plasmoid.configuration.sortDescending = !plasmoid.configuration.sortDescending;
                            } else {
                                plasmoid.configuration.sortField = "mem";
                                plasmoid.configuration.sortDescending = true;
                            }
                        }

                        PlasmaComponents3.Label { 
                            id: headerMem
                            text: i18n("Mem") + headerItem.getSortIndicator("mem")
                            font.bold: true
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter 
                            color: headerMemArea.containsMouse || root.sortField === "mem" ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        }
                    }

                    // GPU Column Header
                    MouseArea {
                        id: headerGpuArea
                        width: parent.colWidth
                        height: parent.height
                        anchors.right: headerMemArea.left
                        anchors.rightMargin: parent.margin
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (plasmoid.configuration.sortField === "sm") {
                                plasmoid.configuration.sortDescending = !plasmoid.configuration.sortDescending;
                            } else {
                                plasmoid.configuration.sortField = "sm";
                                plasmoid.configuration.sortDescending = true;
                            }
                        }

                        PlasmaComponents3.Label { 
                            id: headerGpu
                            text: i18n("GPU") + headerItem.getSortIndicator("sm")
                            font.bold: true
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter 
                            color: headerGpuArea.containsMouse || root.sortField === "sm" ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        }
                    }

                    // Process Name Column Header
                    MouseArea {
                        id: headerNameArea
                        height: parent.height
                        anchors.left: parent.left
                        anchors.leftMargin: parent.margin
                        anchors.right: headerGpuArea.left
                        anchors.rightMargin: parent.margin
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (plasmoid.configuration.sortField === "name") {
                                plasmoid.configuration.sortDescending = !plasmoid.configuration.sortDescending;
                            } else {
                                plasmoid.configuration.sortField = "name";
                                plasmoid.configuration.sortDescending = false;
                            }
                        }

                        PlasmaComponents3.Label { 
                            text: i18n("Process Name") + headerItem.getSortIndicator("name")
                            font.bold: true
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignLeft
                            elide: Text.ElideRight
                            color: headerNameArea.containsMouse || root.sortField === "name" ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        }
                    }
                }

                model: root.status === "active" ? root.gpuProcesses : []
                visible: root.hasNvidiaSmi && root.status === "active" && root.gpuProcesses.length > 0
                
                delegate: PlasmaComponents3.ItemDelegate {
                    id: delegateRoot
                    width: processList.width
                    height: Kirigami.Units.gridUnit * 2.5
                    
                    readonly property int colWidth: Kirigami.Units.gridUnit * 4.5
                    readonly property int margin: Kirigami.Units.largeSpacing

                    contentItem: Item {
                        Item {
                            id: killBtnContainer
                            anchors.right: parent.right
                            anchors.rightMargin: parent.parent.margin
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                            visible: root.allowProcessTermination

                            readonly property bool isUserProc: root.isUserProcess(modelData)

                            // For user processes: a real interactive ToolButton
                            PlasmaComponents3.ToolButton {
                                id: killBtn
                                anchors.fill: parent
                                icon.name: "process-stop-symbolic"
                                display: PlasmaComponents3.ToolButton.IconOnly
                                visible: killBtnContainer.isUserProc

                                PlasmaComponents3.ToolTip.text: i18n("Terminate or Force Kill %1 (PID: %2)", modelData.name, modelData.pid)

                                onClicked: processMenu.open()

                                PlasmaComponents3.Menu {
                                    id: processMenu

                                    PlasmaComponents3.MenuItem {
                                        text: i18n("Terminate (SIGTERM)")
                                        icon.name: "process-stop-symbolic"
                                        onTriggered: root.killProcess(modelData.pid, false)
                                    }

                                    PlasmaComponents3.MenuItem {
                                        text: i18n("Force Kill (SIGKILL)")
                                        icon.name: "edit-delete-symbolic"
                                        onTriggered: root.killProcess(modelData.pid, true)
                                    }
                                }
                            }

                            // For system processes: a static icon + hover area for tooltip
                            Item {
                                anchors.fill: parent
                                visible: !killBtnContainer.isUserProc

                                Kirigami.Icon {
                                    id: sysKillIcon
                                    anchors.centerIn: parent
                                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                    source: "process-stop-symbolic"
                                    isMask: true
                                    color: Kirigami.Theme.disabledTextColor
                                }

                                HoverHandler {
                                    id: sysKillHover
                                }

                                PlasmaComponents3.ToolTip {
                                    visible: sysKillHover.hovered
                                    text: i18n("System process (%1) cannot be terminated", modelData.name)
                                }
                            }
                        }

                        PlasmaComponents3.Label { 
                            id: dataMem
                            text: {
                                const m = (modelData.mem || "0").toString();
                                if (m.indexOf("B") !== -1 || m.indexOf("%") !== -1) return m;
                                return m + "%";
                            }
                            width: parent.parent.colWidth
                            anchors.right: root.allowProcessTermination ? killBtnContainer.left : parent.right
                            anchors.rightMargin: parent.parent.margin
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignHCenter 
                            color: root.parseVramInMb(modelData.mem) > 0 ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor 
                        }
                        PlasmaComponents3.Label { 
                            id: dataGpu
                            text: modelData.sm + "%"
                            width: parent.parent.colWidth
                            anchors.right: dataMem.left
                            anchors.rightMargin: parent.parent.margin
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignHCenter 
                            color: parseFloat(modelData.sm) > 0 ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor 
                        }
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            anchors.left: parent.left
                            anchors.leftMargin: parent.parent.margin
                            anchors.right: dataGpu.left
                            anchors.rightMargin: parent.parent.margin
                            anchors.verticalCenter: parent.verticalCenter

                            Kirigami.Icon {
                                visible: root.showProcessIcons
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                source: root.resolveProcessIcon(modelData.name)
                                fallback: root.resolveProcessFallbackIcon(modelData.name)
                                Layout.alignment: Qt.AlignVCenter
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                PlasmaComponents3.Label { 
                                    text: modelData.name
                                    font.bold: true
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight 
                                }
                                PlasmaComponents3.Label { 
                                    text: "PID: " + modelData.pid + " • " + modelData.type
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }

                PlasmaComponents3.Label {
                    anchors.centerIn: parent
                    text: i18n("No apps currently using GPU")
                    opacity: 0.5
                    visible: root.status === "active" && root.gpuProcesses.length === 0
                }
            }

            // Info Placeholders
            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !processList.visible
                icon.name: !root.hasNvidiaSmi ? "error-symbolic" : (root.status === "active" ? "utilities-system-monitor-symbolic" : "system-suspend-symbolic")
                text: !root.hasNvidiaSmi ? i18n("nvidia-smi Not Found") : (root.status === "active" ? i18n("GPU is Active") : i18n("GPU is Suspended"))
                explanation: !root.hasNvidiaSmi 
                    ? i18n("Check your NVIDIA driver installation.") 
                    : (root.status === "active" ? i18n("No active processes detected.") : i18n("Monitoring is paused to save power."))
            }
        }
    }

    // --- Data Source ---
    Plasma5Support.DataSource {
        id: processActionSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            if (root.isViewActive && root.status === "active" && root.hasNvidiaSmi) {
                root.isBackingOff = false;
                root.idleCooldownTicks = 0;
                root.baselineFuserPids = [];
                gpuProcessesSource.disconnectSource(root.getProcessCmd);
                gpuProcessesSource.connectSource(root.getProcessCmd);
            }
        }
    }

    Plasma5Support.DataSource {
        id: gpuStatusSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            const oldStatus = root.status;
            const result = data["stdout"] ? data["stdout"].trim() : "";
            root.status = result;
            root.lastUpdate = new Date();

            if (result === "suspended") {
                root.statusText = i18n("Suspended (D3cold)");
                root.processHistory = {};
                root.rawGpuProcesses = []; // Clear processes when suspended
                root.vramUsedMb = 0;
                root.vramTotalMb = 0;
                root.gpuTemp = 0;
                root.gpuPowerDraw = null;
                root.isBackingOff = false;
                root.idleCooldownTicks = 0;
                root.baselineFuserPids = [];
            } else if (result === "active") {
                root.statusText = i18n("Active (D0)");
                if (oldStatus !== "active" && root.isViewActive && root.hasNvidiaSmi) {
                    gpuProcessesSource.disconnectSource(root.getProcessCmd);
                    gpuProcessesSource.connectSource(root.getProcessCmd);
                }
            } else if (result === "resuming") {
                root.statusText = i18n("Resuming...");
            } else if (result === "suspending") {
                root.statusText = i18n("Suspending...");
            } else {
                root.statusText = result || i18n("Unknown");
            }
            disconnectSource(sourceName);
        }
    }

    Plasma5Support.DataSource {
        id: gpuProcessesSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            const stdout = data["stdout"] || "";
            // Handle Discovery
            if (sourceName.indexOf("p in") !== -1 || sourceName.indexOf("which") !== -1) {
                const discoveredPath = stdout.trim();
                if (discoveredPath.length > 0) {
                    root.nvidiaSmiPath = discoveredPath;
                    if (root.isViewActive && root.status === "active") {
                        gpuProcessesSource.disconnectSource(root.getProcessCmd);
                        gpuProcessesSource.connectSource(root.getProcessCmd);
                    }
                }
            } else {
                const partsOut = stdout.split("---TELEMETRY---");
                const mainOut = partsOut[0] || "";
                const telemetryOut = (partsOut[1] || "").trim();

                const tParsed = root.parseTelemetryCsv(telemetryOut);
                if (tParsed) {
                    root.vramUsedMb = tParsed.usedMb;
                    root.vramTotalMb = tParsed.totalMb;
                    root.gpuTemp = tParsed.tempC;
                    root.gpuPowerDraw = tParsed.powerW;
                }

                const procParts = mainOut.split("---PROCESSES---");
                const pmonOut = procParts[0] || "";
                const smiOut = procParts[1] || "";

                const parsedProcs = root.parseProcessData(pmonOut, smiOut, root.processHistory);
                const finalProcesses = parsedProcs.processes;

                let userProcCount = 0;
                for (let i = 0; i < finalProcesses.length; i++) {
                    if (root.isUserProcess(finalProcesses[i])) {
                        userProcCount++;
                        root.extractExeIcon(finalProcesses[i].name);
                    }
                }

                if (userProcCount === 0) {
                    root.isBackingOff = true;
                    root.idleCooldownTicks = 0;
                    fuserBaselineSnapshotSource.disconnectSource(root.fuserCmd);
                    fuserBaselineSnapshotSource.connectSource(root.fuserCmd);
                } else {
                    root.isBackingOff = false;
                    root.idleCooldownTicks = 0;
                    root.baselineFuserPids = [];
                }

                root.processHistory = parsedProcs.history;
                root.rawGpuProcesses = finalProcesses;
            }
            disconnectSource(sourceName);
        }
    }

    Plasma5Support.DataSource {
        id: exeIconExtractorSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            // Trigger process array reference refresh so Kirigami.Icon re-evaluates file:// image source
            root.rawGpuProcesses = root.rawGpuProcesses;
        }
    }

    Plasma5Support.DataSource {
        id: steamAppsSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            const stdout = data["stdout"] || "";
            const lines = stdout.split("\n");
            const map = {};
            let currentAppId = "";
            let currentName = "";

            for (let i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                if (line.startsWith("HOME=")) {
                    root.userHome = line.substring(5).trim();
                } else if (line.startsWith('"appid"')) {
                    const parts = line.split('"');
                    if (parts.length >= 4) currentAppId = parts[3];
                } else if (line.startsWith('"name"')) {
                    const parts = line.split('"');
                    if (parts.length >= 4) currentName = parts[3];
                } else if (line.startsWith('"installdir"')) {
                    const parts = line.split('"');
                    if (parts.length >= 4) {
                        const installDir = parts[3];
                        if (currentAppId) {
                            const cName = currentName.toLowerCase().replace(/[^a-z0-9]/g, "");
                            const cDir = installDir.toLowerCase().replace(/[^a-z0-9]/g, "");
                            if (cName) map[cName] = currentAppId;
                            if (cDir) map[cDir] = currentAppId;
                        }
                    }
                }
            }
            root.steamAppMap = map;
            disconnectSource(sourceName);
        }
    }

    Plasma5Support.DataSource {
        id: gpuModelSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            const parsed = root.parseGpuDetectOutput(data["stdout"] || "");
            root.gpuModelName = parsed.model || "";
            if (parsed.address) {
                root.detectedPciAddress = parsed.address;
                if (plasmoid.configuration && (!plasmoid.configuration.pciAddress || root.normalizePciAddress(plasmoid.configuration.pciAddress) === "0000:01:00.0") && parsed.address !== "0000:01:00.0") {
                    plasmoid.configuration.pciAddress = parsed.address;
                }
            }
        }
    }

    Component.onCompleted: {
        // Resolve valid NVIDIA PCI address and fetch GPU model passively from sysfs/proc (zero wake)
        root.refreshGpuIdentity();
        // Search in common system paths, user path, and then system-wide which
        gpuProcessesSource.connectSource("for p in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi ~/.local/bin/nvidia-smi; do [ -x \"$p\" ] && echo \"$p\" && exit 0; done; which nvidia-smi");
        steamAppsSource.connectSource("echo \"HOME=$HOME\"; grep -hE '\"appid\"|\"name\"|\"installdir\"' ~/.local/share/Steam/steamapps/appmanifest_*.acf ~/.steam/root/steamapps/appmanifest_*.acf ~/.steam/steam/steamapps/appmanifest_*.acf 2>/dev/null");
    }

    Plasma5Support.DataSource {
        id: fuserBaselineSnapshotSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            const stdout = (data["stdout"] || "").trim();
            root.baselineFuserPids = stdout ? stdout.split(/\s+/).filter(Boolean) : [];
        }
    }

    Plasma5Support.DataSource {
        id: fuserSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName);
            const stdout = (data["stdout"] || "").trim();
            const currentPids = stdout ? stdout.split(/\s+/).filter(Boolean) : [];

            let hasNewPid = false;
            for (let i = 0; i < currentPids.length; i++) {
                if (root.baselineFuserPids.indexOf(currentPids[i]) === -1) {
                    hasNewPid = true;
                    break;
                }
            }

            if (hasNewPid) {
                // A new process opened the dGPU! Immediately exit backoff and trigger nvidia-smi
                root.isBackingOff = false;
                root.idleCooldownTicks = 0;
                root.baselineFuserPids = [];
                if (root.isViewActive && root.status === "active" && root.hasNvidiaSmi) {
                    gpuProcessesSource.disconnectSource(root.getProcessCmd);
                    gpuProcessesSource.connectSource(root.getProcessCmd);
                }
            } else {
                root.idleCooldownTicks++;
                if (root.idleCooldownTicks >= root.maxCooldownTicks) {
                    // Grace window completed: GPU is still active (e.g. external display / desktop GPU)
                    // Resume regular nvidia-smi polling!
                    root.isBackingOff = false;
                    root.idleCooldownTicks = 0;
                    root.baselineFuserPids = [];
                    if (root.isViewActive && root.status === "active" && root.hasNvidiaSmi) {
                        gpuProcessesSource.disconnectSource(root.getProcessCmd);
                        gpuProcessesSource.connectSource(root.getProcessCmd);
                    }
                }
            }
        }
    }

    // Refresh processes when expanded
    onExpandedChanged: (expanded) => {
        if (expanded && root.status === "active" && root.hasNvidiaSmi) {
            root.isBackingOff = false;
            root.idleCooldownTicks = 0;
            root.baselineFuserPids = [];
            root.lastSmiQueryTime = Date.now();
            gpuProcessesSource.disconnectSource(root.getProcessCmd);
            gpuProcessesSource.connectSource(root.getProcessCmd);
        }
    }

    // Safe Timer: Polls every X seconds
    Timer {
        interval: (plasmoid.configuration.updateInterval || 3) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const addr = root.configuredPciAddress;
            gpuStatusSource.disconnectSource("cat /sys/bus/pci/devices/" + addr + "/power/runtime_status");
            gpuStatusSource.connectSource("cat /sys/bus/pci/devices/" + addr + "/power/runtime_status");
            
            // Only query processes if view is active (expanded popup or desktop widget) AND gpu is active AND tool was found
            if (root.isViewActive && root.status === "active" && root.hasNvidiaSmi) {
                if (root.isBackingOff) {
                    // Passively monitor fuser without waking or resetting autosuspend timer
                    fuserSource.disconnectSource(root.fuserCmd);
                    fuserSource.connectSource(root.fuserCmd);
                } else {
                    gpuProcessesSource.disconnectSource(root.getProcessCmd);
                    gpuProcessesSource.connectSource(root.getProcessCmd);
                }
            }
        }
    }
}
