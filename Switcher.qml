import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Keyboard-first window switcher overlay with a live window peek.
//
// Opened with `omarchy-shell shell toggle piyush.omaswitch` (bind it to
// a key in ~/.config/hypr/bindings.lua). Lists Hyprland toplevels from the
// Quickshell Hyprland singleton, filters live as you type, and focuses the
// selection through the native Wayland toplevel API, with hyprctl as fallback.
//
// The right side shows a live preview (Windows-11-style "peek") of the
// highlighted window via two alternating ScreencopyViews. The current frame
// stays visible while the inactive view starts capturing the next selection,
// then the views swap once the new frame is ready. If the compositor lacks the
// hyprland-toplevel-export protocol (or the views get no frames), hasContent
// stays false and the list simply stays full-width —
// the same layout as the plain list version.

Item {
  id: root

  property var shell: null
  property var manifest: null

  // The plugin host hides us by calling close() after removing us from
  // openPanelIds; we must not fight it, so `opened` is only our UI state.
  property bool opened: false
  property bool cycleMode: false
  property string filterText: ""
  property int selectedIndex: 0

  // Raw toplevels (live objects from the Hyprland singleton) + filtered rows.
  property var allWindows: []
  property var rows: []

  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int rowHeight: Math.max(Style.space(48), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int listGap: Style.space(4)
  readonly property int gap: Style.space(12)

  // Guard the index: assigning a shorter rows array notifies bindings before
  // rebuildRows() gets to clamp selectedIndex.
  readonly property var selectedToplevel: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null
  property bool previewAvailable: false
  property var previewSourceA: null
  property var previewSourceB: null
  property int activePreview: -1
  property int pendingPreview: -1
  readonly property bool previewWanted: root.opened && root.selectedToplevel !== null && !!root.selectedToplevel.wayland
  // Diagnostic: freeze the capture target after opening. Selection may move,
  // but screencopy does not. This isolates selection rendering from capture.
  property var previewTarget: null
  // Once a preview has appeared, keep the pane mounted for the rest of this
  // opening. selectedToplevel.wayland can change or briefly be unavailable
  // while selection moves; that must not collapse and rebuild the card.
  readonly property bool previewActive: root.opened && root.previewAvailable

  // Diagnostic: make the card geometry completely invariant while open.
  // This intentionally gives up the list-only compact fallback for the test.
  readonly property int cardWidth: Math.min(Style.space(1400), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(800), panel.height - Style.gapsOut * 2)
  readonly property int contentHeight: Math.max(0, root.cardHeight - root.contentMargin * 2)
  readonly property int innerWidth: Math.max(0, root.cardWidth - root.contentMargin * 2)
  readonly property int listWidth: Math.max(Style.space(300), Math.round(root.innerWidth * 0.40))
  readonly property int previewWidth: Math.max(0, root.innerWidth - root.listWidth - root.gap)
  readonly property int listHeight: Math.max(0, root.contentHeight - root.headerHeight - root.listGap)
  // Positive before the pane appears, so ScreencopyView can obtain its first
  // frame and flip hasContent without depending on a zero-sized parent.
  readonly property int previewConstraintWidth: Math.max(1, Math.min(Style.space(580), panel.width - Style.space(420)))
  readonly property int previewConstraintHeight: Math.max(1, Math.min(Style.space(360), panel.height - Style.gapsOut * 2 - root.contentMargin * 2))

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  function logGeometry(reason) {
    console.log("omaswitch-geometry",
      reason,
      "selectedIndex=" + root.selectedIndex,
      "rows=" + root.rows.length,
      "opened=" + root.opened,
      "previewAvailable=" + root.previewAvailable,
      "previewActive=" + root.previewActive,
      "cardWidth=" + root.cardWidth,
      "cardHeight=" + root.cardHeight,
      "listWidth=" + root.listWidth,
      "previewWidth=" + root.previewWidth,
      "panelWidth=" + panel.width,
      "panelHeight=" + panel.height)
  }

  onSelectedIndexChanged: root.logGeometry("selectedIndex")
  onPreviewAvailableChanged: root.logGeometry("previewAvailable")
  onPreviewActiveChanged: root.logGeometry("previewActive")
  onCardWidthChanged: root.logGeometry("cardWidth")
  onCardHeightChanged: root.logGeometry("cardHeight")
  onRowsChanged: root.logGeometry("rows")

  function queuePreview(source) {
    if (!root.opened || !source) return

    // If the user cycles back to the frame already on screen, keep it and
    // cancel any in-flight capture in the other buffer.
    if (root.activePreview === 0 && root.previewSourceA === source) {
      root.pendingPreview = -1
      return
    }
    if (root.activePreview === 1 && root.previewSourceB === source) {
      root.pendingPreview = -1
      return
    }

    var next = root.activePreview === 0 ? 1 : 0
    if (root.activePreview < 0) next = 0

    root.pendingPreview = next
    if (next === 0)
      root.previewSourceA = source
    else
      root.previewSourceB = source
  }

  function previewReady(index) {
    if (root.pendingPreview !== index) return

    var source = index === 0 ? root.previewSourceA : root.previewSourceB
    if (!source || source !== root.previewTarget) return

    // True ping-pong buffering: never clear the previous buffer here.
    // Keep it intact behind the new one; the next selection will retarget
    // whichever buffer is inactive. This avoids tearing a capture node down
    // in the same scene-graph update that promotes the new one.
    root.activePreview = index
    root.pendingPreview = -1
    root.previewAvailable = true
  }

  function rebuildRows() {
    rows = Model.filteredWindows(allWindows, filterText)
    if (selectedIndex >= rows.length) selectedIndex = Math.max(0, rows.length - 1)
    if (selectedIndex < 0 && rows.length > 0) selectedIndex = 0
  }

  function setFilter(value) {
    filterText = value
    selectedIndex = 0
    rebuildRows()
  }

  function refresh() {
    allWindows = Model.sortedWindows(Hyprland.toplevels.values)
    rebuildRows()
  }

  function focusSelected() {
    root.dismiss()
  }

  function select(delta) {
    selectedIndex = (selectedIndex + delta + 10) % 10
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var direction = Number(payload.direction) < 0 ? -1 : 1

    // Repeated Alt+Tab summons cycle instead of resetting or closing.
    if (root.opened && payload.mode === "cycle") {
      root.cycleMode = true
      root.select(direction)
      return
    }

    root.previewAvailable = false
    root.previewTarget = null
    root.activePreview = -1
    root.pendingPreview = -1
    root.previewSourceA = null
    root.previewSourceB = null
    root.opened = true
    root.cycleMode = payload.mode === "cycle"
    root.filterText = ""
    root.selectedIndex = 0
    root.refresh()
    root.selectedIndex = 0
    root.previewTarget = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.cycleMode = false
  }

  // User-initiated dismissal also drops the host's openPanelIds entry.
  function dismiss() {
    root.opened = false
    root.cycleMode = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "piyush.omaswitch")
  }

  // Keep the window snapshot fixed while the switcher is open. Replacing the
  // ListView model in response to compositor events can transiently change the
  // row count and therefore the card geometry. A fresh snapshot is taken on
  // every open instead.

  PanelWindow {
    id: panel
    visible: root.opened
    onWidthChanged: root.logGeometry("panelWidth")
    onHeightChanged: root.logGeometry("panelHeight")
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "piyush-omaswitch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec

      Item {
        anchors.fill: parent
        anchors.margins: root.contentMargin

        Rectangle {
          anchors.fill: parent
          radius: 0
          color: "#ff00ff"

          Column {
            anchors.centerIn: parent
            spacing: Style.space(24)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "OMASWITCH DIAGNOSTIC BUILD"
              color: "black"
              font.bold: true
              font.pixelSize: Style.font.title * 3
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "COMMIT MARKER: RADICAL-VERIFY-1"
              color: "black"
              font.bold: true
              font.pixelSize: Style.font.title * 2
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Selection " + root.selectedIndex
              color: "black"
              font.pixelSize: Style.font.title * 4
            }
          }
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      z: 1
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.focusSelected()
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
          root.select((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }

      // Best-effort native Alt-Tab behavior. If the compositor delivers the
      // modifier release after granting this overlay focus, commit selection.
      Keys.onReleased: function(event) {
        if (root.cycleMode && (event.key === Qt.Key_Alt || event.key === Qt.Key_Meta)) {
          root.focusSelected()
          event.accepted = true
        }
      }
    }
  }
}
