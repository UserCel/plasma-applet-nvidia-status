import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // --- Properties ---
    property string status: "unknown"
    property string statusText: i18n("Checking...")
    property var lastUpdate: new Date()

    property color statusColor: {
        const cfg = plasmoid.configuration;
        if (status === "active") return cfg.activeColor || "#76b900";
        if (status === "suspended") return cfg.suspendedColor || "#888888";
        if (status === "resuming" || status === "suspending") return cfg.resumingColor || "#3daee9";
        return cfg.unknownColor || "#ffaa00";
    }

    // --- Tooltip ---
    toolTipMainText: i18n("NVIDIA GPU Status")
    toolTipSubText: i18n("Current State: %1", statusText)

    // --- Representations ---
    preferredRepresentation: compactRepresentation

    compactRepresentation: RowLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium

            // Qt.resolvedUrl ensures the path is relative to THIS .qml file
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
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8

        ColumnLayout {
            anchors.centerIn: parent
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading {
                Layout.alignment: Qt.AlignHCenter
                level: 2
                text: i18n("NVIDIA dGPU Status")
            }

            Kirigami.Icon {
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: Kirigami.Units.iconSizes.huge
                implicitHeight: Kirigami.Units.iconSizes.huge

                source: root.status === "active"
                ? Qt.resolvedUrl("../assets/nvidia-active.svg")
                : Qt.resolvedUrl("../assets/nvidia-suspended.svg")

                isMask: true
                color: root.statusColor
            }

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.statusText
                color: root.statusColor
                font.pointSize: 18
                font.bold: true
            }

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                opacity: 0.6
                text: i18n("Last checked: %1", lastUpdate.toLocaleTimeString())
            }
        }
    }

    // --- Data Source ---
    Plasma5Support.DataSource {
        id: gpuStatusSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            const result = data["stdout"] ? data["stdout"].trim() : "";
            root.status = result;
            root.lastUpdate = new Date();

            if (result === "suspended") {
                root.statusText = i18n("Suspended (D3cold)");
            } else if (result === "active") {
                root.statusText = i18n("Active (D0)");
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

    // Safe Timer: Polls every X seconds
    Timer {
        interval: (plasmoid.configuration.updateInterval || 3) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            // Use the configuration property
            const addr = plasmoid.configuration.pciAddress || "0000:01:00.0";
            gpuStatusSource.connectSource("cat /sys/bus/pci/devices/" + addr + "/power/runtime_status");
        }
    }
}
