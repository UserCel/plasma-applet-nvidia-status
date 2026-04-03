import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

Kirigami.FormLayout {
    id: page

    // Standard Plasma config properties
    property alias cfg_pciAddress: pciAddressField.text
    property alias cfg_showTextInCompact: showTextInCompact.checked
    property alias cfg_updateInterval: updateIntervalSpin.value

    // Color properties bound manually
    property color cfg_activeColor: "#76b900"
    property color cfg_suspendedColor: "#888888"
    property color cfg_unknownColor: "#ffaa00"
    property color cfg_resumingColor: "#3daee9"

    // Internal GPU detection state
    property var gpuList: []
    property bool searching: false

    // --- Color Dialogs ---
    ColorDialog {
        id: activeColorDialog
        title: i18n("Pick Active State Color")
        selectedColor: page.cfg_activeColor
        onAccepted: page.cfg_activeColor = selectedColor
    }
    ColorDialog {
        id: suspendedColorDialog
        title: i18n("Pick Suspended State Color")
        selectedColor: page.cfg_suspendedColor
        onAccepted: page.cfg_suspendedColor = selectedColor
    }
    ColorDialog {
        id: unknownColorDialog
        title: i18n("Pick Unknown State Color")
        selectedColor: page.cfg_unknownColor
        onAccepted: page.cfg_unknownColor = selectedColor
    }
    ColorDialog {
        id: resumingColorDialog
        title: i18n("Pick Resuming State Color")
        selectedColor: page.cfg_resumingColor
        onAccepted: page.cfg_resumingColor = selectedColor
    }

    // --- GPU Detection DataSource ---
    Plasma5Support.DataSource {
        id: detectionSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            const output = data["stdout"] ? data["stdout"].trim() : "";
            const foundItems = [];
            if (output) {
                const lines = output.split(/\n+/);
                for (let line of lines) {
                    if (!line.trim()) continue;
                    const addr = line.split(" ")[0];
                    const match = line.match(/\[(.*?)\]/);
                    const modelName = match ? match[1] : line.substring(line.indexOf(":") + 1).replace("NVIDIA Corporation", "").trim();
                    foundItems.push({ "address": addr, "display": addr + ": " + modelName });
                }
            }
            gpuList = foundItems;
            searching = false;
            disconnectSource(sourceName);
        }
    }

    // --- Display Options ---
    CheckBox {
        id: showTextInCompact
        Kirigami.FormData.label: i18n("Display Options:")
        text: i18n("Show status text in compact mode (panel)")
    }

    SpinBox {
        id: updateIntervalSpin
        Kirigami.FormData.label: i18n("Update Interval (seconds):")
        from: 1
        to: 3600
        stepSize: 1
        editable: true
    }

    // --- Status Colors ---
    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Status Colors")
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Active (D0):")
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            id: activePreview
            implicitWidth: Kirigami.Units.iconSizes.medium
            implicitHeight: Kirigami.Units.iconSizes.medium
            source: Qt.resolvedUrl("../../assets/nvidia-active.svg")
            isMask: true
            color: page.cfg_activeColor
            
            MouseArea { anchors.fill: parent; onClicked: activeColorDialog.open() }
        }
        Label { text: page.cfg_activeColor; opacity: 0.7; font.family: "monospace" }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Suspended (D3cold):")
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            id: suspendedPreview
            implicitWidth: Kirigami.Units.iconSizes.medium
            implicitHeight: Kirigami.Units.iconSizes.medium
            source: Qt.resolvedUrl("../../assets/nvidia-suspended.svg")
            isMask: true
            color: page.cfg_suspendedColor
            
            MouseArea { anchors.fill: parent; onClicked: suspendedColorDialog.open() }
        }
        Label { text: page.cfg_suspendedColor; opacity: 0.7; font.family: "monospace" }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Resuming/Suspending:")
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            id: resumingPreview
            implicitWidth: Kirigami.Units.iconSizes.medium
            implicitHeight: Kirigami.Units.iconSizes.medium
            source: Qt.resolvedUrl("../../assets/nvidia-suspended.svg")
            isMask: true
            color: page.cfg_resumingColor
            
            MouseArea { anchors.fill: parent; onClicked: resumingColorDialog.open() }
        }
        Label { text: page.cfg_resumingColor; opacity: 0.7; font.family: "monospace" }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Unknown:")
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            id: unknownPreview
            implicitWidth: Kirigami.Units.iconSizes.medium
            implicitHeight: Kirigami.Units.iconSizes.medium
            source: Qt.resolvedUrl("../../assets/nvidia-suspended.svg")
            isMask: true
            color: page.cfg_unknownColor
            
            MouseArea { anchors.fill: parent; onClicked: unknownColorDialog.open() }
        }
        Label { text: page.cfg_unknownColor; opacity: 0.7; font.family: "monospace" }
    }

    Button {
        Kirigami.FormData.label: ""
        text: i18n("Restore Defaults")
        icon.name: "edit-undo"
        onClicked: {
            page.cfg_activeColor = "#76b900";
            page.cfg_suspendedColor = "#888888";
            page.cfg_unknownColor = "#ffaa00";
            page.cfg_resumingColor = "#3daee9";
        }
    }

    // --- GPU Selection ---
    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("GPU Selection")
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Detected NVIDIA GPUs:")
        spacing: Kirigami.Units.smallSpacing

        ComboBox {
            id: gpuCombo
            Layout.fillWidth: true
            model: page.gpuList
            textRole: "display"
            enabled: !page.searching && page.gpuList.length > 0

            onActivated: (index) => {
                if (index >= 0 && index < page.gpuList.length)
                    pciAddressField.text = page.gpuList[index].address;
            }

            Component.onCompleted: {
                for (let i = 0; i < page.gpuList.length; i++) {
                    if (page.gpuList[i].address === pciAddressField.text) {
                        currentIndex = i;
                        break;
                    }
                }
            }
        }

        BusyIndicator {
            running: page.searching
            visible: running
            implicitWidth: Kirigami.Units.iconSizes.small
            implicitHeight: Kirigami.Units.iconSizes.small
        }

        Label {
            text: i18n("No GPUs found")
            visible: !page.searching && page.gpuList.length === 0
            opacity: 0.6
        }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("PCI Address:")

        TextField {
            id: pciAddressField
            Layout.fillWidth: true
            placeholderText: "0000:01:00.0"
        }

        Button {
            icon.name: "view-refresh"
            text: i18n("Detect")
            onClicked: {
                page.searching = true;
                detectionSource.connectSource("lspci -d 10de:: -D | grep -E 'VGA|3D'")
            }
        }
    }

    Component.onCompleted: {
        page.searching = true;
        detectionSource.connectSource("lspci -d 10de:: -D | grep -E 'VGA|3D'")
    }
}
