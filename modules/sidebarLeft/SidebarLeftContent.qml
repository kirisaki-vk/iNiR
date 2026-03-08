import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.sidebarLeft.animeSchedule
import qs.modules.sidebarLeft.reddit
import qs.modules.sidebarLeft.plugins
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QtQuick.Effects
import Qt5Compat.GraphicalEffects as GE

Item {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    property int sidebarPadding: 10
    property int screenWidth: 1920
    property int screenHeight: 1080
    property var panelScreen: null

    // Delay content loading until after animation completes
    property bool contentReady: false

    Connections {
        target: GlobalStates
        function onSidebarLeftOpenChanged() {
            if (GlobalStates.sidebarLeftOpen) {
                root.contentReady = false
                contentDelayTimer.restart()
            }
            // WebApps keep running in background — audio, WebSockets, etc.
            // stay alive even when sidebar is closed. No freeze/resume.
        }
    }

    Timer {
        id: contentDelayTimer
        interval: 200
        onTriggered: root.contentReady = true
    }

    property bool aiChatEnabled: (Config.options?.policies?.ai ?? 0) !== 0
    property bool translatorEnabled: (Config.options?.sidebar?.translator?.enable ?? false)
    property bool animeEnabled: (Config.options?.policies?.weeb ?? 0) !== 0
    property bool animeCloset: (Config.options?.policies?.weeb ?? 0) === 2
    property bool animeScheduleEnabled: Config.options?.sidebar?.animeSchedule?.enable ?? false
    property bool redditEnabled: Config.options?.sidebar?.reddit?.enable ?? false
    property bool wallhavenEnabled: Config.options?.sidebar?.wallhaven?.enable !== false
    property bool widgetsEnabled: Config.options?.sidebar?.widgets?.enable ?? true
    property bool toolsEnabled: Config.options?.sidebar?.tools?.enable ?? false
    property bool ytMusicEnabled: Config.options?.sidebar?.ytmusic?.enable ?? false
    property bool pluginsEnabled: Config.options?.sidebar?.plugins?.enable ?? false

    // ─── WebApp state (lives HERE, survives contentReady resets) ──────
    // Currently active webapp plugin id (empty = no webapp showing)
    property string _activeWebAppId: ""
    // Signals to SidebarLeft for width resize
    property bool pluginViewActive: _activeWebAppId !== ""

    // Persistent cache: pluginId → WebAppView instance
    // These NEVER get destroyed by contentReady or SwipeView lifecycle
    property var _webViewCache: ({})
    property int _webViewCount: 0  // for reactivity

    // Persistent cache: pluginId → WebEngineProfile
    // Created BEFORE the WebAppView so storageName is set from the start.
    // This avoids the off-the-record → disk-based transition that breaks cookies.
    property var _profileCache: ({})

    function _getOrCreateProfile(id: string): QtObject {
        if (root._profileCache[id]) return root._profileCache[id]
        // storageName MUST be in the QML declaration — if set imperatively
        // after construction, the C++ constructor starts off-the-record and
        // cookies get corrupted during the transition.
        const escaped = id.replace(/"/g, '\\"')
        const profile = Qt.createQmlObject(
            'import QtWebEngine; WebEngineProfile { storageName: "' + escaped + '"; offTheRecord: false; httpCacheType: WebEngineProfile.DiskHttpCache; persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies }',
            root, "pluginProfile_" + id
        )
        root._profileCache[id] = profile
        return profile
    }

    // ─── WebApp management functions ─────────────────────────────────

    function openWebApp(id: string, url: string, name: string, icon: string, userscriptSources): void {
        // Hide previously active webapp (but keep it running in background)
        if (root._activeWebAppId && root._webViewCache[root._activeWebAppId]) {
            root._webViewCache[root._activeWebAppId].visible = false
        }

        // Get or create the WebAppView
        let view = root._webViewCache[id]
        if (!view) {
            // Create profile FIRST with storageName already set
            const profile = root._getOrCreateProfile(id)

            const comp = Qt.createComponent("plugins/WebAppView.qml")
            if (comp.status !== Component.Ready) {
                console.error("[Plugins] Failed to create WebAppView:", comp.errorString())
                return
            }
            view = comp.createObject(webAppOverlay, {
                pluginId: id,
                pluginUrl: url,
                pluginName: name,
                pluginIcon: icon,
                webProfile: profile,
                userscriptSources: userscriptSources ?? [],
                visible: false
            })
            if (!view) {
                console.error("[Plugins] createObject returned null for", id)
                return
            }
            view.anchors.fill = webAppOverlay
            view.closeRequested.connect(() => root.closeWebApp())
            root._webViewCache[id] = view
            root._webViewCount++
        }

        // Show it
        view.visible = true
        root._activeWebAppId = id

        // Save to config for state restoration
        Config.setNestedValue("sidebar.plugins.lastActivePlugin", id)
    }

    function closeWebApp(): void {
        if (root._activeWebAppId && root._webViewCache[root._activeWebAppId]) {
            root._webViewCache[root._activeWebAppId].visible = false
        }
        root._activeWebAppId = ""
        // Keep lastActivePlugin in config — next sidebar open restores it
        // Only clear it if user explicitly navigates away
    }

    function removeWebApp(id: string): void {
        const view = root._webViewCache[id]
        if (view) {
            view.destroy()
            delete root._webViewCache[id]
            root._webViewCount--
        }
        // Also destroy cached profile
        const profile = root._profileCache[id]
        if (profile) {
            profile.destroy()
            delete root._profileCache[id]
        }
        if (root._activeWebAppId === id) {
            root._activeWebAppId = ""
            Config.setNestedValue("sidebar.plugins.lastActivePlugin", "")
        }
    }

    function _freezeAllWebApps(): void {
        for (const id in root._webViewCache) {
            const view = root._webViewCache[id]
            if (view) view.frozen = true
        }
    }

    function _resumeActiveWebApp(): void {
        for (const id in root._webViewCache) {
            const view = root._webViewCache[id]
            if (view) view.frozen = (id !== root._activeWebAppId)
        }
    }

    // ─── Restore last active plugin from config ──────────────────────
    property bool _restoredLastPlugin: false

    function _tryRestoreLastPlugin(): void {
        if (root._restoredLastPlugin) return
        root._restoredLastPlugin = true

        const lastId = Config.options?.sidebar?.plugins?.lastActivePlugin ?? ""
        if (!lastId) return

        // Find the plugin in the discovered list (PluginsTab populates via scan)
        // We need to defer until PluginsTab has scanned — use a timer
        restoreTimer.restart()
    }

    Timer {
        id: restoreTimer
        interval: 500
        onTriggered: root._doRestoreLastPlugin()
    }

    function _doRestoreLastPlugin(): void {
        const lastId = Config.options?.sidebar?.plugins?.lastActivePlugin ?? ""
        if (!lastId) return

        // Check if we already have it cached (from a previous session's WebEngine)
        if (root._webViewCache[lastId]) {
            root._webViewCache[lastId].visible = true
            root._webViewCache[lastId].frozen = false
            root._activeWebAppId = lastId
            return
        }

        // Look up the plugin manifest data — scan-plugins.py stores them
        // We need the URL from the manifest. Read it from the plugins list
        // that PluginsTab populates, which is now available via the signal flow.
        // For now, read manifest directly.
        restoreProcess.command = ["/usr/bin/python3", Quickshell.shellPath("scripts/scan-plugins.py")]
        restoreProcess.running = true
    }

    Process {
        id: restoreProcess
        stdout: SplitParser {
            onRead: data => {
                try {
                    const plugins = JSON.parse(data)
                    const lastId = Config.options?.sidebar?.plugins?.lastActivePlugin ?? ""
                    const plugin = plugins.find(p => p.id === lastId)
                    if (plugin) {
                        root.openWebApp(
                            plugin.id ?? "",
                            plugin.url ?? "",
                            plugin.name ?? plugin.id ?? "Plugin",
                            plugin.icon ?? "language",
                            plugin.userscriptSources ?? []
                        )
                    }
                } catch(e) {
                    console.warn("[Plugins] Failed to restore last plugin:", e)
                }
            }
        }
    }

    // Tab button list - simple static order
    property var tabButtonList: {
        const result = []
        if (root.widgetsEnabled) result.push({ icon: "widgets", name: Translation.tr("Widgets") })
        if (root.aiChatEnabled) result.push({ icon: "neurology", name: Translation.tr("Intelligence") })
        if (root.translatorEnabled) result.push({ icon: "translate", name: Translation.tr("Translator") })
        if (root.animeEnabled && !root.animeCloset) result.push({ icon: "bookmark_heart", name: Translation.tr("Anime") })
        if (root.animeScheduleEnabled) result.push({ icon: "calendar_month", name: Translation.tr("Schedule") })
        if (root.redditEnabled) result.push({ icon: "forum", name: Translation.tr("Reddit") })
        if (root.wallhavenEnabled) result.push({ icon: "collections", name: Translation.tr("Wallhaven") })
        if (root.ytMusicEnabled) result.push({ icon: "library_music", name: Translation.tr("YT Music") })
        if (root.toolsEnabled) result.push({ icon: "build", name: Translation.tr("Tools") })
        if (root.pluginsEnabled) result.push({ icon: "extension", name: Translation.tr("Web Apps") })
        return result
    }

    // Find the index of the plugins tab
    readonly property int _pluginsTabIndex: {
        for (let i = 0; i < tabButtonList.length; i++) {
            if (tabButtonList[i].icon === "extension") return i
        }
        return -1
    }

    function focusActiveItem() {
        swipeView.currentItem?.forceActiveFocus()
    }

    implicitHeight: sidebarLeftBackground.implicitHeight
    implicitWidth: sidebarLeftBackground.implicitWidth

    StyledRectangularShadow {
        target: sidebarLeftBackground
        visible: !Appearance.gameModeMinimal
    }
    Rectangle {
        id: sidebarLeftBackground

        anchors.fill: parent
        implicitHeight: parent.height - Appearance.sizes.hyprlandGapsOut * 2
        implicitWidth: sidebarWidth - Appearance.sizes.hyprlandGapsOut * 2
        property bool cardStyle: Config.options?.sidebar?.cardStyle ?? false
        readonly property bool angelEverywhere: Appearance.angelEverywhere
        readonly property bool auroraEverywhere: Appearance.auroraEverywhere
        readonly property bool gameModeMinimal: Appearance.gameModeMinimal
        readonly property string wallpaperUrl: {
            const _dep1 = WallpaperListener.multiMonitorEnabled
            const _dep2 = WallpaperListener.effectivePerMonitor
            const _dep3 = Wallpapers.effectiveWallpaperUrl
            return WallpaperListener.wallpaperUrlForScreen(root.panelScreen)
        }

        ColorQuantizer {
            id: sidebarLeftWallpaperQuantizer
            source: sidebarLeftBackground.wallpaperUrl
            depth: 0
            rescaleSize: 10
        }

        readonly property color wallpaperDominantColor: (sidebarLeftWallpaperQuantizer?.colors?.[0] ?? Appearance.colors.colPrimary)
        readonly property QtObject blendedColors: AdaptedMaterialScheme {
            color: ColorUtils.mix(sidebarLeftBackground.wallpaperDominantColor, Appearance.colors.colPrimaryContainer, 0.8) || Appearance.m3colors.m3secondaryContainer
        }

        color: gameModeMinimal ? "transparent"
             : auroraEverywhere ? ColorUtils.applyAlpha((blendedColors?.colLayer0 ?? Appearance.colors.colLayer0), 1)
             : (cardStyle ? Appearance.colors.colLayer1 : Appearance.colors.colLayer0)
        border.width: gameModeMinimal ? 0 : (angelEverywhere ? Appearance.angel.panelBorderWidth : 1)
        border.color: angelEverywhere ? Appearance.angel.colPanelBorder
            : Appearance.inirEverywhere ? Appearance.inir.colBorder
            : Appearance.colors.colLayer0Border
        radius: angelEverywhere ? Appearance.angel.roundingNormal
            : Appearance.inirEverywhere ? Appearance.inir.roundingNormal
            : cardStyle ? Appearance.rounding.normal : (Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1)

        clip: true

        layer.enabled: auroraEverywhere && !gameModeMinimal
        layer.effect: GE.OpacityMask {
            maskSource: Rectangle {
                width: sidebarLeftBackground.width
                height: sidebarLeftBackground.height
                radius: sidebarLeftBackground.radius
            }
        }

        Image {
            id: sidebarLeftBlurredWallpaper
            x: -Appearance.sizes.hyprlandGapsOut
            y: -Appearance.sizes.hyprlandGapsOut
            width: root.screenWidth
            height: root.screenHeight
            visible: sidebarLeftBackground.auroraEverywhere && !sidebarLeftBackground.gameModeMinimal
            source: sidebarLeftBackground.wallpaperUrl
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true

            layer.enabled: Appearance.effectsEnabled && !sidebarLeftBackground.gameModeMinimal
            layer.effect: MultiEffect {
                source: sidebarLeftBlurredWallpaper
                anchors.fill: source
                saturation: sidebarLeftBackground.angelEverywhere
                    ? (Appearance.angel.blurSaturation * Appearance.angel.colorStrength)
                    : (Appearance.effectsEnabled ? 0.2 : 0)
                blurEnabled: Appearance.effectsEnabled
                blurMax: 100
                blur: Appearance.effectsEnabled
                    ? (sidebarLeftBackground.angelEverywhere ? Appearance.angel.blurIntensity : 1)
                    : 0
            }

            Rectangle {
                anchors.fill: parent
                color: sidebarLeftBackground.angelEverywhere
                    ? ColorUtils.transparentize((sidebarLeftBackground.blendedColors?.colLayer0 ?? Appearance.colors.colLayer0Base), Appearance.angel.overlayOpacity * Appearance.angel.panelTransparentize)
                    : ColorUtils.transparentize((sidebarLeftBackground.blendedColors?.colLayer0 ?? Appearance.colors.colLayer0Base), Appearance.aurora.overlayTransparentize)
            }
        }

        // Angel inset glow — top edge
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Appearance.angel.insetGlowHeight
            visible: sidebarLeftBackground.angelEverywhere
            color: Appearance.angel.colInsetGlow
            z: 10
        }

        // Angel partial border — elegant half-borders
        AngelPartialBorder {
            targetRadius: sidebarLeftBackground.radius
            z: 10
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: sidebarPadding
            anchors.topMargin: Appearance.angelEverywhere ? sidebarPadding + 4
                : Appearance.inirEverywhere ? sidebarPadding + 6 : sidebarPadding
            spacing: Appearance.angelEverywhere ? sidebarPadding + 2
                : Appearance.inirEverywhere ? sidebarPadding + 4 : sidebarPadding

            // Tab bar — hidden when webapp is fullscreen in sidebar
            Toolbar {
                id: toolbarContainer
                Layout.alignment: Qt.AlignHCenter
                enableShadow: false
                transparent: Appearance.auroraEverywhere || Appearance.inirEverywhere
                visible: !root.pluginViewActive
                ToolbarTabBar {
                    id: tabBar
                    Layout.alignment: Qt.AlignHCenter
                    maxWidth: Math.max(0, root.width - (root.sidebarPadding * 2) - 16)
                    tabButtonList: root.tabButtonList
                    // Don't bind to swipeView - let tabBar be the source of truth
                    onCurrentIndexChanged: swipeView.currentIndex = currentIndex
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Appearance.angelEverywhere ? Appearance.angel.roundingNormal
                    : Appearance.inirEverywhere ? Appearance.inir.roundingNormal : Appearance.rounding.normal
                color: Appearance.angelEverywhere ? Appearance.angel.colGlassCard
                    : Appearance.inirEverywhere ? Appearance.inir.colLayer1
                     : Appearance.auroraEverywhere ? "transparent"
                     : Appearance.colors.colLayer1
                border.width: Appearance.angelEverywhere ? Appearance.angel.cardBorderWidth
                    : Appearance.inirEverywhere ? 1 : 0
                border.color: Appearance.angelEverywhere ? Appearance.angel.colCardBorder
                    : Appearance.inirEverywhere ? Appearance.inir.colBorder : "transparent"

                // SwipeView with normal tab content
                SwipeView {
                    id: swipeView
                    anchors.fill: parent
                    spacing: 10
                    visible: !root.pluginViewActive
                    // Sync back to tabBar when swiping
                    onCurrentIndexChanged: {
                        tabBar.setCurrentIndex(currentIndex)
                        const currentTab = root.tabButtonList[currentIndex]
                        if (currentTab?.icon === "neurology") {
                            Ai.ensureInitialized()
                        }
                    }
                    interactive: !(currentItem?.item?.editMode ?? false) && !(currentItem?.item?.dragPending ?? false)

                    clip: true
                    layer.enabled: root.contentReady
                    layer.effect: GE.OpacityMask {
                        maskSource: Rectangle {
                            width: swipeView.width
                            height: swipeView.height
                            radius: Appearance.rounding.small
                        }
                    }

                    Repeater {
                        model: root.contentReady ? root.tabButtonList : []
                        delegate: Loader {
                            required property var modelData
                            required property int index
                            active: SwipeView.isCurrentItem || SwipeView.isNextItem || SwipeView.isPreviousItem
                            sourceComponent: {
                                switch (modelData.icon) {
                                    case "widgets": return widgetsComp
                                    case "neurology": return aiChatComp
                                    case "translate": return translatorComp
                                    case "bookmark_heart": return animeComp
                                    case "calendar_month": return animeScheduleComp
                                    case "forum": return redditComp
                                    case "collections": return wallhavenComp
                                    case "library_music": return ytMusicComp
                                    case "build": return toolsComp
                                    case "extension": return pluginsComp
                                    default: return null
                                }
                            }
                        }
                    }
                }

                // ── WebApp overlay ───────────────────────────────────
                // WebAppViews live HERE, above the SwipeView.
                // They survive contentReady resets and SwipeView destruction.
                // Visibility controlled by: active webapp + sidebar open state.
                Item {
                    id: webAppOverlay
                    anchors.fill: parent
                    visible: root.pluginViewActive && GlobalStates.sidebarLeftOpen
                    z: 5
                }
            }
        }

        Component { id: widgetsComp; WidgetsView {} }
        Component { id: aiChatComp; AiChat {} }
        Component { id: translatorComp; Translator {} }
        Component { id: animeComp; Anime {} }
        Component { id: animeScheduleComp; AnimeScheduleView {} }
        Component { id: redditComp; RedditView {} }
        Component { id: wallhavenComp; WallhavenView {} }
        Component { id: ytMusicComp; YtMusicView {} }
        Component { id: toolsComp; ToolsView {} }
        Component {
            id: pluginsComp
            PluginsTab {
                activePluginId: root._activeWebAppId
                onPluginRequested: (id, url, name, icon, userscriptSources) => root.openWebApp(id, url, name, icon, userscriptSources)
                onPluginCloseRequested: root.closeWebApp()
                onPluginRemoved: (id) => root.removeWebApp(id)
            }
        }

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                // If webapp is open, close it first (go back to list)
                if (root.pluginViewActive) {
                    root.closeWebApp()
                    event.accepted = true
                    return
                }
                GlobalStates.sidebarLeftOpen = false
            }
            if (event.modifiers === Qt.ControlModifier) {
                if (event.key === Qt.Key_PageDown) {
                    swipeView.incrementCurrentIndex()
                    event.accepted = true
                }
                else if (event.key === Qt.Key_PageUp) {
                    swipeView.decrementCurrentIndex()
                    event.accepted = true
                }
            }
        }
    }

    // ── Restore last active plugin on first load ─────────────────────
    Connections {
        target: Config
        function onReadyChanged() {
            if (Config.ready && root.pluginsEnabled) {
                root._tryRestoreLastPlugin()
            }
        }
    }

    Component.onCompleted: {
        if (Config.ready && root.pluginsEnabled) {
            root._tryRestoreLastPlugin()
        }
    }
}
