pragma Singleton

import qs.services
import qs.modules.common
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import Quickshell.Io

Singleton {
    id: root
    property bool available: UPower.displayDevice.isLaptopBattery
    property var chargeState: UPower.displayDevice.state
    property bool isCharging: chargeState == UPowerDeviceState.Charging
    property bool isPluggedIn: isCharging || chargeState == UPowerDeviceState.PendingCharge
    property real percentage: UPower.displayDevice?.percentage ?? 1
    readonly property bool allowAutomaticSuspend: Config.options?.battery?.automaticSuspend ?? false
    readonly property bool soundEnabled: Config.options?.sounds?.battery ?? true

    property bool isLow: available && (percentage <= ((Config.options?.battery?.low ?? 20) / 100))
    property bool isCritical: available && (percentage <= ((Config.options?.battery?.critical ?? 10) / 100))
    property bool isSuspending: available && (percentage <= ((Config.options?.battery?.suspend ?? 5) / 100))
    property bool isFull: available && (percentage >= ((Config.options?.battery?.full ?? 95) / 100))

    property bool isLowAndNotCharging: isLow && !isCharging
    property bool isCriticalAndNotCharging: isCritical && !isCharging
    property bool isSuspendingAndNotCharging: allowAutomaticSuspend && isSuspending && !isCharging
    property bool isFullAndCharging: isFull && isCharging

    property real energyRate: UPower.displayDevice.changeRate
    property real timeToEmpty: UPower.displayDevice.timeToEmpty
    property real timeToFull: UPower.displayDevice.timeToFull

    // ─── Charge limit ───
    readonly property bool chargeLimitEnabled: Config.options?.battery?.chargeLimit?.enable ?? false
    readonly property int chargeLimitThreshold: Config.options?.battery?.chargeLimit?.threshold ?? 80
    property string _chargeLimitSysfsPath: ""
    property int _currentChargeLimit: -1
    readonly property bool chargeLimitSupported: _chargeLimitSysfsPath.length > 0
    readonly property int currentChargeLimit: _currentChargeLimit

    Component.onCompleted: {
        if (root.available) {
            _detectChargeLimitPath()
        }
    }

    onAvailableChanged: {
        if (available && _chargeLimitSysfsPath.length === 0) {
            _detectChargeLimitPath()
        }
    }

    function _detectChargeLimitPath(): void {
        if (!chargeLimitDetector.running) {
            chargeLimitDetector.running = true
        }
    }

    Process {
        id: chargeLimitDetector
        command: ["/bin/sh", "-c",
            "for p in /sys/class/power_supply/BAT*/charge_control_end_threshold " +
            "/sys/class/power_supply/BAT*/charge_stop_threshold; do " +
            "[ -f \"$p\" ] && echo \"$p\" && exit 0; done; echo ''"
        ]
        stdout: SplitParser {
            onRead: data => {
                const path = data.trim()
                if (path.length > 0) {
                    root._chargeLimitSysfsPath = path
                    console.log("[Battery] Charge limit sysfs: " + path)
                    root._readChargeLimit()
                    if (root.chargeLimitEnabled) {
                        chargeLimitApplyDelay.restart()
                    }
                }
            }
        }
    }

    // Small delay before applying on startup so the shell is settled
    Timer {
        id: chargeLimitApplyDelay
        interval: 2000
        repeat: false
        onTriggered: root._applyChargeLimit()
    }

    function _readChargeLimit(): void {
        if (_chargeLimitSysfsPath.length === 0 || chargeLimitReader.running) return
        chargeLimitReader.command = ["/bin/cat", _chargeLimitSysfsPath]
        chargeLimitReader.running = true
    }

    Process {
        id: chargeLimitReader
        stdout: SplitParser {
            onRead: data => {
                const val = parseInt(data.trim())
                if (!isNaN(val)) {
                    root._currentChargeLimit = val
                }
            }
        }
    }

    // Periodically re-read the threshold so the UI stays in sync
    Timer {
        id: chargeLimitPoll
        interval: 30000
        repeat: true
        running: root.chargeLimitSupported
        onTriggered: root._readChargeLimit()
    }

    function _applyChargeLimit(): void {
        if (!chargeLimitSupported || chargeLimitWriter.running) return
        chargeLimitWriter.command = [
            "/usr/bin/pkexec", "/bin/sh", "-c",
            "printf '%d' " + chargeLimitThreshold + " > " + _chargeLimitSysfsPath
        ]
        chargeLimitWriter.running = true
    }

    function _resetChargeLimit(): void {
        if (!chargeLimitSupported || chargeLimitResetter.running) return
        chargeLimitResetter.command = [
            "/usr/bin/pkexec", "/bin/sh", "-c",
            "printf '100' > " + _chargeLimitSysfsPath
        ]
        chargeLimitResetter.running = true
    }

    Process {
        id: chargeLimitWriter
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root._currentChargeLimit = root.chargeLimitThreshold
                console.log("[Battery] Charge limit set to " + root.chargeLimitThreshold + "%")
            } else {
                console.warn("[Battery] Failed to set charge limit (exit code " + exitCode + ")")
            }
        }
    }

    Process {
        id: chargeLimitResetter
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root._currentChargeLimit = 100
                console.log("[Battery] Charge limit removed (set to 100%)")
            } else {
                console.warn("[Battery] Failed to reset charge limit (exit code " + exitCode + ")")
            }
        }
    }

    onChargeLimitEnabledChanged: {
        if (!chargeLimitSupported) return
        if (chargeLimitEnabled) {
            _applyChargeLimit()
        } else {
            _resetChargeLimit()
        }
    }

    onChargeLimitThresholdChanged: {
        if (!chargeLimitSupported || !chargeLimitEnabled) return
        _applyChargeLimit()
    }

    // ─── Battery warnings ───
    onIsLowAndNotChargingChanged: {
        if (!root.available || !isLowAndNotCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send", 
            Translation.tr("Low battery"), 
            Translation.tr("Consider plugging in your device"), 
            "-u", "critical",
            "-a", "Shell",
            "--hint=int:transient:1",
        ])

        if (root.soundEnabled) Audio.playSystemSound("dialog-warning");
    }

    onIsCriticalAndNotChargingChanged: {
        if (!root.available || !isCriticalAndNotCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send", 
            Translation.tr("Critically low battery"), 
            Translation.tr("Please charge!\nAutomatic suspend triggers at %1%").arg(Config.options?.battery?.suspend ?? 5), 
            "-u", "critical",
            "-a", "Shell",
            "--hint=int:transient:1",
        ]);

        if (root.soundEnabled) Audio.playSystemSound("suspend-error");
    }

    onIsSuspendingAndNotChargingChanged: {
        if (root.available && isSuspendingAndNotCharging) {
            if (!suspendSystemctl.running && !suspendLoginctl.running) {
                suspendSystemctl.running = true
            }
        }
    }

    Process {
        id: suspendSystemctl
        command: ["/usr/bin/systemctl", "suspend"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                suspendLoginctl.running = true
            }
        }
    }

    Process {
        id: suspendLoginctl
        command: ["/usr/bin/loginctl", "suspend"]
    }

    onIsFullAndChargingChanged: {
        if (!root.available || !isFullAndCharging) return;
        Quickshell.execDetached([
            "/usr/bin/notify-send",
            Translation.tr("Battery full"),
            Translation.tr("Please unplug the charger"),
            "-a", "Shell",
            "--hint=int:transient:1",
        ]);

        if (root.soundEnabled) Audio.playSystemSound("complete");
    }

    onIsPluggedInChanged: {
        if (!root.available || !root.soundEnabled) return;
        if (isPluggedIn) {
            Audio.playSystemSound("power-plug")
        } else {
            Audio.playSystemSound("power-unplug")
        }
    }
}
