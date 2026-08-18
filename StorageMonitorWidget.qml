import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./services" as Services

PluginComponent {
    id: root

    layerNamespacePlugin: "storage-monitor"

    readonly property var storage: Services.StorageService
    readonly property bool activeClick: false

    Component.onCompleted: {
        applySettings();
        storage.refresh();
    }
    onPluginDataChanged: applySettings()

    function applySettings() {
        const service = Services.StorageService;
        service.refreshInterval = pluginData.refreshInterval !== undefined ? parseInt(pluginData.refreshInterval) : 60;
        if (isNaN(service.refreshInterval) || service.refreshInterval < 10)
            service.refreshInterval = 60;
        service.showUnmounted = pluginData.showUnmounted !== false;
        service.showLabels = pluginData.showLabels !== false;
        service.showSystemPartitions = pluginData.showSystemPartitions === true;
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Item {
                width: Theme.iconSize - 4
                height: Theme.iconSize - 4
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    name: "storage"
                    size: Theme.iconSize - 5
                    color: Theme.surfaceText
                }
            }

            StyledText {
                text: root.storage.totalStats().percent + "%"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                color: root.storage.totalStats().percent >= 90 ? Theme.error : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 1

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "storage"
                size: Theme.iconSize - 5
                color: Theme.surfaceText
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.storage.totalStats().percent + "%"
                font.pixelSize: 9
                font.weight: Font.Bold
                color: Theme.surfaceText
            }
        }
    }

    popoutContent: Component {
        StorageMonitorPopout {}
    }
    popoutWidth: 460
    popoutHeight: 620
}
