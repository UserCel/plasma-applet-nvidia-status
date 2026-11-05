import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

ScrollView {
    id: scrollRoot
    contentWidth: availableWidth

    // Standard Plasma config properties exposed at root level
    property alias cfg_pciAddress: page.cfg_pciAddress
    property alias cfg_showTextInCompact: page.cfg_showTextInCompact
    property alias cfg_allowProcessTermination: page.cfg_allowProcessTermination
    property alias cfg_showProcessIcons: page.cfg_showProcessIcons
    property alias cfg_showGpuModel: page.cfg_showGpuModel
    property alias cfg_updateInterval: page.cfg_updateInterval
    property alias cfg_sortField: page.cfg_sortField
    property alias cfg_sortDescending: page.cfg_sortDescending
    property alias cfg_activeColor: page.cfg_activeColor
    property alias cfg_suspendedColor: page.cfg_suspendedColor
    property alias cfg_unknownColor: page.cfg_unknownColor
    property alias cfg_resumingColor: page.cfg_resumingColor

    Kirigami.FormLayout {
        id: page
        width: scrollRoot.availableWidth

        // Standard Plasma config properties
        property alias cfg_pciAddress: pciAddressField.text
        property alias cfg_showTextInCompact: showTextInCompact.checked
        property alias cfg_allowProcessTermination: allowProcessTerminationCheckBox.checked
        property alias cfg_showProcessIcons: showProcessIconsCheckBox.checked
        property alias cfg_showGpuModel: showGpuModelCheckBox.checked
        property alias cfg_updateInterval: updateIntervalSpin.value
        property string cfg_sortField: "sm"
        property alias cfg_sortDescending: sortDescendingCheckBox.checked

        onCfg_sortFieldChanged: {
            if (sortFieldCombo.model) {
                for (let i = 0; i < sortFieldCombo.model.length; i++) {
                    if (sortFieldCombo.model[i].value === cfg_sortField) {
                        sortFieldCombo.currentIndex = i;
                        break;
                    }
                }
            }
        }

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

        function parseDetectedGpus(output) {
            const foundItems = [];
            if (!output) return foundItems;
            const lines = String(output).trim().split(/\n+/);
            for (let line of lines) {
                if (!line.trim()) continue;
                const addr = page.normalizePciAddress(line.split(" ")[0]);
                const match = line.match(/\[(.*?)\]/);
                const modelName = match ? match[1] : line.substring(line.indexOf(":") + 1).replace("NVIDIA Corporation", "").trim();
                foundItems.push({ "address": addr, "display": addr + ": " + modelName });
            }
            return foundItems;
        }

        function resolveSelectedGpu(foundItems, currentText) {
            const normalizedCurrent = page.normalizePciAddress(currentText);
            if (!foundItems || foundItems.length === 0) {
                return { index: -1, address: normalizedCurrent || currentText };
            }
            for (let i = 0; i < foundItems.length; i++) {
                if (foundItems[i].address === normalizedCurrent) {
                    return { index: i, address: foundItems[i].address };
                }
            }
            return { index: 0, address: foundItems[0].address };
        }

        // --- GPU Detection DataSource ---
        Plasma5Support.DataSource {
            id: detectionSource
            engine: "executable"
            connectedSources: []
            onNewData: function(sourceName, data) {
                const output = data["stdout"] ? data["stdout"].trim() : "";
                const foundItems = page.parseDetectedGpus(output);
                page.gpuList = foundItems;
                page.searching = false;
                const resolved = page.resolveSelectedGpu(foundItems, pciAddressField.text);
                if (resolved.index >= 0) {
                    gpuCombo.currentIndex = resolved.index;
                    if (pciAddressField.text !== resolved.address) {
                        pciAddressField.text = resolved.address;
                    }
                }
                detectionSource.disconnectSource(sourceName);
            }
        }

        // --- Display Options ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Display Options")
        }

        CheckBox {
            id: showTextInCompact
            Kirigami.FormData.label: i18n("Panel Layout:")
            text: i18n("Show status text in compact mode (panel)")
        }

        CheckBox {
            id: showGpuModelCheckBox
            Kirigami.FormData.label: i18n("GPU Model:")
            text: i18n("Show GPU model name in header and tooltip")
        }

        SpinBox {
            id: updateIntervalSpin
            Kirigami.FormData.label: i18n("Update Interval (seconds):")
            from: 1
            to: 3600
            stepSize: 1
            editable: true
        }

        // --- Process List Options ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Process List & Actions")
        }

        CheckBox {
            id: allowProcessTerminationCheckBox
            Kirigami.FormData.label: i18n("Process Termination:")
            text: i18n("Allow terminating processes (Terminate / Force Kill)")
        }

        CheckBox {
            id: showProcessIconsCheckBox
            Kirigami.FormData.label: i18n("Process Icons:")
            text: i18n("Show application icons in process list")
        }

        ComboBox {
            id: sortFieldCombo
            Kirigami.FormData.label: i18n("Default Sort By:")
            textRole: "text"
            model: [
                { "text": i18n("GPU Usage (SM %)"), "value": "sm" },
                { "text": i18n("Memory Usage (%)"), "value": "mem" },
                { "text": i18n("Process Name"), "value": "name" }
            ]
            onActivated: (index) => {
                page.cfg_sortField = model[index].value;
            }
            Component.onCompleted: {
                for (let i = 0; i < model.length; i++) {
                    if (model[i].value === page.cfg_sortField) {
                        currentIndex = i;
                        break;
                    }
                }
            }
        }

        CheckBox {
            id: sortDescendingCheckBox
            Kirigami.FormData.label: i18n("Sort Order:")
            text: i18n("Sort descending (highest first)")
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
                onEditingFinished: {
                    const norm = page.normalizePciAddress(text);
                    if (norm && norm !== text) {
                        text = norm;
                    }
                    for (let i = 0; i < page.gpuList.length; i++) {
                        if (page.gpuList[i].address === norm) {
                            gpuCombo.currentIndex = i;
                            break;
                        }
                    }
                }
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
}
