pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: root
    settingsPageIndex: 12
    settingsPageName: Translation.tr("Compositor")

    property var outputList: []
    property int selectedOutputIndex: 0

    readonly property var currentOutput: outputList.length > selectedOutputIndex ? outputList[selectedOutputIndex] : null
    readonly property string currentOutputName: currentOutput?.name ?? ""
    readonly property string currentResolution: currentOutput?.current_resolution ?? ""
    readonly property real currentRate: currentOutput?.current_rate ?? 0
    readonly property real currentScale: currentOutput?.scale ?? 1.0
    readonly property string currentTransform: currentOutput?.transform ?? "Normal"
    readonly property bool vrrSupported: currentOutput?.vrr_supported ?? false
    readonly property bool vrrEnabled: currentOutput?.vrr_enabled ?? false

    readonly property var resolutionOptions: {
        const out = currentOutput
        if (!out?.resolutions) return []
        return out.resolutions.map(r => ({
            displayName: `${r.width}x${r.height}` + (r.preferred ? " \u2605" : ""),
            value: `${r.width}x${r.height}`,
            width: r.width,
            height: r.height,
            rates: r.rates
        }))
    }

    readonly property var refreshOptions: {
        const res = currentResolution
        if (!res || !currentOutput?.resolutions) return []
        const match = currentOutput.resolutions.find(r => `${r.width}x${r.height}` === res)
        if (!match?.rates) return []
        return match.rates.map(r => ({
            displayName: `${r.rate} Hz` + (r.preferred ? " \u2605" : ""),
            value: r.rate
        })).sort((a, b) => b.value - a.value)
    }

    readonly property var scaleOptions: [
        { displayName: "0.5x", value: 0.5 },
        { displayName: "0.75x", value: 0.75 },
        { displayName: "1x", value: 1.0 },
        { displayName: "1.25x", value: 1.25 },
        { displayName: "1.5x", value: 1.5 },
        { displayName: "1.75x", value: 1.75 },
        { displayName: "2x", value: 2.0 },
        { displayName: "2.5x", value: 2.5 },
        { displayName: "3x", value: 3.0 }
    ]

    readonly property var transformOptions: [
        { displayName: Translation.tr("Normal"), icon: "screen_rotation", value: "normal" },
        { displayName: "90\u00b0", icon: "screen_rotation", value: "90" },
        { displayName: "180\u00b0", icon: "screen_rotation", value: "180" },
        { displayName: "270\u00b0", icon: "screen_rotation", value: "270" },
        { displayName: Translation.tr("Flipped"), icon: "flip", value: "flipped" },
        { displayName: Translation.tr("Flipped 90\u00b0"), icon: "flip", value: "flipped-90" },
        { displayName: Translation.tr("Flipped 180\u00b0"), icon: "flip", value: "flipped-180" },
        { displayName: Translation.tr("Flipped 270\u00b0"), icon: "flip", value: "flipped-270" }
    ]

    property var inputData: ({})
    readonly property var keyboardData: inputData?.keyboard ?? {}
    readonly property var touchpadData: inputData?.touchpad ?? {}
    readonly property var mouseData: inputData?.mouse ?? {}
    readonly property var cursorData: inputData?.cursor ?? {}

    property var layoutData: ({})

    property bool inputReady: false
    property bool layoutReady: false
    property bool outputReady: false

    readonly property string scriptPath: Quickshell.shellPath("scripts/niri-config.py")

    function loadOutputs() { outputsProcess.running = true }
    function loadInput() { inputProcess.running = true }
    function loadLayout() { layoutProcess.running = true }

    function applyOutput(key, value) {
        applyOutputProcess.command = ["python3", scriptPath, "apply-output", currentOutputName, `${key}=${value}`]
        applyOutputProcess.running = true
    }

    function persistOutput(key, value) {
        persistOutputProcess.command = ["python3", scriptPath, "persist-output", currentOutputName, `${key}=${value}`]
        persistOutputProcess.running = true
    }

    function applyAndPersistOutput(key, value) {
        applyOutput(key, value)
        persistOutput(key, value)
    }

    function setConfig(section, key, value) {
        setProcess.command = ["python3", scriptPath, "set", section, key, String(value)]
        setProcess.running = true
    }

    function choiceIndex(options, value) {
        for (let i = 0; i < options.length; ++i) {
            if (String(options[i].value) === String(value))
                return i
        }
        return -1
    }

    Component.onCompleted: {
        loadOutputs()
        loadInput()
        loadLayout()
    }

    Process {
        id: outputsProcess
        command: ["python3", root.scriptPath, "outputs"]
        stdout: StdioCollector {
            id: outputsCollector
            onStreamFinished: {
                try {
                    root.outputReady = false
                    const data = JSON.parse(outputsCollector.text)
                    if (Array.isArray(data))
                        root.outputList = data
                    root.outputReady = true
                } catch (e) {
                    console.warn("[NiriConfig] Failed to parse outputs:", e)
                }
            }
        }
    }

    Process {
        id: inputProcess
        command: ["python3", root.scriptPath, "get-input"]
        stdout: StdioCollector {
            id: inputCollector
            onStreamFinished: {
                try {
                    root.inputReady = false
                    root.inputData = JSON.parse(inputCollector.text)
                    root.inputReady = true
                } catch (e) {
                    console.warn("[NiriConfig] Failed to parse input:", e)
                }
            }
        }
    }

    Process {
        id: layoutProcess
        command: ["python3", root.scriptPath, "get-layout"]
        stdout: StdioCollector {
            id: layoutCollector
            onStreamFinished: {
                try {
                    root.layoutReady = false
                    root.layoutData = JSON.parse(layoutCollector.text)
                    root.layoutReady = true
                } catch (e) {
                    console.warn("[NiriConfig] Failed to parse layout:", e)
                }
            }
        }
    }

    Process {
        id: applyOutputProcess
        onExited: (exitCode) => {
            if (exitCode === 0) root.loadOutputs()
        }
    }

    Process { id: persistOutputProcess }

    Process {
        id: setProcess
        onExited: (exitCode) => {
            if (exitCode !== 0) console.warn("[NiriConfig] set command failed")
        }
    }

    // =====================
    // DISPLAYS SECTION
    // =====================
    SettingsCardSection {
        icon: "monitor"
        title: Translation.tr("Displays")

        SettingsGroup {
            ContentSubsection {
                title: Translation.tr("Monitor")
                visible: root.outputList.length > 1

                ConfigSelectionArray {
                    currentValue: root.currentOutputName
                    options: root.outputList.map((o, i) => ({
                        displayName: `${o.name} — ${o.make} ${o.model}`,
                        icon: "monitor",
                        value: o.name
                    }))
                    onSelected: newValue => {
                        const idx = root.outputList.findIndex(o => o.name === newValue)
                        if (idx >= 0) root.selectedOutputIndex = idx
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: monitorInfoRow.implicitHeight + 8
                visible: root.currentOutput !== null

                RowLayout {
                    id: monitorInfoRow
                    anchors {
                        left: parent.left; right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 8; rightMargin: 8
                    }
                    spacing: 10

                    MaterialSymbol {
                        text: "monitor"
                        iconSize: Appearance.font.pixelSize.hugeass
                        color: Appearance.colors.colPrimary
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        StyledText {
                            text: root.currentOutputName
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.Medium
                            color: Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            text: {
                                const o = root.currentOutput
                                if (!o) return ""
                                const make = o.make ?? ""
                                const model = o.model ?? ""
                                const phys = o.physical_size ?? [0, 0]
                                let info = `${make} ${model}`.trim()
                                if (phys[0] > 0 && phys[1] > 0) {
                                    const diag = Math.sqrt(phys[0]*phys[0] + phys[1]*phys[1]) / 25.4
                                    info += ` \u2014 ${diag.toFixed(1)}"`
                                }
                                return info
                            }
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                    }
                }
            }

            SettingsDivider { visible: root.currentOutput !== null }

            ContentSubsection {
                title: Translation.tr("Resolution")
                visible: root.resolutionOptions.length > 0

                ConfigSelectionArray {
                    currentValue: root.currentResolution
                    options: root.resolutionOptions
                    onSelected: newValue => {
                        const match = root.currentOutput?.resolutions?.find(r => `${r.width}x${r.height}` === newValue)
                        if (match?.rates?.length > 0) {
                            const best = match.rates.reduce((a, b) => a.rate > b.rate ? a : b)
                            root.applyAndPersistOutput("mode", `${newValue}@${best.rate}`)
                        }
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Refresh rate")
                visible: root.refreshOptions.length > 1

                ConfigSelectionArray {
                    currentValue: root.currentRate
                    options: root.refreshOptions
                    onSelected: newValue => {
                        root.applyAndPersistOutput("mode", `${root.currentResolution}@${newValue}`)
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Scale")

                ConfigSelectionArray {
                    currentValue: root.currentScale
                    options: root.scaleOptions
                    onSelected: newValue => {
                        root.applyAndPersistOutput("scale", String(newValue))
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Rotation")

                ConfigSelectionArray {
                    currentValue: root.currentTransform.toLowerCase()
                    options: root.transformOptions
                    onSelected: newValue => {
                        root.applyAndPersistOutput("transform", newValue)
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Variable refresh rate (VRR)")
                tooltip: Translation.tr("Adaptive sync / FreeSync / G-Sync. Reduces tearing in games and video.")
                visible: root.vrrSupported

                SettingsSwitch {
                    Layout.fillWidth: true
                    buttonIcon: "display_settings"
                    text: Translation.tr("Enable VRR")
                    checked: root.vrrEnabled
                    onCheckedChanged: {
                        if (!root.outputReady) return
                        root.applyAndPersistOutput("vrr", checked ? "on" : "off")
                    }
                }
            }
        }
    }

    // =====================
    // INPUT SECTION
    // =====================
    SettingsCardSection {
        expanded: false
        icon: "keyboard"
        title: Translation.tr("Input")

        SettingsGroup {
            ContentSubsection {
                title: Translation.tr("Key repeat delay")
                tooltip: Translation.tr("Milliseconds before a held key starts repeating")

                ConfigSpinBox {
                    text: Translation.tr("Delay (ms)")
                    value: root.keyboardData?.repeat_delay ?? 250
                    from: 100
                    to: 1000
                    stepSize: 50
                    onValueChanged: {
                        if (!root.inputReady) return
                        root.setConfig("input", "keyboard.repeat-delay", value)
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Key repeat rate")
                tooltip: Translation.tr("Characters per second when a key is held")

                ConfigSpinBox {
                    text: Translation.tr("Rate (chars/s)")
                    value: root.keyboardData?.repeat_rate ?? 50
                    from: 10
                    to: 100
                    stepSize: 5
                    onValueChanged: {
                        if (!root.inputReady) return
                        root.setConfig("input", "keyboard.repeat-rate", value)
                    }
                }
            }

            SettingsDivider {}

            ContentSubsection {
                title: Translation.tr("Touchpad")
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "touch_app"
                text: Translation.tr("Tap to click")
                checked: root.touchpadData?.tap ?? true
                onCheckedChanged: {
                    if (!root.inputReady) return
                    root.setConfig("input", "touchpad.tap", checked ? "on" : "off")
                }
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "swipe"
                text: Translation.tr("Natural scroll")
                checked: root.touchpadData?.natural_scroll ?? true
                onCheckedChanged: {
                    if (!root.inputReady) return
                    root.setConfig("input", "touchpad.natural-scroll", checked ? "on" : "off")
                }
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "block"
                text: Translation.tr("Disable while typing")
                checked: root.touchpadData?.dwt ?? true
                onCheckedChanged: {
                    if (!root.inputReady) return
                    root.setConfig("input", "touchpad.dwt", checked ? "on" : "off")
                }
            }

            ContentSubsection {
                title: Translation.tr("Touchpad acceleration")

                ConfigSelectionArray {
                    currentValue: root.touchpadData?.accel_profile ?? "adaptive"
                    options: [
                        { displayName: Translation.tr("Adaptive"), icon: "tune", value: "adaptive" },
                        { displayName: Translation.tr("Flat"), icon: "horizontal_rule", value: "flat" }
                    ]
                    onSelected: newValue => {
                        root.setConfig("input", "touchpad.accel-profile", newValue)
                    }
                }
            }

            SettingsDivider {}

            ContentSubsection {
                title: Translation.tr("Mouse")
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "swipe"
                text: Translation.tr("Natural scroll")
                checked: root.mouseData?.natural_scroll ?? false
                onCheckedChanged: {
                    if (!root.inputReady) return
                    root.setConfig("input", "mouse.natural-scroll", checked ? "on" : "off")
                }
            }

            ContentSubsection {
                title: Translation.tr("Mouse acceleration")

                ConfigSelectionArray {
                    currentValue: root.mouseData?.accel_profile ?? "flat"
                    options: [
                        { displayName: Translation.tr("Adaptive"), icon: "tune", value: "adaptive" },
                        { displayName: Translation.tr("Flat"), icon: "horizontal_rule", value: "flat" }
                    ]
                    onSelected: newValue => {
                        root.setConfig("input", "mouse.accel-profile", newValue)
                    }
                }
            }
        }
    }

    // =====================
    // LAYOUT SECTION
    // =====================
    SettingsCardSection {
        expanded: false
        icon: "grid_view"
        title: Translation.tr("Layout")

        SettingsGroup {
            ContentSubsection {
                title: Translation.tr("Window gaps")
                tooltip: Translation.tr("Space between windows and screen edges in pixels")

                ConfigSpinBox {
                    text: Translation.tr("Gap size (px)")
                    value: root.layoutData?.gaps ?? 25
                    from: 0
                    to: 64
                    stepSize: 1
                    onValueChanged: {
                        if (!root.layoutReady) return
                        root.setConfig("layout", "gaps", value)
                    }
                }
            }

            ContentSubsection {
                title: Translation.tr("Focus behavior")
                tooltip: Translation.tr("When to center the focused column on screen")

                ConfigSelectionArray {
                    currentValue: root.layoutData?.center_focused ?? "never"
                    options: [
                        { displayName: Translation.tr("Never"), icon: "align_horizontal_left", value: "never" },
                        { displayName: Translation.tr("On overflow"), icon: "align_horizontal_center", value: "on-overflow" },
                        { displayName: Translation.tr("Always"), icon: "center_focus_strong", value: "always" }
                    ]
                    onSelected: newValue => {
                        root.setConfig("layout", "center-focused-column", newValue)
                    }
                }
            }

            SettingsDivider {}

            ContentSubsection {
                title: Translation.tr("Window border")
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "border_style"
                text: Translation.tr("Enable border")
                checked: root.layoutData?.border?.enabled ?? false
                onCheckedChanged: {
                    if (!root.layoutReady) return
                    root.setConfig("layout", "border.enabled", checked ? "on" : "off")
                }
            }

            ContentSubsection {
                title: Translation.tr("Border width")
                visible: root.layoutData?.border?.enabled ?? false

                ConfigSpinBox {
                    text: Translation.tr("Width (px)")
                    value: root.layoutData?.border?.width ?? 2
                    from: 1
                    to: 8
                    stepSize: 1
                    onValueChanged: {
                        if (!root.layoutReady) return
                        root.setConfig("layout", "border.width", value)
                    }
                }
            }

            SettingsDivider {}

            ContentSubsection {
                title: Translation.tr("Focus ring")
            }

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "radio_button_checked"
                text: Translation.tr("Enable focus ring")
                checked: root.layoutData?.focus_ring?.enabled ?? false
                onCheckedChanged: {
                    if (!root.layoutReady) return
                    root.setConfig("layout", "focus-ring.enabled", checked ? "on" : "off")
                }
            }

            ContentSubsection {
                title: Translation.tr("Focus ring width")
                visible: root.layoutData?.focus_ring?.enabled ?? false

                ConfigSpinBox {
                    text: Translation.tr("Width (px)")
                    value: root.layoutData?.focus_ring?.width ?? 4
                    from: 1
                    to: 8
                    stepSize: 1
                    onValueChanged: {
                        if (!root.layoutReady) return
                        root.setConfig("layout", "focus-ring.width", value)
                    }
                }
            }

            SettingsDivider {}

            SettingsSwitch {
                Layout.fillWidth: true
                buttonIcon: "shadow"
                text: Translation.tr("Window shadow")
                checked: root.layoutData?.shadow?.enabled ?? false
                onCheckedChanged: {
                    if (!root.layoutReady) return
                    root.setConfig("layout", "shadow.enabled", checked ? "on" : "off")
                }
            }

            SettingsDivider {}

            ContentSubsection {
                title: Translation.tr("Overview zoom")
                tooltip: Translation.tr("How much workspaces are scaled in the overview")

                ConfigSpinBox {
                    text: Translation.tr("Zoom (%)")
                    value: Math.round((root.layoutData?.overview_zoom ?? 0.7) * 100)
                    from: 30
                    to: 100
                    stepSize: 5
                    onValueChanged: {
                        if (!root.layoutReady) return
                        root.setConfig("layout", "overview.zoom", (value / 100.0).toFixed(2))
                    }
                }
            }
        }
    }
}
