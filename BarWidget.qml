import QtQuick
import qs.Commons
import qs.Ui

// Mirrors the first-party weather widget: the bar mounts this, and the
// detail view is a Panel loaded underneath it.
BarWidget {
  id: root
  moduleName: "joelgaff.hatchbox"

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
  }
  function refresh() { if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    // The Hatchbox mark takes the theme foreground, and the urgent color
    // while any app's latest deploy has failed.
    iconComponent: Component {
      HatchboxMark {
        iconSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }
    active: panelLoader.item ? panelLoader.item.anyFailed === true : false
    activeColor: panelLoader.item && panelLoader.item.failedColor !== undefined ? panelLoader.item.failedColor : (root.bar ? root.bar.urgent : Color.urgent)
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Hatchbox"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
