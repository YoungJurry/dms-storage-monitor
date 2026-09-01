import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets
import "./services" as Services

PluginSettings {
    id: root
    pluginId: "storageMonitor"

    Component.onCompleted: Services.StorageService.refresh()

    StyledText {
        width: parent.width
        text: "Storage Monitor"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Monitor storage usage, mount or unmount partitions, and safely power off removable drives through udisks2. A system authorization prompt appears when required."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: "General"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.primary
    }

    SelectionSetting {
        settingKey: "refreshInterval"
        label: "Refresh Interval"
        description: "How often partition usage is re-scanned."
        defaultValue: "60"
        options: [
            { label: "15 seconds", value: "15" },
            { label: "30 seconds", value: "30" },
            { label: "60 seconds", value: "60" },
            { label: "5 minutes", value: "300" }
        ]
    }

    ToggleSetting {
        settingKey: "showUnmounted"
        label: "Show Unmounted Partitions"
        description: "List partitions that are not currently mounted so they can be mounted from the popout."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showLabels"
        label: "Show Partition Labels"
        description: "Prefer the volume label (e.g. MYASUS) over the device name."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showSystemPartitions"
        label: "Show System Partitions"
        description: "Show EFI and Windows reserved partitions (boot/ESP/SYSTEM). Hidden by default like most file managers."
        defaultValue: false
    }
}
