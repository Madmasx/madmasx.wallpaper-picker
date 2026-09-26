import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "madmasx.wallpaper-picker"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false

  function open() {
    if (panelLoader.item && panelLoader.item.open)
      panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close)
      panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle)
      panelLoader.item.toggle()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
  }

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("WallpaperManager.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸌"
    horizontalMargin: 7.5
    tooltipText: "Wallpaper picker"
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.LeftButton) root.toggle()
    }
  }
}
