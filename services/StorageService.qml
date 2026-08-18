pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    // Runtime state
    property bool probing: false
    property bool busyAction: false
    property string lastError: ""
    property string lastActionMessage: ""
    property string lastActionLog: ""

    // Probed data
    property var partitions: [] // [{name, path, size, used, avail, usePercent, fstype, mountpoint, label, mounted}]

    // Settings supplied by the widget
    property int refreshInterval: 60
    property bool showUnmounted: true
    property bool showLabels: true
    property bool showSystemPartitions: false

    readonly property var systemPartitionLabels: ["SYSTEM", "ESP", "RECOVERY", "WINRE", "MSR", "DIAGS", "MYASUS"]

    readonly property var visiblePartitions: {
        const list = [];
        const partitions = root.partitions;
        for (let i = 0; i < partitions.length; i++) {
            const partition = partitions[i];
            if (root.showSystemPartitions || !isSystemPartition(partition))
                list.push(partition);
        }
        return list;
    }

    function isSystemPartition(partition) {
        if (!partition)
            return false;
        const mountpoint = partition.mountpoint || "";
        if (mountpoint === "/boot" || mountpoint.indexOf("/boot/") === 0)
            return true;
        const partType = (partition.partTypeName || "").toLowerCase();
        if (partType.indexOf("efi") >= 0 || partType.indexOf("recovery") >= 0 || partType.indexOf("reserved") >= 0)
            return true;
        const label = (partition.label || "").toUpperCase();
        return systemPartitionLabels.indexOf(label) >= 0;
    }

    property var _dfData: ({}) // path -> {used, avail, capacity}

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    function refresh() {
        if (lsblkProc.running || dfProc.running)
            return;
        probing = true;
        lastError = "";
        _dfData = ({});
        lsblkProc.running = true;
        dfProc.running = true;
    }

    function mountPartition(partition) {
        if (busyAction || !partition || partition.mounted)
            return;
        _beginAction("mount", partition.path);
    }

    function unmountPartition(partition) {
        if (busyAction || !partition || !partition.mounted)
            return;
        _beginAction("unmount", partition.path);
    }

    function _beginAction(verb, path) {
        busyAction = true;
        lastActionMessage = "";
        lastActionLog = "";
        actionProc.command = ["udisksctl", verb, "-b", path];
        actionWatchdog.interval = 20000;
        actionWatchdog.restart();
        actionProc.running = true;
    }

    function formatBytes(bytes) {
        const value = Number(bytes || 0);
        if (isNaN(value) || value <= 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let index = 0;
        let size = value;
        while (size >= 1024 && index < units.length - 1) {
            size /= 1024;
            index++;
        }
        const digits = index === 0 ? 0 : (size >= 100 ? 0 : (size >= 10 ? 1 : 2));
        return size.toFixed(digits) + " " + units[index];
    }

    function totalStats() {
        let used = 0;
        let size = 0;
        const partitions = root.visiblePartitions;
        for (let i = 0; i < partitions.length; i++) {
            const p = partitions[i];
            if (!p.mounted)
                continue;
            used += p.used;
            size += p.size;
        }
        const percent = size > 0 ? Math.round((used / size) * 100) : 0;
        return { used: used, size: size, percent: percent };
    }

    Process {
        id: lsblkProc
        command: ["env", "LC_ALL=C", "lsblk", "-J", "-b", "-o", "NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL,PARTTYPENAME"]
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.lastError = "lsblk failed: " + stderr.text.trim();
                root.probing = false;
                return;
            }
            let parsed = null;
            try {
                parsed = JSON.parse(stdout.text);
            } catch (e) {
                root.lastError = "Could not parse lsblk output.";
                root.probing = false;
                return;
            }
            const result = [];
            const devices = parsed.blockdevices || [];
            for (let i = 0; i < devices.length; i++)
                collectPartitions(devices[i], result);
            root.partitions = result;
            root._finishIfDone();
        }
    }

    Process {
        id: dfProc
        command: ["df", "-B1", "-P", "-x", "squashfs", "-x", "tmpfs", "-x", "overlay", "-x", "devtmpfs", "-x", "efivarfs", "-x", "proc", "-x", "sysfs", "-x", "cgroup2", "-x", "zfs"]
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            const lines = stdout.text.trim().split("\n");
            for (let i = 1; i < lines.length; i++) {
                const parts = lines[i].trim().split(/\s+/);
                if (parts.length < 6)
                    continue;
                const path = parts[0];
                const used = parseInt(parts[2], 10);
                const avail = parseInt(parts[3], 10);
                const capacity = parseInt(parts[4].replace("%", ""), 10);
                root._dfData[path] = { used: used, avail: avail, capacity: capacity };
            }
            root._finishIfDone();
        }
    }

    function _finishIfDone() {
        if (lsblkProc.running || dfProc.running)
            return;
        probing = false;
        const merged = [];
        for (let i = 0; i < partitions.length; i++) {
            const p = partitions[i];
            const info = _dfData["/dev/" + p.name] || _dfData[p.name];
            if (info) {
                p.used = info.used;
                p.avail = info.avail;
                p.usePercent = info.capacity;
                p.mounted = true;
            } else {
                p.used = 0;
                p.avail = p.size;
                p.usePercent = 0;
                p.mounted = false;
            }
            merged.push(p);
        }
        root.partitions = merged;
    }

    function collectPartitions(device, result) {
        if (!device)
            return;
        const type = device.type || "";
        const fstype = device.fstype || "";
        if (type === "part" || (type === "disk" && fstype && fstype !== "swap")) {
            if (fstype && fstype !== "swap") {
                result.push({
                    name: device.name || device.kname || "",
                    path: "/dev/" + (device.kname || device.name),
                    size: Number(device.size || 0),
                    fstype: fstype,
                    partTypeName: device.parttypename || "",
                    mountpoint: device.mountpoint || "",
                    label: device.label || "",
                    mounted: !!device.mountpoint,
                    used: 0,
                    avail: 0,
                    usePercent: 0
                });
            }
        }
        const children = device.children || [];
        for (let i = 0; i < children.length; i++)
            collectPartitions(children[i], result);
    }

    Process {
        id: actionProc
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            root.busyAction = false;
            root.lastActionLog = (stdout.text + " " + stderr.text).trim();
            if (exitCode === 0) {
                root.lastActionMessage = "OK";
                root.refresh();
            } else {
                root.lastError = stderr.text.trim() || "Storage operation failed.";
                ToastService.showError("Storage Monitor", root.lastError);
            }
        }
    }

    Timer {
        id: actionWatchdog
        interval: 20000
        repeat: false
        onTriggered: {
            if (!root.busyAction)
                return;
            root.busyAction = false;
            root.lastError = "Storage operation timed out (udisks2 did not respond). Check the authorization prompt.";
            ToastService.showError("Storage Monitor", root.lastError);
        }
    }
}
