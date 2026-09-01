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
    property string currentAction: ""
    property string actionDescription: ""
    property string lastError: ""
    property string lastActionMessage: ""
    property string lastActionLog: ""

    property var _actionQueue: []
    property int _actionIndex: 0
    property bool _actionTimedOut: false
    property bool _probeFailed: false

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

    property var _dfData: ({}) // device or mountpoint -> {used, avail, capacity}

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    function refresh(preserveError) {
        if (busyAction || lsblkProc.running || dfProc.running)
            return;
        probing = true;
        if (!preserveError)
            lastError = "";
        _dfData = ({});
        _probeFailed = false;
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

    function safelyRemoveDrive(partition) {
        if (busyAction || !partition || !partition.external || !partition.drivePath || partition.drivePath === "/dev/")
            return;

        const commands = [];
        const seen = ({});
        for (let i = 0; i < root.partitions.length; i++) {
            const candidate = root.partitions[i];
            if (candidate.drivePath !== partition.drivePath || !candidate.mounted || seen[candidate.path])
                continue;
            seen[candidate.path] = true;
            commands.push({
                command: ["udisksctl", "unmount", "-b", candidate.path],
                description: "Unmounting " + candidate.name + "…"
            });
        }
        commands.push({
            command: ["udisksctl", "power-off", "-b", partition.drivePath],
            description: "Powering off " + partition.driveName + "…"
        });
        _beginActionSequence("safe-remove", commands);
    }

    function _beginAction(verb, path) {
        const description = verb === "mount" ? "Mounting " + path + "…" : "Unmounting " + path + "…";
        _beginActionSequence(verb, [{
            command: ["udisksctl", verb, "-b", path],
            description: description
        }]);
    }

    function _beginActionSequence(kind, commands) {
        if (busyAction || !commands || commands.length === 0)
            return;
        busyAction = true;
        currentAction = kind;
        actionDescription = "";
        lastError = "";
        lastActionMessage = "";
        actionMessageTimer.stop();
        lastActionLog = "";
        _actionQueue = commands;
        _actionIndex = 0;
        _actionTimedOut = false;
        _runNextAction();
    }

    function _runNextAction() {
        if (_actionIndex >= _actionQueue.length) {
            const completedAction = currentAction;
            busyAction = false;
            currentAction = "";
            actionDescription = "";
            _actionQueue = [];
            lastActionMessage = completedAction === "safe-remove"
                ? "Drive safely powered off — you can unplug it now."
                : (completedAction === "mount" ? "Partition mounted." : "Partition unmounted. The drive is still powered.");
            ToastService.showInfo("Storage Monitor", lastActionMessage);
            actionMessageTimer.restart();
            refresh();
            return;
        }

        const step = _actionQueue[_actionIndex];
        actionDescription = step.description;
        actionProc.command = step.command;
        actionWatchdog.restart();
        actionProc.running = true;
    }

    function _failAction(message) {
        const failedStep = actionDescription;
        actionWatchdog.stop();
        forceKillTimer.stop();
        busyAction = false;
        currentAction = "";
        actionDescription = "";
        _actionQueue = [];
        lastError = (failedStep ? failedStep.replace("…", "") + ": " : "") + (message || "Storage operation failed.");
        ToastService.showError("Storage Monitor", lastError);
        refresh(true);
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
        command: ["env", "LC_ALL=C", "lsblk", "-J", "-b", "-o", "NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MOUNTPOINTS,LABEL,PARTTYPENAME,PKNAME,TRAN,RM,HOTPLUG"]
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.lastError = "lsblk failed: " + stderr.text.trim();
                root._probeFailed = true;
                root._finishIfDone();
                return;
            }
            let parsed = null;
            try {
                parsed = JSON.parse(stdout.text);
            } catch (e) {
                root.lastError = "Could not parse lsblk output.";
                root._probeFailed = true;
                root._finishIfDone();
                return;
            }
            const result = [];
            const devices = parsed.blockdevices || [];
            for (let i = 0; i < devices.length; i++)
                collectPartitions(devices[i], result, null);
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
                const info = { used: used, avail: avail, capacity: capacity };
                root._dfData[path] = info;
                root._dfData[parts.slice(5).join(" ")] = info;
            }
            root._finishIfDone();
        }
    }

    function _finishIfDone() {
        if (lsblkProc.running || dfProc.running)
            return;
        probing = false;
        if (_probeFailed)
            return;
        const merged = [];
        for (let i = 0; i < partitions.length; i++) {
            const p = partitions[i];
            const info = _dfData[p.path] || _dfData["/dev/" + p.name] || _dfData[p.name] || _dfData[p.mountpoint];
            p.mounted = !!p.mountpoint;
            if (info) {
                p.used = info.used;
                p.avail = info.avail;
                p.usePercent = info.capacity;
            } else {
                p.used = 0;
                p.avail = p.mounted ? 0 : p.size;
                p.usePercent = 0;
            }
            merged.push(p);
        }
        root.partitions = merged;
    }

    function collectPartitions(device, result, parentDrive) {
        if (!device)
            return;
        const type = device.type || "";
        const fstype = device.fstype || "";
        let drive = parentDrive;
        if (type === "disk") {
            const driveName = device.kname || device.name || "";
            drive = {
                name: driveName,
                path: "/dev/" + driveName,
                transport: device.tran || "",
                removable: !!device.rm,
                hotplug: !!device.hotplug
            };
        }
        if (!drive) {
            const fallbackName = device.pkname || device.kname || device.name || "";
            drive = {
                name: fallbackName,
                path: "/dev/" + fallbackName,
                transport: device.tran || "",
                removable: !!device.rm,
                hotplug: !!device.hotplug
            };
        }

        if ((type === "part" || (type === "disk" && fstype && fstype !== "swap")) && fstype && fstype !== "swap") {
            const mountpoints = device.mountpoints || [];
            let mountpoint = device.mountpoint || "";
            if (!mountpoint) {
                for (let i = 0; i < mountpoints.length; i++) {
                    if (mountpoints[i]) {
                        mountpoint = mountpoints[i];
                        break;
                    }
                }
            }
            const transport = (device.tran || drive.transport || "").toLowerCase();
            const removable = !!device.rm || drive.removable;
            const hotplug = !!device.hotplug || drive.hotplug;
            const external = transport === "usb"
                || ((transport !== "sata" && transport !== "ata" && transport !== "nvme") && removable && hotplug);
            result.push({
                name: device.name || device.kname || "",
                path: "/dev/" + (device.kname || device.name),
                driveName: drive.name,
                drivePath: drive.path,
                transport: transport,
                external: external,
                size: Number(device.size || 0),
                fstype: fstype,
                partTypeName: device.parttypename || "",
                mountpoint: mountpoint,
                mountpoints: mountpoints,
                label: device.label || "",
                mounted: !!mountpoint,
                used: 0,
                avail: 0,
                usePercent: 0
            });
        }
        const children = device.children || [];
        for (let i = 0; i < children.length; i++)
            collectPartitions(children[i], result, drive);
    }

    Process {
        id: actionProc
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            forceKillTimer.stop();
            root.lastActionLog = (root.lastActionLog + "\n" + stdout.text + " " + stderr.text).trim();
            if (root._actionTimedOut) {
                root._actionTimedOut = false;
                root._failAction("Storage operation timed out. Check the authorization prompt and try again.");
            } else if (exitCode === 0) {
                root._actionIndex += 1;
                root._runNextAction();
            } else {
                root._failAction(stderr.text.trim() || "Storage operation failed.");
            }
        }
    }

    Timer {
        id: actionMessageTimer
        interval: 6000
        repeat: false
        onTriggered: root.lastActionMessage = ""
    }

    Timer {
        id: actionWatchdog
        interval: 60000
        repeat: false
        onTriggered: {
            if (!root.busyAction || !actionProc.running)
                return;
            root._actionTimedOut = true;
            actionProc.running = false;
            forceKillTimer.restart();
        }
    }

    Timer {
        id: forceKillTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (actionProc.running)
                actionProc.signal(9);
        }
    }
}
