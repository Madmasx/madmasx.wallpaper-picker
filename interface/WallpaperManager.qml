import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick 6.11
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import qs.Commons

Item {
  id: root

  // Catálogos propios del plugin (interface/i18n/<código>.json). Omarchy pasa
  // el idioma elegido en Setup > Language y reevalúa los bindings al cambiarlo,
  // así que la interfaz sigue el idioma del sistema sin reiniciar el shell.
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property bool opened: false
  property string home: Quickshell.env("HOME")
  readonly property string stateHome: root.home + "/.local/state"
  readonly property string themeNameFile: root.stateHome + "/omarchy/current/theme.name"
  readonly property string currentBgLink: root.stateHome + "/omarchy/current/background"

  property string themeName: ""
  // Omarchy guarda los fondos del usuario en ~/.config/omarchy/backgrounds/<tema>/
  // y los del tema ya aplicado en ~/.local/state/omarchy/current/theme/backgrounds/.
  // Los temas propios (como dark-carbon) guardan sus fondos en
  // ~/.config/omarchy/themes/<tema>/backgrounds/; también se listan para poder
  // borrarlos desde el picker.
  readonly property string userBgDir: root.home + "/.config/omarchy/backgrounds/" + root.themeName
  readonly property string themeUserDir: root.home + "/.config/omarchy/themes/" + root.themeName + "/backgrounds"
  readonly property string liveBgDir: root.stateHome + "/omarchy/current/theme/backgrounds"
  readonly property string themeDir: root.userBgDir
  readonly property string themeSysDir: "/usr/share/omarchy/themes/" + root.themeName + "/backgrounds"
  property var images: []
  property var themeList: []
  property string filterKind: "all"
  readonly property int visibleCount: {
    var c = 0
    for (var i = 0; i < root.images.length; i++)
      if (root.filterKind === "all" || root.images[i].kind === root.filterKind) c++
    return c
  }
  property var monitors: []
  property string currentMonitor: ""
  property int currentIndex: -1
  property string activeBackground: ""
  property bool applyVideoActive: false
  property bool videoSoundActive: false
  // Qué vídeo está realmente en pantalla (no el que esté seleccionado en la
  // rejilla) y si trae pista de audio. Sin esto el botón ♪ no sabía a qué
  // fondo conmutar y mentía en vídeos mudos.
  property string activeVideoPath: ""
  property string activeVideoMonitor: ""
  property bool activeVideoHasAudio: false
  readonly property bool soundAvailable: root.activeVideoPath === "" || root.activeVideoHasAudio
  property bool importDialogActive: false
  property bool importReopen: false
  property bool currentRemovable: false
  property string pendingRemove: ""

  // Pausa automática del vídeo cuando una ventana tapa el monitor.
  property bool autoPause: true
  property bool autoPauseWriting: false
  property var pausedNow: ({})
  readonly property string ipcDir: root.stateHome
    + "/omarchy/plugins/madmasx.wallpaper-picker/ipc"
  readonly property string autoPauseFile: root.stateHome
    + "/omarchy/plugins/madmasx.wallpaper-picker/autopause"

  onCurrentIndexChanged: root.currentRemovable =
    root.isRemovable(root.currentIndex >= 0 ? root.images[root.currentIndex] : null)
  onImagesChanged: root.currentRemovable =
    root.isRemovable(root.currentIndex >= 0 ? root.images[root.currentIndex] : null)

  // Stubs for the injections BarWidget sends (bar) so injectPanel() stays clean.
  property var bar: null
  // Monitor donde se coloca el panel; lo fija el shell al abrir (monitor con foco).
  property var panelScreen: null

  readonly property var imageExts: ["jpg", "jpeg", "png", "gif", "bmp", "webp"]
  readonly property var videoExts: ["mkv", "mp4", "webm", "avi"]

  // Paleta del tema aplicado (qs.Commons). imagePicker/popups son superficies
  // definidas en shell.toml del tema; se recargan en vivo al cambiar de tema.
  readonly property color bg: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color fg: Color.popups.text
  readonly property color borderColor: Color.popups.border
  // El picker nativo de Omarchy ya no trae backdrop: `Color.imagePicker.scrim`
  // desapareció de Commons/Color.qml, así que la vinculación quedaba inválida y
  // Qt pintaba el scrim en negro opaco. Se deriva del fondo del tema con la
  // misma alpha que usan los otros scrims (menu/polkit/lock: 0.5).
  readonly property color scrimColor: Util.alpha(Color.background, 0.5)
  readonly property color selectedTileColor: Color.imagePicker.selectedBorder
  readonly property color unselectedTileColor: Color.imagePicker.unselectedBorder

  readonly property string statusText: root.applyVideoActive
    ? strings.t("status.video").arg(root.currentMonitor || "?")
    : (root.activeBackground
        ? strings.t("status.image").arg(root.baseName(root.activeBackground))
        : strings.t("status.none"))

  // Alterna el audio del vídeo en pantalla. Se hace por el socket IPC de mpv
  // (aid auto/no): antes se mataba y relanzaba mpvpaper, y el monitor se
  // quedaba sin fondo mientras el layer surface viejo soltaba el output.
  function setSound(on) {
    root.videoSoundActive = !!on
    console.log("[picker.WM] sonido " + (root.videoSoundActive ? "ON" : "OFF"))
    root.persistSound(root.videoSoundActive)
    if (!root.applyVideoActive || root.activeVideoPath === "") return
    if (!root.activeVideoHasAudio) {
      console.log("[picker.WM] el vídeo activo no tiene pista de audio")
      return
    }
    var m = root.activeVideoMonitor || root.currentMonitor
    if (!m) return
    var fallback = root.currentMonitor || m
    var want = root.videoSoundActive ? "auto" : "no"
    // Se prueban los dos sockets posibles y se usa el que responda: el del
    // monitor guardado puede ser un archivo muerto de una sesión anterior.
    soundProc.command = ["bash", "-c",
      "s1=" + root.shq(root.monSocket(m)) + "; "
      + "s2=" + root.shq(root.monSocket(fallback)) + "; live=\"\"; "
      + "for s in \"$s1\" \"$s2\"; do "
      + "r=$(printf '{\"command\":[\"get_property\",\"aid\"]}\\n' | socat - UNIX-CONNECT:\"$s\" 2>/dev/null); "
      + "case \"$r\" in *'\"error\":\"success\"'*) live=\"$s\"; break;; esac; "
      + "done; "
      + "[ -n \"$live\" ] || exit 1; "
      + "printf '{\"command\":[\"set_property\",\"aid\",\"" + want + "\"]}\\n' "
      + "| socat - UNIX-CONNECT:\"$live\" >/dev/null 2>&1; "
      + "printf '{\"command\":[\"get_property\",\"aid\"]}\\n' | socat - UNIX-CONNECT:\"$live\" 2>/dev/null"]
    soundProc.running = true
  }

  // Lee de vuelta `aid` para que el botón no mienta si mpv rechazó el cambio.
  Process {
    id: soundProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "")
        if (t.indexOf("\"error\":\"success\"") === -1) {
          console.log("[picker.WM] ningún socket IPC de mpv respondió")
          return
        }
        var off = t.indexOf("\"data\":false") !== -1
        var on = /"data":\s*\d/.test(t)
        if ((off || on) && root.videoSoundActive !== on) {
          root.videoSoundActive = on
          root.persistSound(on)
        }
      }
    }
  }

  // Deja la preferencia en el estado de vídeo para que la restauración de
  // sesión relance el fondo con el audio correcto.
  function persistSound(on) {
    var st = root.videoStateFile
    persistSoundProc.command = ["bash", "-c",
      "st=" + root.shq(st) + "; [ -f \"$st\" ] || exit 0; "
      + "awk -F'\\t' -v s=" + (on ? 1 : 0) + " 'BEGIN{OFS=\"\\t\"} NF>=3 { $3=s } { print }' "
      + "\"$st\" > \"$st.tmp\" && mv \"$st.tmp\" \"$st\""]
    persistSoundProc.running = true
  }

  Process {
    id: persistSoundProc
  }

  FileView {
    id: themeNameView
    path: root.themeNameFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    // OJO: solo se recorta el salto de línea, NO los espacios. Hay temas
    // cuyo nombre acaba en espacio ("dark-carbon "), y quitarlo hacía que
    // el plugin buscara una carpeta inexistente.
    onLoaded: root.themeName = String(text() || "").replace(/^[\r\n]+|[\r\n]+$/g, "")
  }

  // Estado de vídeo (monitor, ruta, sonido 0/1, fondo base). Se lee para que el
  // botón ♪ arranque reflejando lo que de verdad suena, también tras reiniciar
  // sesión: antes siempre nacía en OFF aunque el vídeo tuviera audio.
  FileView {
    id: videoStateView
    path: root.videoStateFile
    watchChanges: true
    printErrors: false
    onLoaded: root.syncVideoState(text())
    onFileChanged: reload()
    onLoadFailed: root.syncVideoState("")
  }

  // El archivo de estado acumula una línea por monitor y applyVideo añade al
  // final, así que la entrada vigente es la ÚLTIMA. Leer la primera daba el
  // monitor equivocado (y su socket muerto) al conmutar el audio.
  function syncVideoState(raw) {
    var lines = String(raw || "").split("\n").filter(function(l) { return l.trim() !== "" })
    var line = lines.length ? lines[lines.length - 1] : ""
    var f = line.split("\t")
    if (f.length >= 3 && f[1]) {
      root.activeVideoPath = String(f[1])
      root.activeVideoMonitor = String(f[0])
      root.videoSoundActive = String(f[2]).trim() === "1"
    } else {
      root.activeVideoPath = ""
      root.activeVideoMonitor = ""
      // Sin estado no se toca la preferencia: sigue valiendo para el próximo vídeo.
    }
  }

  function shq(s) { return "'" + String(s || "").replace(/'/g, "'\\''") + "'" }
  function baseName(p) { return String(p || "").split("/").pop() }
  function isRemovable(item) {
    if (!item) return false
    return item.path.indexOf(root.userBgDir) === 0
      || item.path.indexOf(root.themeUserDir) === 0
      || item.path.indexOf(root.themeDir) === 0
  }
  // Mata el mpvpaper del monitor M, pero SOLO el que lanzó este plugin.
  // El cmdline de nuestros mpvpaper siempre incluye la ruta del socket IPC
  // (madmasx.wallpaper-picker/ipc), así que el patrón no toca instancias ajenas.
  // Dos detalles imprescindibles:
  // - el ancla `^mpvpaper`: sin ella el pkill también coincide con el propio
  //   bash -c (su cmdline contiene el patrón) y se suicidea con SIGTERM.
  // - `-9`: mpvpaper ignora SIGTERM, así que sin SIGKILL el vídeo viejo
  //   sobrevive y se queda pegado al fondo.
  function killMon(m) {
    var me = String(m || "").replace(/[][\\^$.*/+?(){}|]/g, "\\$&")
    return "pkill -9 -f '^mpvpaper .*madmasx[.]wallpaper-picker/ipc.* " + me + " /' 2>/dev/null"
  }
  // Socket IPC de mpv para un monitor (mpvpaper lo crea al arrancar).
  function monSocket(m) {
    return root.ipcDir + "/" + String(m || "").replace(/[^A-Za-z0-9._-]/g, "_") + ".sock"
  }
  function urlFromUrl(u) {
    var s = String(u || "")
    if (s.indexOf("file://") === 0) return decodeURIComponent(s.slice(7))
    return s
  }

  // Coloca el panel en el monitor con foco (el que el usuario está usando) y
  // deja ese monitor seleccionado para APPLY. Síncrono vía Quickshell.Hyprland:
  // no hay parpadeo de abrir en el monitor primario y saltar después.
  function applyFocusedScreen() {
    var fm = Hyprland.focusedMonitor
    if (!fm || !fm.name) return
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === fm.name) {
        if (root.panelScreen !== screens[i]) root.panelScreen = screens[i]
        break
      }
    }
    root.currentMonitor = fm.name
  }

  function open() {
    root.applyFocusedScreen()
    root.opened = true
    root.positionCard()
    root.refreshMonitors()
    root.scan()
    root.readCurrent()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    console.log("[picker.WM] open() en " + (root.currentMonitor || "?"))
  }

  // ---------- posición de la tarjeta ----------
  // Al abrir, la tarjeta aparece centrada en el monitor del panel. Se puede
  // arrastrar desde la cabecera; la posición se mantiene durante la sesión.

  readonly property string thumbsDir: root.stateHome + "/omarchy/plugins/madmasx.wallpaper-picker/thumbs"
  readonly property string videoStateFile: root.stateHome + "/omarchy/plugins/madmasx.wallpaper-picker/video"

  function positionCard() {
    card.x = Math.round(Math.max(0, (panel.width - card.width) / 2))
    card.y = Math.round(Math.max(0, (panel.height - card.height) / 2))
  }

  function close() {
    root.opened = false
    root.pendingRemove = ""
    console.log("[picker.WM] close()")
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ---------- escaneo de la carpeta de fondos del tema ----------

  function scan() {
    if (!root.themeName) return
    if (root.scanning) { root.rescanPending = true; return }
    root.scanning = true
    console.log("[picker.WM] scan user=" + root.userBgDir + " theme=" + root.themeUserDir
      + " live=" + root.liveBgDir + " sys=" + root.themeSysDir)
    // Omarchy precedence: backgrounds/<tema>, themes/<tema>/backgrounds y
    // current/theme/backgrounds. Se deduplica por nombre en ingestScan.
    scanProc.command = ["bash", "-c",
      "for d in " + root.shq(root.userBgDir) + " " + root.shq(root.themeUserDir) + " "
      + root.shq(root.liveBgDir) + " " + root.shq(root.themeSysDir) + "; do "
      + "[ -d \"$d\" ] || continue; "
      + "for f in \"$d\"/*; do "
      + "[ -f \"$f\" ] || continue; "
      + "case \"$(basename \"$f\")\" in *.part|*.crdownload|.*) continue;; esac; "
      + "realpath \"$f\" 2>/dev/null; done; done"]
    scanProc.running = true
  }

  property bool scanning: false
  property bool rescanPending: false

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scanning = false
        root.ingestScan(String(text || ""))
        var pending = root.rescanPending
        root.rescanPending = false
        if (pending) Qt.callLater(root.scan)
      }
    }
  }

function ingestScan(raw) {
    var rows = String(raw || "").split("\n")
    var out = []
    var names = []
    var seen = {}
    var vids = []
    for (var i = 0; i < rows.length; i++) {
      var p = String(rows[i] || "").trim()
      if (!p) continue
      var name = p.split("/").pop()
      if (seen[name]) continue
      seen[name] = true
      var dot = name.lastIndexOf(".")
      var ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : ""
      if (root.imageExts.indexOf(ext) === -1 && root.videoExts.indexOf(ext) === -1) continue
      var isVideo = root.videoExts.indexOf(ext) !== -1
      var item = {
        path: p,
        name: name,
        ext: ext,
        kind: isVideo ? "video" : "image",
        thumb: isVideo ? root.thumbsDir + "/" + name + ".jpg" : "",
        ar: 0
      }
      out.push(item)
      if (isVideo) vids.push(item)
      names.push(name)
    }
    // Conserva la selección por nombre: tras un reescaneo los índices cambian,
    // así que se re-resuelve currentIndex sobre el nuevo grid.
    var keepName = (root.currentIndex >= 0 && root.images[root.currentIndex])
      ? root.images[root.currentIndex].name : ""
    root.images = out
    if (keepName) {
      for (var n = 0; n < out.length; n++) {
        if (out[n].name === keepName) { root.currentIndex = n; break }
      }
    } else {
      root.matchCurrent()
    }
    console.log("[picker.WM] grid: " + out.length + " ítems (" + names.join(", ") + ")")
    root.ensureThumbs(vids)
    root.queueMasonry()
  }

  // Genera (una sola vez) un fotograma como miniatura para cada vídeo que no
  // la tenga; al terminar reescannea para mostrarlas.
  function ensureThumbs(videos) {
    var cmds = []
    for (var i = 0; i < videos.length; i++) {
      cmds.push("f=" + root.shq(videos[i].path) + "; t=" + root.shq(videos[i].thumb)
        + "; [ -f \"$t\" ] && echo \"SKIP \"$t || { echo \"WANT \"$t; ffmpeg -y -loglevel error -ss 0.5 -i \"$f\""
        + " -frames:v 1 -vf \"scale=200:-2\" \"$t\" >/dev/null 2>&1; }")
    }
    if (!cmds.length) return
    console.log("[picker.WM] generando " + cmds.length + " miniatura(s) de vídeo")
    thumbProc.command = ["bash", "-c",
      "mkdir -p " + root.shq(root.thumbsDir) + " && " + cmds.join("; ")]
    thumbProc.running = true
  }

  Process {
    id: thumbProc
    property bool made: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        logThumbDetail(String(text || ""))
        thumbProc.made = String(text || "").indexOf("WANT") !== -1
      }
    }
    onExited: function(code) {
      console.log("[picker.WM] thumbnails exit=" + code)
      if (thumbProc.made) root.scan()
    }
  }

  function logThumbDetail(txt) {
    var lines = String(txt || "").split("\n")
    for (var i = 0; i < lines.length; i++)
      if (lines[i].indexOf("WANT") === 0)
        console.log("[picker.WM] miniatura nueva: " + lines[i].slice(5))
  }

  function matchCurrent() {
    if (!root.activeBackground) { root.currentIndex = -1; return }
    var base = root.baseName(root.activeBackground)
    for (var i = 0; i < root.images.length; i++) {
      if (root.images[i].path === root.activeBackground || root.images[i].name === base) {
        root.currentIndex = i
        return
      }
    }
    root.currentIndex = -1
  }

  function readCurrent() {
    currentBgProc.running = true
  }

  Process {
    id: currentBgProc
    command: ["bash", "-c", "readlink -f " + root.shq(root.currentBgLink) + " 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.activeBackground = String(text || "").trim()
        // Re-sincroniza el resaltado con el fondo realmente aplicado.
        root.matchCurrent()
      }
    }
  }

  Process {
    id: themeProc
    onExited: function(code) {
      if (code !== 0) console.warn("[picker.WM] no se pudo cambiar el tema (exit " + code + ")")
    }
  }

  // ---------- monitores (dinámicos) ----------

  function refreshMonitors() {
    if (!monProc.running) monProc.running = true
  }

  Process {
    id: monProc
    command: ["bash", "-c", "hyprctl monitors -j 2>/dev/null || echo '[]'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestMonitors(String(text || ""))
    }
  }

  function ingestMonitors(raw) {
    var list = []
    try {
      var arr = JSON.parse(raw)
      for (var i = 0; i < arr.length; i++) if (arr[i].name) list.push(String(arr[i].name))
    } catch (e) {}
    root.monitors = list
    if (!root.currentMonitor || list.indexOf(root.currentMonitor) === -1)
      root.currentMonitor = list.length ? list[0] : ""
  }

  // ---------- aplicar fondos ----------

  function applySelected() {
    var item = root.currentIndex >= 0 ? root.images[root.currentIndex] : null
    if (!item) return
    if (item.kind === "video") applyVideo(item)
    else applyImage(item)
  }

  function applyImage(item) {
    var m = root.currentMonitor
    if (!m) {
      console.warn("[picker.WM] sin monitor para la imagen")
      return
    }
    var ipc = "--input-ipc-server=" + root.monSocket(m)
    var opts = "no-audio panscan=1.0 image-display-duration=inf load-scripts=no " + ipc
    root.applyVideoActive = true
    root.activeVideoPath = ""
    root.activeVideoMonitor = ""
    root.activeVideoHasAudio = false
    applyProc.command = ["bash", "-c",
      "m=" + root.shq(m) + "; " + root.killMon(m) + "; "
      + "st=" + root.shq(root.videoStateFile) + "; "
      + "mkdir -p " + root.shq(root.stateHome) + "/omarchy/plugins/madmasx.wallpaper-picker; "
      + "mkdir -p " + root.shq(root.ipcDir) + "; "
      + "rm -f " + root.shq(root.monSocket(m)) + "; "
      + "b=$(readlink -f " + root.shq(root.currentBgLink) + " 2>/dev/null || true); "
      + "t=\"$st.tmp\"; : > \"$t\"; "
      + "[ -f \"$st\" ] && awk -F'\t' -v m=\"$m\" 'NF>=3 && $1!=m' \"$st\" >> \"$t\"; "
      + "printf '%s\\t%s\\t%s\\t%s\\n' \"$m\" " + root.shq(item.path) + " 0 \"$b\" >> \"$t\"; "
      + "mv \"$t\" \"$st\"; "
      + "if grep -qs 0x10de /sys/class/drm/card*/device/vendor 2>/dev/null && grep -qsE '0x8086|0x1002' /sys/class/drm/card*/device/vendor 2>/dev/null && [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then "
      + "export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json; fi; "
      + "EGL_PLATFORM=wayland mpvpaper -f -o " + root.shq(opts) + " \"$m\" "
      + root.shq(item.path) + " >/dev/null 2>&1 & echo UP"]
    applyProc.running = true
    console.log("[picker.WM] imagen por monitor: " + item.path + " → " + m
      + " (el resto de monitores intacto)")
  }

  function applyVideo(item) {
    if (!root.currentMonitor) {
      console.warn("[picker.WM] sin monitor para mpvpaper")
      return
    }
    root.applyVideoActive = true
    var m = root.currentMonitor
    var audioOpt = root.videoSoundActive ? "loop" : "no-audio loop"
    var soundFlag = root.videoSoundActive ? 1 : 0
    //El socket IPC permite pausar el vídeo sin matarlo (ver pausa automática)
    var ipc = "--input-ipc-server=" + root.monSocket(m)
    // load-scripts=no: evita que mpv-mpris registre el wallpaper como un
    // reproductor MPRIS (el widget de media lo mostraba como "reproduciendo").
    var mpvOpts = audioOpt + " load-scripts=no " + ipc
    applyProc.command = ["bash", "-c",
      "m=" + root.shq(m) + "; " + root.killMon(m) + "; "
      + "st=" + root.shq(root.videoStateFile) + "; "
      + "mkdir -p " + root.shq(root.stateHome) + "/omarchy/plugins/madmasx.wallpaper-picker; "
      + "mkdir -p " + root.shq(root.ipcDir) + "; "
      + "rm -f " + root.shq(root.monSocket(m)) + "; "
      + "b=$(readlink -f " + root.shq(root.currentBgLink) + " 2>/dev/null || true); "
      + "t=\"$st.tmp\"; : > \"$t\"; "
      + "[ -f \"$st\" ] && awk -F'\t' -v m=\"$m\" 'NF>=3 && $1!=m' \"$st\" >> \"$t\"; "
      + "printf '%s\\t%s\\t%s\\t%s\\n' \"$m\" " + root.shq(item.path) + " "
      + soundFlag + " \"$b\" >> \"$t\"; "
      + "mv \"$t\" \"$st\"; "
      + "if grep -qs 0x10de /sys/class/drm/card*/device/vendor 2>/dev/null && grep -qsE '0x8086|0x1002' /sys/class/drm/card*/device/vendor 2>/dev/null && [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then "
      + "export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json; fi; "
      + "EGL_PLATFORM=wayland mpvpaper -f -o " + root.shq(mpvOpts) + " \"$m\" "
      + root.shq(item.path) + " >/dev/null 2>&1 & echo UP"]
    applyProc.running = true
    root.activeVideoPath = item.path
    root.activeVideoMonitor = m
    root.probeAudio(item.path)
    console.log("[picker.WM] vídeo vivo: " + item.path + " en " + m + " · " + audioOpt)
    console.log("[picker.WM] vídeos persistentes (se relanzan al iniciar sesión)")
  }

  // Relanza mecánicamente los vídeo wallpapers al arrancar la sesión, si no
  // cambió el fondo-imagen base desde que se guardaron.
  function maybeRestoreVideo() {
    restoreProc.command = ["bash", "-c",
      "st=" + root.shq(root.videoStateFile) + "; "
      + "[ -f \"$st\" ] || exit 0; "
      + "pgrep -f '^mpvpaper' >/dev/null && exit 0; "
      + "mkdir -p " + root.shq(root.stateHome) + "/omarchy/plugins/madmasx.wallpaper-picker; "
      + "mkdir -p " + root.shq(root.ipcDir) + "; "
      + "exec 9> \"$st.lock\"; flock -n 9 || exit 0; "
      + "pgrep -f '^mpvpaper' >/dev/null && exit 0; "
      + "IFS=$'\\t' read -r mon path snd img < \"$st\"; "
      + "[ -n \"$mon\" ] || exit 0; "
      + "cur=$(readlink -f " + root.shq(root.currentBgLink) + " 2>/dev/null || true); "
      + "[ \"$cur\" = \"$img\" ] || { rm -f \"$st\"; echo '[picker.WM] vídeos no restaurados: fondo base cambiado'; exit 0; }; "
      + "if grep -qs 0x10de /sys/class/drm/card*/device/vendor 2>/dev/null && grep -qsE '0x8086|0x1002' /sys/class/drm/card*/device/vendor 2>/dev/null && [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then "
      + "export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json; fi; "
      + "n=0; "
      + "while IFS=$'\\t' read -r mon path snd img; do "
      + "[ -f \"$path\" ] || continue; "
      + "o=loop; [ \"$snd\" = 0 ] && o='no-audio loop'; "
      + "o=\"$o load-scripts=no\"; "
      + "ext=\"${path##*.}\"; ext=$(printf '%s' \"$ext\" | tr 'A-Z' 'a-z'); "
      + "case \"$ext\" in jpg|jpeg|png|gif|bmp|webp) o=\"$o panscan=1.0 image-display-duration=inf\";; esac; "
      + "sock=\"$(dirname " + root.shq(root.ipcDir) + ")/ipc/$(printf '%s' \"$mon\" | tr -c 'A-Za-z0-9._-' '_').sock\"; "
      + "rm -f \"$sock\"; "
      + "EGL_PLATFORM=wayland mpvpaper -f -o \"$o --input-ipc-server=$sock\" \"$mon\" \"$path\" >/dev/null 2>&1 & n=$((n+1)); "
      + "done < \"$st\"; "
      + "echo '[picker.WM] vídeos restaurados: '\"$n\""]
    restoreProc.running = true
  }

  Process {
    id: restoreProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: console.log("" + (text || "").split("\n").join(" | "))
    }
    onExited: function(code) {
      console.log("[picker.WM] restore exit=" + code)
      if (code === 0) {
        root.applyVideoActive = true
        root.pausedNow = {}
        Qt.callLater(root.evalCover)
      }
    }
  }

  // Mientras haya un vídeo activo, vigila el symlink de fondo que maneja
  // Omarchy (bg-switcher, cambio de tema). Si cambia, significa que el usuario
  // eligió otro fondo por el sistema tradicional: para el vídeo y olvida el
  // estado para que no vuelva a tapar el nuevo fondo.
  Timer {
    id: videoWatchTimer
    interval: 3000
    repeat: true
    running: root.applyVideoActive
    onTriggered: root.watchBaseBackground()
  }

  function watchBaseBackground() {
    watchProc.command = ["bash", "-c",
      "st=" + root.shq(root.videoStateFile) + "; "
      + "[ -f \"$st\" ] || exit 0; "
      + "IFS=$'\\t' read -r mon path snd img < \"$st\"; "
      + "cur=$(readlink -f " + root.shq(root.currentBgLink) + " 2>/dev/null || true); "
      + "if [ \"$cur\" != \"$img\" ]; then "
      + "pkill -9 -f '^mpvpaper .*madmasx[.]wallpaper-picker/ipc' 2>/dev/null; rm -f " + root.shq(root.ipcDir) + "/*.sock; "
      + "rm -f \"$st\"; echo CHANGED; fi"]
    watchProc.running = true
  }

  Process {
    id: watchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").indexOf("CHANGED") !== -1) {
          root.applyVideoActive = false
          root.activeVideoPath = ""
          root.activeVideoMonitor = ""
          root.activeVideoHasAudio = false
          console.log("[picker.WM] fondo externo detectado: vídeo detenido")
        }
      }
    }
  }

  // ---------- pausa automática por ventanas encima ----------
  // Cuando una ventana tapa casi todo un monitor (>=90% de su área), el vídeo de
  // ese monitor se pausa vía el socket IPC de mpv; al despejarse se reanuda.
  // El vídeo no se mata: se pausa, así que volver es instantáneo.

  Timer {
    id: coverTimer
    interval: 1500
    repeat: true
    running: root.applyVideoActive && root.autoPause
    onTriggered: root.evalCover()
  }

  function evalCover() {
    if (!root.applyVideoActive || !root.autoPause) return
    if (coverDataProc.running) return
    coverDataProc.running = true
  }

  Process {
    id: coverDataProc
    // timeout en los hyprctl: si se cuelgan, no bloquean el timer para siempre.
    command: ["bash", "-c",
      "{ timeout 2 hyprctl clients -j 2>/dev/null || echo '[]'; }; echo '==='; "
      + "{ timeout 2 hyprctl monitors -j 2>/dev/null || echo '[]'; }; echo '==='; "
      + "cat " + root.shq(root.videoStateFile) + " 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCoverDecision(String(text || ""))
    }
    // Si el proceso muere sin emitir salida, el flag running ya se limpia solo
    // en Quickshell, pero aseguramos que el timer pueda seguir evaluando.
    onExited: function(code) {
      if (code !== 0) { /* hyprctl falló: el siguiente ciclo reintenta */ }
    }
  }

  // Área cubierta por la unión de varios rectángulos (ventanas), sin contar
  // dos veces las zonas solapadas. Importante para el caso de dos ventanas
  // lado a lado: cada una ocupa ~47% pero juntas tapan casi toda la pantalla.
  function rectUnionArea(rects) {
    if (!rects || !rects.length) return 0
    var xs = [], ys = []
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].w <= 0 || rects[i].h <= 0) continue
      xs.push(rects[i].x); xs.push(rects[i].x + rects[i].w)
      ys.push(rects[i].y); ys.push(rects[i].y + rects[i].h)
    }
    if (!xs.length) return 0
    xs.sort(function (a, b) { return a - b })
    ys.sort(function (a, b) { return a - b })
    var ux = [], uy = []
    for (i = 0; i < xs.length; i++) if (!ux.length || ux[ux.length - 1] !== xs[i]) ux.push(xs[i])
    for (i = 0; i < ys.length; i++) if (!uy.length || uy[uy.length - 1] !== ys[i]) uy.push(ys[i])
    var area = 0
    for (var a = 0; a < ux.length - 1; a++) {
      for (var b = 0; b < uy.length - 1; b++) {
        var x0 = ux[a], x1 = ux[a + 1], y0 = uy[b], y1 = uy[b + 1]
        if (x1 <= x0 || y1 <= y0) continue
        var inside = false
        for (var k = 0; k < rects.length; k++) {
          var r = rects[k]
          if (r.w <= 0 || r.h <= 0) continue
          if (r.x < x1 && r.x + r.w > x0 && r.y < y1 && r.y + r.h > y0) { inside = true; break }
        }
        if (inside) area += (x1 - x0) * (y1 - y0)
      }
    }
    return area
  }

  // Entrada: "<json clients>\n===\n<json monitors>\n===\n<lineas estado>"
  function applyCoverDecision(raw) {
    var parts = String(raw || "").split("===")
    if (parts.length < 3) return
    var clients = [], mons = []
    try { clients = JSON.parse(parts[0].trim()) } catch (e) {}
    try { mons = JSON.parse(parts[1].trim()) } catch (e) {}
    // Si no hay monitores no se puede decidir nada (no toco el estado).
    // Con cero ventanas sí hay que decidir: significa "nada tapa" -> reanudar.
    if (!mons.length) return
    if (!Array.isArray(clients)) clients = []

    //Monitores con vídeo según el estado
    var withVideo = {}
    var lines = String(parts[2] || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var ln = lines[i].trim()
      if (!ln) continue
      var mon = ln.split("\t")[0]
      if (mon) withVideo[mon] = true
    }

    var next = {}
    var changes = []
    for (var j = 0; j < mons.length; j++) {
      var m = mons[j]
      var name = String(m.name || "")
      if (!withVideo[name]) continue
      var activeWs = m.activeWorkspace ? m.activeWorkspace.id : -99999
      var specialWs = m.specialWorkspace ? m.specialWorkspace.id : 0
      // reserved = [left, top, right, bottom] en píxeles (barra, dock, etc).
      // Una ventana maximizada ocupa el área de trabajo (monitor menos las
      // zonas reservadas), no el monitor entero: por eso comparamos contra
      // el área de trabajo, o si no una ventana al 95% del monitor real nunca
      // superaría el umbral del 90%.
      var res = m.reserved || [0, 0, 0, 0]
      var workX = (m.x || 0) + (res[0] || 0)
      var workY = (m.y || 0) + (res[1] || 0)
      var mW = (m.width || 0) - (res[0] || 0) - (res[2] || 0)
      var mH = (m.height || 0) - (res[1] || 0) - (res[3] || 0)
      var mArea = mW * mH
      if (mArea <= 0) continue
      // Juntamos los rectángulos de todas las ventanas visibles del monitor y
      // medimos su unión: así dos ventanas lado a lado cuentan como cobertura
      // aunque ninguna llegue al 90% por separado.
      var rects = []
      for (var k = 0; k < clients.length; k++) {
        var c = clients[k]
        if (!c || c.hidden) continue
        if (c.monitor !== m.id) continue
        var cWs = c.workspace ? c.workspace.id : -99999
        var visible = (cWs === activeWs)
          || (specialWs !== 0 && cWs === specialWs)
        if (!visible) continue
        var at = c.at || [0, 0]
        var sz = c.size || [0, 0]
        // Recortado al área de trabajo para que una ventana desbordada no
        // infle la cobertura.
        var x0 = Math.max(workX, at[0])
        var y0 = Math.max(workY, at[1])
        var x1 = Math.min(workX + mW, at[0] + (sz[0] || 0))
        var y1 = Math.min(workY + mH, at[1] + (sz[1] || 0))
        if (x1 > x0 && y1 > y0) rects.push({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
      }
      var covered = root.rectUnionArea(rects) >= 0.9 * mArea
      next[name] = covered
      if (root.pausedNow[name] !== covered) changes.push([name, covered])
    }
    root.pausedNow = next
    if (changes.length) root.sendPauses(changes)
  }

  function sendPauses(changes) {
    var parts = []
    for (var i = 0; i < changes.length; i++) {
      var mon = changes[i][0]
      // OJO: este build de mpv solo acepta "yes"/"no" para pause
      // (con "true"/"false" devuelve "error running command").
      var val = changes[i][1] ? "yes" : "no"
      parts.push("printf '{\"command\":[\"set\",\"pause\",\"" + val + "\"]}\\n' | socat - UNIX-CONNECT:"
        + root.shq(root.monSocket(mon)) + " 2>/dev/null")
    }
    pauseProc.command = ["bash", "-c", "mkdir -p " + root.shq(root.ipcDir) + "; " + parts.join("; ")]
    pauseProc.running = true
    var log = []
    for (var j = 0; j < changes.length; j++)
      log.push(changes[j][0] + (changes[j][1] ? " pausa" : " reanuda"))
    console.log("[picker.WM] " + log.join(" · "))
  }

  Process {
    id: pauseProc
    onExited: function(code) {
      if (code !== 0) console.log("[picker.WM] pauseProc exit=" + code)
    }
  }

  function resumePaused() {
    var resume = []
    for (var m in root.pausedNow)
      if (root.pausedNow[m]) resume.push(m)
    if (!resume.length) return
    var changes = []
    for (var i = 0; i < resume.length; i++) changes.push([resume[i], false])
    root.sendPauses(changes)
    console.log("[picker.WM] pausa automática: reanudando " + resume.join(", "))
    root.pausedNow = {}
  }

  function setAutoPause(on) {
    // Al desactivar, reanuda los vídeos que la pausa automática dejó pausados;
    // si no, se quedaban congelados hasta reaplicar el fondo.
    if (!on) root.resumePaused()
    root.autoPause = !!on
    // OJO: proceso aparte del de lectura. Si compartieran, el collector de
    // salida (vacía al guardar) volvía a poner autoPause=false al instante.
    root.autoPauseWriting = true
    autoPauseSaveProc.command = ["bash", "-c",
      "d=" + root.shq(root.autoPauseFile) + "; mkdir -p \"$(dirname \"$d\")\"; "
      + "if [ " + (root.autoPause ? "1" : "0") + " = 1 ]; then rm -f \"$d\"; else echo 0 > \"$d\"; fi"]
    autoPauseSaveProc.running = true
    root.pausedNow = {}
    console.log("[picker.WM] pausa automática " + (root.autoPause ? "activada" : "desactivada"))
    if (root.autoPause) Qt.callLater(root.evalCover)
  }

  // Sin archivo = activado (default). El archivo solo existe si el usuario la
  // desactivó explícitamente. FileView + Timer mantiene el estado sincronizado
  // entre las instancias del widget (una por monitor).
  function applyAutoPauseState(on) {
    if (root.autoPauseWriting) return
    if (root.autoPause === on) return
    root.autoPause = on
    if (!on) root.resumePaused()
    else Qt.callLater(root.evalCover)
  }

  FileView {
    id: autoPauseView
    path: root.autoPauseFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyAutoPauseState(false)
    onLoadFailed: root.applyAutoPauseState(true)
  }

  Timer {
    id: autoPauseSync
    interval: 2000
    repeat: true
    running: true
    onTriggered: autoPauseView.reload()
  }

  Process {
    id: autoPauseSaveProc
    onExited: root.autoPauseWriting = false
  }

  // Al arrancar (o tras un reload), reanuda cualquier vídeo que quedara
  // pausado por la pausa automática antes de cerrar.
  function resumePausedOnStart() {
    resumeProc.command = ["bash", "-c",
      "st=" + root.shq(root.videoStateFile) + "; "
      + "[ -f \"$st\" ] || exit 0; "
      + "while IFS=$'\\t' read -r mon path snd img; do "
      + "[ -n \"$mon\" ] || continue; "
      + "sock=" + root.shq(root.ipcDir) + "/$(printf '%s' \"$mon\" | tr -c 'A-Za-z0-9._-' '_').sock; "
      + "printf '{\"command\":[\"set\",\"pause\",\"no\"]}\\n' | socat - UNIX-CONNECT:\"$sock\" 2>/dev/null; "
      + "done < \"$st\""]
    resumeProc.running = true
  }

  Process {
    id: resumeProc
  }

  // ffprobe: ¿el fondo trae pista de audio? Con un vídeo mudo el botón ♪ no
  // tiene nada que conmutar, así que se muestra apagado en vez de mentir.
  function probeAudio(path) {
    probeProc.command = ["bash", "-c",
      "ffprobe -v error -select_streams a -show_entries stream=index "
      + "-of csv=p=0 " + root.shq(path) + " 2>/dev/null | head -n1"]
    probeProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.activeVideoHasAudio = String(text || "").trim() !== ""
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "")
        if (t.indexOf("UP") !== -1) root.applyVideoActive = true
        if (t.indexOf("DOWN") !== -1) root.applyVideoActive = false
      }
    }
    onExited: function(code) {
      console.log("[picker.WM] apply exit=" + code)
      // Al reaplicar, el estado de pausa anterior ya no es válido: que el
      // siguiente ciclo de evalCover reevalúe desde cero.
      root.pausedNow = {}
      if (root.applyVideoActive) Qt.callLater(root.evalCover)
    }
  }

  // ---------- importar ----------

  function importFile(fileUrl) {
    var src = root.urlFromUrl(fileUrl)
    if (!src) return
    importProc.command = ["bash", "-c",
      "mkdir -p " + root.shq(root.themeDir) + " && install -m 644 "
      + root.shq(src) + " " + root.shq(root.themeDir) + "/"]
    importProc.running = true
    console.log("[picker.WM] importar: " + src + " -> " + root.themeDir)
  }

  Process {
    id: importProc
    onExited: function(code) {
      console.log("[picker.WM] import exit=" + code)
      if (code === 0) root.scan()
    }
  }

  // El FileDialog nativo de Quickshell hace crashear el shell al abrirse
  // (bug upstream con toplevels). Se usa zenity como proceso externo, que
  // además libera el foco de teclado del panel mientras está abierto.

  // Escapa el texto traducido antes de incrustarlo en un argumento de zenity:
  // comillas y barras invertidas romperían la línea de comandos.
  function zenityArg(text) {
    return String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  }

  function openImportDialog() {
    if (root.importDialogActive) return
    root.importDialogActive = true
    root.importReopen = root.opened
    root.opened = false
    console.log("[picker.WM] importar: abriendo zenity en " + root.themeDir)
    importDialogProc.command = ["bash", "-c",
      "d=" + root.shq(root.themeDir) + "; [ -d \"$d\" ] || d=$HOME; "
      + "zenity --file-selection --title=\"" + root.zenityArg(strings.t("import.title")) + "\" "
      + "--file-filter=\"" + root.zenityArg(strings.t("import.images")) + " | *.jpg *.jpeg *.png *.gif *.bmp *.webp\" "
      + "--file-filter=\"" + root.zenityArg(strings.t("import.videos")) + " | *.mkv *.mp4 *.webm *.avi\" "
      + "--file-filter=\"" + root.zenityArg(strings.t("import.all")) + " | *\" "
      + "--filename=\"$d/\""]
    importDialogProc.running = true
  }

  function endImportDialog() {
    root.importDialogActive = false
    if (root.importReopen) {
      root.importReopen = false
      root.opened = true
    }
  }

  Process {
    id: importDialogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var sel = String(text || "").trim()
        root.endImportDialog()
        if (sel) root.importFile(sel)
        else console.log("[picker.WM] importar cancelado")
      }
    }
    onExited: function(code) {
      console.log("[picker.WM] zenity exit=" + code)
      root.endImportDialog()
    }
  }

  // ---------- eliminar fondos ----------
  // Pide confirmación y mueve el archivo a la papelera (gio trash) o lo borra
  // si gio no está. Solo se permite quitar fondos de la carpeta del tema del
  // usuario; los de sistema (/usr/share) quedan protegidos.

  function confirmRemove() {
    var item = root.currentIndex >= 0 ? root.images[root.currentIndex] : null
    if (!item || !root.isRemovable(item)) return
    root.pendingRemove = item.path
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    console.log("[picker.WM] eliminar: confirmando " + item.name)
  }

  function removeItem(path) {
    var name = root.baseName(path)
    console.log("[picker.WM] eliminar: " + path)
    removeProc.command = ["bash", "-c",
      "st=" + root.shq(root.videoStateFile) + "; p=" + root.shq(path) + "; "
      + "live=" + root.shq(root.liveBgDir + "/" + name) + "; "
      + "if [ -f \"$st\" ]; then "
      + "while IFS=$'\\t' read -r vmon vpath vsnd vimg; do "
      + "{ [ \"$vpath\" = \"$p\" ] || [ \"$vpath\" = \"$live\" ]; } && { "
      + "vm=$(printf '%s' \"$vmon\" | sed 's/[][^$.*/]/\\\\&/g'); "
      + "pkill -9 -f \"^mpvpaper .*madmasx[.]wallpaper-picker/ipc.* $vm /\" 2>/dev/null; "
      + "rm -f " + root.shq(root.ipcDir) + "/$(printf '%s' \"$vmon\" | tr -c 'A-Za-z0-9._-' '_').sock; "
      + "echo '[picker.WM] vídeo borrado: '\"$vmon\"''; }; "
      + "done < \"$st\"; "
      + "awk -F'\t' -v p=\"$p\" -v l=\"$live\" 'NF>=4 && $2!=p && $2!=l' \"$st\" > \"$st.tmp\" && mv \"$st.tmp\" \"$st\"; "
      + "[ -s \"$st\" ] || rm -f \"$st\"; "
      + "fi; "
      + "rm -f " + root.shq(root.thumbsDir + "/" + name + ".jpg") + "; "
      + "if command -v gio >/dev/null 2>&1; then gio trash -f \"$p\" 2>/dev/null; else rm -f \"$p\"; fi; "
      + "[ -e \"$p\" ] && { echo 'ERROR no se pudo eliminar'; exit 1; }; "
      + "[ \"$live\" != \"$p\" ] && rm -f \"$live\"; "
      + "[ -s \"$st\" ] && echo UP || { rm -f \"$st\"; echo DOWN; }"]
    removeProc.running = true
  }

  Process {
    id: removeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "")
        if (t.indexOf("UP") !== -1) root.applyVideoActive = true
        if (t.indexOf("DOWN") !== -1) root.applyVideoActive = false
      }
    }
    onExited: function(code) {
      console.log("[picker.WM] remove exit=" + code)
      if (code !== 0) { console.warn("[picker.WM] no se pudo eliminar el fondo"); return }
      root.currentIndex = -1
      root.scan()
    }
  }

  // ---------- IPC desde terminal / atajos ----------

  IpcHandler {
    target: "madmasx.wallpaper-picker"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function sound(): void { root.setSound(true) }
    function mute(): void { root.setSound(false) }
    function autopause(): void { root.setAutoPause(!root.autoPause) }
    function scan(): void { root.scan(); root.readCurrent() }
    function check(): void { root.applyVideoActive = true; root.evalCover() }
  }

  // ---------- diseño ----------
  // La paleta se adapta al tema activo (Omarchy), así que el panel encaja con
  // el escritorio en cualquier tema. Solo el rojo de DELETE es fijo: es un
  // color destructivo, no existe equivalente en los temas.
  readonly property string dBg: Color.popups.background
  readonly property color dSurface: Util.alpha(Color.foreground, 0.04)
  readonly property color dSurfaceHi: Util.alpha(Color.foreground, 0.08)
  readonly property string dAccent: Color.accent
  readonly property string dText: Color.popups.text
  readonly property string dMuted: Color.muted
  readonly property string dDanger: "#ef4444"
  readonly property string dSuccess: "#22c55e"
  readonly property string dBorder: Color.popups.border
  readonly property color dAccentGlow: Util.alpha(Color.accent, 0.35)
  readonly property color dDangerGlow: Util.alpha("#ef4444", 0.35)
  // Solo para el desplegable de monitor: el fondo del tema puede venir
  // translúcido y entonces la lista abierta era casi ilegible.
  readonly property color dPanel: Util.alpha(Color.popups.background, 1)

  // ---------- masonry ----------
  // Reparte los fondos en N columnas equilibrando altura, al estilo Pinterest.
  // La altura de cada celda sale de su relación de aspecto real (item.ar), que
  // el delegate rellena cuando la miniatura termina de cargar.
  property int masonryCols: 3
  property real masonryWidth: 584
  property real masonryColW: 188
  property var masonry: []

  function relayoutMasonry() {
    var cols = Math.max(1, root.masonryCols)
    var gap = 10
    var colW = Math.floor((root.masonryWidth - gap * (cols - 1)) / cols)
    var buckets = []
    var heights = []
    for (var i = 0; i < cols; i++) { buckets.push([]); heights.push(0) }
    for (var n = 0; n < root.images.length; n++) {
      var it = root.images[n]
      if (root.filterKind !== "all" && it.kind !== root.filterKind) continue
      var ar = (it && it.ar > 0.2) ? it.ar : 1.7778
      var h = colW / ar + 26
      var shortest = 0
      for (var c = 1; c < cols; c++) if (heights[c] < heights[shortest]) shortest = c
      it.__idx = n            // índice global: el masonry reordena, la
      buckets[shortest].push(it)  // selección debe usar el índice real
      heights[shortest] += h + gap
    }
    root.masonryColW = colW
    root.masonry = buckets
  }

  // Agrupa las actualizaciones de aspecto para no reconstruir el grid por cada
  // miniatura que carga.
  Timer {
    id: masonryTimer
    interval: 140
    onTriggered: root.relayoutMasonry()
  }

  function queueMasonry() {
    masonryTimer.restart()
    root.relayoutMasonry()
  }

  function setFilter(kind) {
    if (root.filterKind === kind) return
    root.filterKind = kind
    root.currentIndex = -1
    root.queueMasonry()
  }

  // Lista de temas instalados (sistema + usuario) para OTHER THEMES.
  function loadThemeList() {
    themeListProc.command = ["bash", "-c",
      "{ find /usr/share/omarchy/themes -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'; "
      + "find " + root.shq(root.home + "/.config/omarchy/themes") + " -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'; } 2>/dev/null "
      + "| grep -v '^\\.' | sort -u"]
    themeListProc.running = true
  }

  function setTheme(name) {
    if (!name) return
    console.log("[picker.WM] cambiar tema → " + name)
    themeProc.command = ["omarchy-theme-set", name]
    themeProc.running = true
    themeMenu.close()
  }

  Process {
    id: themeListProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.themeList = String(text || "")
        .split("\n")
        .filter(function(s) { return s.trim() !== "" })
    }
  }

  // ---------- ventana del panel ----------

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.panelScreen
    onWidthChanged: if (root.opened) root.positionCard()
    onHeightChanged: if (root.opened) root.positionCard()
    anchors { top: true; bottom: true; left: true; right: true }
    color: Qt.rgba(0, 0, 0, 0)
    WlrLayershell.namespace: "madmasx-wallpaper-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && !root.importDialogActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // El escape y el click en el fondo cierran el panel.
    Shortcut {
      sequence: "Escape"
      // Mientras el diálogo de borrado está abierto, el keyCatcher se encarga
      // de cancelarlo; si no, este atajo cierra el panel.
      enabled: root.opened && root.pendingRemove === "" && !themeMenu.visible
      onActivated: root.close()
    }

    Rectangle {
      id: scrim
      anchors.fill: parent
      color: root.scrimColor
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    Item {
      anchors.fill: parent

      Rectangle {
        id: card
        width: 620
        height: 664
        radius: 16
        color: root.dBg
        border { color: root.dBorder; width: 1 }
        clip: true

        // Sin sombra falsa: al ser hija de la tarjeta (que recorta) el anillo
        // se dibujaba dentro y dejaba manchas oscuras en las esquinas, muy
        // visibles con temas claros. Si se quiere profundidad, la sombra real
        // va con QtQuick.Effects fuera de la tarjeta, no dentro.
        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          radius: 15
          color: "transparent"
          border { color: Util.alpha(root.dText, 0.05); width: 1 }
          z: -1
        }

        // Tragador de clicks: sólo el scrim cierra el panel.
        MouseArea { anchors.fill: parent; onClicked: {} }

        // Asa de arrastre: va DEBAJO del contenido para que los controles de
        // la cabecera (p. ej. la píldora del tema) sigan recibiendo clics.
        MouseArea {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 46
          cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          drag.target: card
          drag.axis: Drag.XAndYAxis
          drag.minimumX: 0
          drag.minimumY: 0
          drag.maximumX: panel.width - card.width
          drag.maximumY: panel.height - card.height
          drag.threshold: 6
          drag.smoothed: true
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 18
          spacing: 14

          // ---------- cabecera ----------
          Item {
            Layout.fillWidth: true
            height: 48

            RowLayout {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 10

              Item {
                Layout.alignment: Qt.AlignVCenter
                width: 20
                height: 20
                Image {
                  id: cubeSrc
                  anchors.fill: parent
                  source: Qt.resolvedUrl("icons/cube.svg")
                  sourceSize { width: 40; height: 40 }
                  visible: false
                  smooth: true
                }
                MultiEffect {
                  anchors.fill: parent
                  source: cubeSrc
                  colorization: 1.0
                  colorizationColor: root.dText
                }
              }

              Column {
                Layout.alignment: Qt.AlignVCenter
                spacing: 2
                Text {
                  text: strings.t("panel.title")
                  font.pixelSize: 18
                  font.weight: Font.ExtraBold
                  font.letterSpacing: 2
                  textFormat: Text.PlainText
                  color: root.dText
                }
                Text {
                  text: strings.t("panel.subtitle")
                  font.pixelSize: 9
                  font.weight: Font.DemiBold
                  font.letterSpacing: 3
                  textFormat: Text.PlainText
                  color: root.dMuted
                }
              }
            }

            // Selector de tema segmentado: tema actual | OTHER THEMES.
            Rectangle {
              id: themeSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: 30
              width: themeSegments.implicitWidth + 4
              radius: 15
              color: Util.alpha(root.dText, 0.03)
              border { color: root.dBorder; width: 1 }

              Row {
                id: themeSegments
                anchors.centerIn: parent
                spacing: 0

                // Segmento activo: tema actual
                Rectangle {
                  width: currentThemeLabel.implicitWidth + 20
                  height: 26
                  radius: 13
                  color: Util.alpha(root.dText, 0.10)
                  Text {
                    id: currentThemeLabel
                    anchors.centerIn: parent
                    text: (root.themeName.trim() || "?").toUpperCase()
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                    textFormat: Text.PlainText
                    color: root.dText
                  }
                }

                // Segmento OTHER THEMES
                Rectangle {
                  width: otherThemesLabel.implicitWidth + 20
                  height: 26
                  radius: 13
                  color: otherMouse.containsMouse || themeMenu.visible
                    ? Util.alpha(root.dText, 0.06) : "transparent"
                  Text {
                    id: otherThemesLabel
                    anchors.centerIn: parent
                    text: strings.t("theme.other")
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                    textFormat: Text.PlainText
                    color: otherMouse.containsMouse || themeMenu.visible ? root.dText : root.dMuted
                  }
                  MouseArea {
                    id: otherMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.loadThemeList()
                      themeMenu.open()
                    }
                  }
                }
              }
            }

            // Menú de temas dentro del panel (sin ventanas externas)
            Popup {
              id: themeMenu
              x: themeSwitch.x + themeSwitch.width - width
              y: themeSwitch.y + themeSwitch.height + 6
              width: 220
              height: Math.min(root.themeList.length * 30 + 8, 300)
              padding: 4
              closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
              background: Rectangle {
                radius: 10
                color: root.dBg
                border { color: root.dBorder; width: 1 }
              }
              contentItem: ListView {
                clip: true
                model: root.themeList
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                  required property string modelData
                  width: ListView.view.width
                  height: 30
                  contentItem: Text {
                    text: modelData
                    font.pixelSize: 11
                    font.weight: modelData === root.themeName.trim() ? Font.DemiBold : Font.Normal
                    textFormat: Text.PlainText
                    color: modelData === root.themeName.trim() ? root.dAccent : root.dText
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                  }
                  background: Rectangle {
                    radius: 6
                    color: highlighted ? Util.alpha(root.dAccent, 0.12) : "transparent"
                  }
                  onClicked: root.setTheme(modelData)
                }
              }
            }
          }

          // ---------- filtros ----------
          RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // TODOS (n)
            Rectangle {
              height: 30
              radius: 8
              width: allLabel.implicitWidth + 24
              color: root.filterKind === "all" ? root.dSurface : "transparent"
              border { color: root.filterKind === "all" ? root.dBorder : "transparent"; width: 1 }
              Text {
                id: allLabel
                anchors.centerIn: parent
                text: strings.tn("filter.all", root.images.length)
                    .arg(I18n.formatNumber(root.images.length))
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
                color: root.filterKind === "all" ? root.dAccent : root.dMuted
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFilter("all")
              }
            }

            // VIDEOS
            Rectangle {
              height: 30
              radius: 8
              width: videoFilterRow.implicitWidth + 24
              color: root.filterKind === "video" ? root.dSurface : "transparent"
              border { color: root.filterKind === "video" ? root.dBorder : "transparent"; width: 1 }
              RowLayout {
                id: videoFilterRow
                anchors.centerIn: parent
                spacing: 5
                Item {
                  Layout.alignment: Qt.AlignVCenter
                  width: 12
                  height: 12
                  Image {
                    id: playSrc
                    anchors.fill: parent
                    source: Qt.resolvedUrl("icons/play.svg")
                    sourceSize { width: 24; height: 24 }
                    visible: false
                    smooth: true
                  }
                  MultiEffect {
                    anchors.fill: parent
                    source: playSrc
                    colorization: 1.0
                    colorizationColor: root.filterKind === "video" ? root.dAccent : root.dMuted
                  }
                }
                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: strings.t("filter.videos")
                  font.pixelSize: 10
                  font.weight: Font.DemiBold
                  font.letterSpacing: 1.2
                  textFormat: Text.PlainText
                  color: root.filterKind === "video" ? root.dAccent : root.dMuted
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFilter("video")
              }
            }

            // IMÁGENES
            Rectangle {
              height: 30
              radius: 8
              width: imageFilterRow.implicitWidth + 24
              color: root.filterKind === "image" ? root.dSurface : "transparent"
              border { color: root.filterKind === "image" ? root.dBorder : "transparent"; width: 1 }
              RowLayout {
                id: imageFilterRow
                anchors.centerIn: parent
                spacing: 5
                Item {
                  Layout.alignment: Qt.AlignVCenter
                  width: 12
                  height: 12
                  Image {
                    id: imageSrc
                    anchors.fill: parent
                    source: Qt.resolvedUrl("icons/image.svg")
                    sourceSize { width: 24; height: 24 }
                    visible: false
                    smooth: true
                  }
                  MultiEffect {
                    anchors.fill: parent
                    source: imageSrc
                    colorization: 1.0
                    colorizationColor: root.filterKind === "image" ? root.dAccent : root.dMuted
                  }
                }
                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: strings.t("filter.images")
                  font.pixelSize: 10
                  font.weight: Font.DemiBold
                  font.letterSpacing: 1.2
                  textFormat: Text.PlainText
                  color: root.filterKind === "image" ? root.dAccent : root.dMuted
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFilter("image")
              }
            }

            Item { Layout.fillWidth: true }
          }

          // ---------- masonry ----------
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            Text {
              visible: root.visibleCount === 0
              anchors.centerIn: parent
              width: parent.width - 40
              text: root.visibleCount === 0
                ? (root.filterKind === "all"
                    ? strings.t("empty.none").arg(root.themeName.trim())
                      + "\n" + strings.t("empty.noneHint")
                    : strings.t("empty.filtered")
                        .arg(strings.t(root.filterKind === "video" ? "kind.videos" : "kind.images"))
                        .arg(root.themeName.trim()))
                : ""
              font.pixelSize: 11
              lineHeight: 1.4
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: root.dMuted
            }

            Flickable {
              id: flick
              visible: root.visibleCount > 0
              anchors.fill: parent
              contentWidth: width
              contentHeight: colRow.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Row {
                id: colRow
                width: flick.width
                spacing: 10

                Repeater {
                  model: root.masonry.length ? root.masonry : [[], [], []]
                  delegate: Column {
                    required property var modelData
                    width: root.masonryColW
                    spacing: 10

                    Repeater {
                      model: parent.modelData ? parent.modelData : []
                      delegate: Item {
                        id: cell
                        required property var modelData
                        required property int index
                        width: root.masonryColW
                        height: (root.masonryColW / ((modelData.ar > 0.2) ? modelData.ar : 1.7778)) + 26

                        // Índice real dentro de root.images (lo fija relayoutMasonry)
                        readonly property int globalIndex: (modelData && modelData.__idx !== undefined)
                          ? modelData.__idx : -1

                        // Halo exterior (glow) al pasar el ratón o al estar
                        // elegido. Va antes que la tarjeta para quedar detrás.
                        Rectangle {
                          id: tileGlow
                          anchors.fill: tile
                          anchors.margins: -3
                          radius: 15
                          color: "transparent"
                          transform: Translate { y: tile.lift }
                          border {
                            width: 2
                            color: Util.alpha(root.dAccent,
                              (cell.globalIndex === root.currentIndex) ? 0.40
                                : (tileHover.hovered ? 0.24 : 0))
                          }
                        }

                        // Tarjeta: superficie, borde redondeado y barra de título
                        // (mismo lenguaje visual que el mockup HTML).
                        Rectangle {
                          id: tile
                          anchors.fill: parent
                          radius: 12
                          color: tileHover.hovered ? root.dSurfaceHi : root.dSurface
                          border {
                            width: 1
                            color: (cell.globalIndex === root.currentIndex)
                              ? root.dAccent
                              : (tileHover.hovered ? Util.alpha(root.dText, 0.2) : root.dBorder)
                          }
                          clip: true
                          property bool broken: false
                          property bool selected: cell.globalIndex === root.currentIndex
                          property real lift: tileHover.hovered ? -3 : 0
                          Behavior on lift { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                          // Pequeño salto al pasar el ratón, como el mockup.
                          transform: Translate { y: tile.lift }

                          Item {
                            id: thumbWrap
                            anchors { top: parent.top; left: parent.left; right: parent.right; bottom: titleBar.top }

                            Image {
                              id: shot
                              anchors.fill: parent
                              anchors.margins: 1
                              source: modelData.kind === "video"
                                ? (modelData.thumb ? Util.fileUrl(modelData.thumb) : "")
                                : Util.fileUrl(modelData.path)
                              fillMode: Image.PreserveAspectCrop
                              asynchronous: true
                              visible: false
                              layer.enabled: true
                              onStatusChanged: {
                                if (status === Image.Error) tile.broken = true
                                else if (status === Image.Ready) {
                                  tile.broken = false
                                  var sw = shot.sourceSize.width
                                  var sh = shot.sourceSize.height
                                  if (sw > 0 && sh > 0) {
                                    var r = sw / sh
                                    if (Math.abs(r - (modelData.ar || 0)) > 0.02) {
                                      modelData.ar = r
                                      root.queueMasonry()
                                    }
                                  }
                                }
                              }
                            }

                            // Máscara redondeada: mismo radio que la tarjeta
                            // (solo arriba; abajo lo cubre la barra de título).
                            Rectangle {
                              id: thumbMask
                              anchors.fill: shot
                              topLeftRadius: 12
                              topRightRadius: 12
                              bottomLeftRadius: 0
                              bottomRightRadius: 0
                              color: "white"
                              visible: false
                              layer.enabled: true
                            }

                            MultiEffect {
                              anchors.fill: shot
                              source: shot
                              maskEnabled: true
                              maskSource: thumbMask
                              maskThresholdMin: 0.5
                              maskSpreadAtMin: 0.02
                            }

                            // Badge de tipo: imagen (ámbar) o vídeo (acento)
                            Rectangle {
                              visible: modelData.kind === "image"
                              anchors { top: parent.top; topMargin: 7; left: parent.left; leftMargin: 7 }
                              width: 22; height: 22; radius: 6
                              color: Util.alpha("#f9e2af", 0.22)
                              border { color: Util.alpha("#f9e2af", 0.5); width: 1 }
                              Item {
                                anchors.centerIn: parent
                                width: 12
                                height: 12
                                Image {
                                  id: badgeImageSrc
                                  anchors.fill: parent
                                  source: Qt.resolvedUrl("icons/image.svg")
                                  sourceSize { width: 24; height: 24 }
                                  visible: false
                                  smooth: true
                                }
                                MultiEffect {
                                  anchors.fill: parent
                                  source: badgeImageSrc
                                  colorization: 1.0
                                  colorizationColor: "#f9e2af"
                                }
                              }
                            }

                            Rectangle {
                              visible: modelData.kind === "video" && !tile.broken
                              anchors { top: parent.top; topMargin: 7; left: parent.left; leftMargin: 7 }
                              width: 22; height: 22; radius: 6
                              color: Util.alpha(root.dAccent, 0.22)
                              border { color: Util.alpha(root.dAccent, 0.5); width: 1 }
                              Item {
                                anchors.centerIn: parent
                                width: 10
                                height: 10
                                Image {
                                  id: badgePlaySrc
                                  anchors.fill: parent
                                  source: Qt.resolvedUrl("icons/play.svg")
                                  sourceSize { width: 20; height: 20 }
                                  visible: false
                                  smooth: true
                                }
                                MultiEffect {
                                  anchors.fill: parent
                                  source: badgePlaySrc
                                  colorization: 1.0
                                  colorizationColor: root.dAccent
                                }
                              }
                            }

                            // Vídeo sin miniatura
                            Rectangle {
                              visible: modelData.kind === "video" && tile.broken
                              anchors.fill: parent
                              anchors.margins: 1
                              radius: 11
                              color: root.dSurfaceHi
                              Text {
                                anchors.centerIn: parent
                                text: "▶"
                                font.pixelSize: 22
                                textFormat: Text.PlainText
                                color: Util.alpha(root.dAccent, 0.7)
                              }
                            }

                            // Aviso de imagen rota
                            Rectangle {
                              visible: modelData.kind === "image" && tile.broken
                              anchors.fill: parent
                              anchors.margins: 1
                              radius: 11
                              color: root.dSurfaceHi
                              Text {
                                anchors.centerIn: parent
                                text: "⚠"
                                font.pixelSize: 18
                                textFormat: Text.PlainText
                                color: root.dMuted
                              }
                            }
                          }

                          // Barra de título (debajo de la miniatura)
                          Rectangle {
                            id: titleBar
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 26
                            color: Util.alpha(Color.background, 0.25)
                            bottomLeftRadius: 12
                            bottomRightRadius: 12
                            Text {
                              anchors {
                                left: parent.left; right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10; rightMargin: 10
                              }
                              text: cell.modelData.name
                              font.pixelSize: 10
                              font.weight: tile.selected ? Font.DemiBold : Font.Normal
                              textFormat: Text.PlainText
                              elide: Text.ElideMiddle
                              color: tile.selected ? root.dText : root.dMuted
                            }
                          }

                          MouseArea {
                            id: tileHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.currentIndex = cell.globalIndex
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- divisor ----------
          Rectangle {
            Layout.fillWidth: true
            height: 1
            color: root.dBorder
          }

          // ---------- panel de control ----------
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 8

            // Fila DISPLAY + selector (label a la izquierda, como el mockup)
            RowLayout {
              Layout.fillWidth: true
              spacing: 10

              Text {
                Layout.alignment: Qt.AlignVCenter
                text: strings.t("display.label")
                font.pixelSize: 9
                font.weight: Font.Bold
                font.letterSpacing: 2
                textFormat: Text.PlainText
                color: root.dMuted
              }

              // Dropdown de monitor con chevron dibujado
              Rectangle {
                Layout.fillWidth: true
                height: 38
                radius: 8
                color: root.dSurface
                border { color: monBox.popup.visible ? root.dAccent : root.dBorder; width: 1 }

                ComboBox {
                  id: monBox
                  anchors.fill: parent
                  anchors.leftMargin: 2
                  anchors.rightMargin: 2
                  model: root.monitors
                  currentIndex: root.monitors.indexOf(root.currentMonitor)
                  onActivated: root.currentMonitor = currentText
                  background: Rectangle { color: "transparent" }
                  contentItem: Text {
                    text: monBox.displayText
                    textFormat: Text.PlainText
                    color: root.dText
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    leftPadding: 14
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                  }
                  indicator: Item {
                    implicitWidth: 11
                    implicitHeight: 7
                    width: 11
                    height: 7
                    x: monBox.width - width - 14
                    y: (monBox.height - height) / 2
                    // Chevron "v" con dos barras rotadas (sin depender de fuentes)
                    Rectangle {
                      width: 7; height: 1.6; color: root.dAccent
                      rotation: 45
                      x: 0; y: 2.4
                      transformOrigin: Item.Left
                      antialiasing: true
                    }
                    Rectangle {
                      width: 7; height: 1.6; color: root.dAccent
                      rotation: -45
                      x: 4; y: 2.4
                      transformOrigin: Item.Left
                      antialiasing: true
                    }
                  }
                  popup: Popup {
                    y: monBox.height + 4
                    width: monBox.width
                    implicitHeight: Math.min(contentItem.implicitHeight + 8, 240)
                    padding: 4
                    // Sombra propia: separa la lista del panel aunque el tema
                    // no contraste mucho.
                    enter: Transition {
                      NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 110 }
                    }
                    contentItem: ListView {
                      clip: true
                      implicitHeight: contentHeight
                      model: monBox.popup.visible ? monBox.delegateModel : null
                      currentIndex: monBox.highlightedIndex
                      ScrollBar.vertical: ScrollBar {}
                    }
                    background: Rectangle {
                      radius: 8
                      // Opaco: con el fondo translúcido del tema la lista
                      // abierta no se leía.
                      color: root.dPanel
                      border { color: root.dAccent; width: 1 }
                    }
                  }
                  delegate: ItemDelegate {
                    required property int index
                    required property string modelData
                    width: monBox.width - 8
                    height: 32
                    highlighted: monBox.highlightedIndex === index
                    contentItem: Text {
                      text: modelData
                      textFormat: Text.PlainText
                      color: highlighted ? root.dAccent : root.dText
                      font.pixelSize: 12
                      font.weight: highlighted ? Font.DemiBold : Font.Normal
                      verticalAlignment: Text.AlignVCenter
                      leftPadding: 10
                    }
                    background: Rectangle {
                      radius: 6
                      color: highlighted ? Util.alpha(root.dAccent, 0.12) : "transparent"
                    }
                  }
                }
              }
            }

            // ---------- acciones ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: 12

              // APPLY: relleno de acento (peso 2x)
              Rectangle {
                Layout.fillWidth: true
                Layout.horizontalStretchFactor: 4
                height: 40
                radius: 8
                color: root.currentIndex >= 0
                  ? (applyMouse.hovered ? Qt.lighter(root.dAccent, 1.1) : root.dAccent)
                  : Util.alpha(root.dAccent, 0.18)
                Text {
                  anchors.centerIn: parent
                  text: strings.t("action.apply")
                  font.pixelSize: 12
                  font.weight: Font.Bold
                  font.letterSpacing: 1.5
                  textFormat: Text.PlainText
                  color: root.currentIndex >= 0 ? Color.background : Util.alpha(root.dAccent, 0.5)
                }
                MouseArea {
                  id: applyMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: root.currentIndex >= 0
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applySelected()
                }
              }

              // IMPORT: contorno (peso 1.5x)
              Rectangle {
                Layout.fillWidth: true
                Layout.horizontalStretchFactor: 3
                height: 40
                radius: 8
                color: importMouse.hovered ? root.dSurface : "transparent"
                border { color: importMouse.hovered ? root.dText : root.dBorder; width: 1 }
                Text {
                  anchors.centerIn: parent
                  text: strings.t("action.import")
                  font.pixelSize: 12
                  font.weight: Font.Bold
                  font.letterSpacing: 1.5
                  textFormat: Text.PlainText
                  color: root.dText
                }
                MouseArea {
                  id: importMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openImportDialog()
                }
              }

              // DELETE: peligro (peso 1x)
              Rectangle {
                Layout.fillWidth: true
                Layout.horizontalStretchFactor: 2
                height: 40
                radius: 8
                color: !root.currentRemovable
                  ? "transparent"
                  : (deleteMouse.hovered ? root.dDanger : Util.alpha(root.dDanger, 0.10))
                border {
                  color: root.currentRemovable
                    ? (deleteMouse.hovered ? root.dDanger : Util.alpha(root.dDanger, 0.25))
                    : Util.alpha(root.dDanger, 0.30)
                  width: 1
                }
                Text {
                  anchors.centerIn: parent
                  text: strings.t("action.delete")
                  font.pixelSize: 12
                  font.weight: Font.Bold
                  font.letterSpacing: 1.5
                  textFormat: Text.PlainText
                  color: !root.currentRemovable
                    ? Util.alpha(root.dDanger, 0.5)
                    : (deleteMouse.hovered ? Color.background : root.dDanger)
                }
                MouseArea {
                  id: deleteMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: root.currentRemovable
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.confirmRemove()
                }
              }
            }

            // ---------- auxiliares ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: 10

              // AUTO / OFF (pausa automática del vídeo)
              Rectangle {
                Layout.fillWidth: true
                height: 38
                radius: 8
                color: root.autoPause ? root.dSurfaceHi : root.dSurface
                border { color: root.autoPause ? root.dAccent : root.dBorder; width: 1 }
                Text {
                  anchors.centerIn: parent
                  text: root.autoPause ? strings.t("auto.on") : strings.t("auto.off")
                  font.pixelSize: 11
                  font.weight: Font.Bold
                  font.letterSpacing: 1.5
                  textFormat: Text.PlainText
                  color: root.autoPause ? root.dAccent : root.dMuted
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setAutoPause(!root.autoPause)
                }
              }

              // Sonido del vídeo. Sólo conmuta si el fondo en pantalla tiene
              // audio; con un vídeo mudo o una imagen queda como preferencia.
              Rectangle {
                width: 72
                height: 38
                radius: 8
                color: root.videoSoundActive && root.soundAvailable
                  ? Util.alpha(root.dSuccess, 0.10) : root.dSurface
                border {
                  color: root.videoSoundActive && root.soundAvailable ? root.dSuccess : root.dBorder
                  width: 1
                }
                Text {
                  anchors.centerIn: parent
                  text: !root.soundAvailable
                    ? "♪ —"
                    : (root.videoSoundActive ? strings.t("sound.on") : strings.t("sound.off"))
                  font.pixelSize: 11
                  font.weight: Font.Bold
                  textFormat: Text.PlainText
                  color: root.videoSoundActive && root.soundAvailable ? root.dSuccess : root.dMuted
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: root.soundAvailable ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                  onClicked: {
                    if (!root.soundAvailable) return
                    root.setSound(!root.videoSoundActive)
                  }
                }
              }

              // Rescanear
              Rectangle {
                width: 44
                height: 38
                radius: 8
                color: root.dSurface
                border { color: root.dBorder; width: 1 }
                Item {
                  anchors.centerIn: parent
                  width: 16
                  height: 16
                  Image {
                    id: refreshSrc
                    anchors.fill: parent
                    source: Qt.resolvedUrl("icons/refresh.svg")
                    sourceSize { width: 32; height: 32 }
                    visible: false
                    smooth: true
                  }
                  MultiEffect {
                    anchors.fill: parent
                    source: refreshSrc
                    colorization: 1.0
                    colorizationColor: root.dMuted
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.scan(); root.readCurrent() }
                }
              }
            }
          }

          // ---------- pie ----------
          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: root.statusText
              font.pixelSize: 9
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.dMuted
            }
            Text {
              text: strings.t("footer.ready")
              font.pixelSize: 9
              font.weight: Font.DemiBold
              font.letterSpacing: 1
              textFormat: Text.PlainText
              color: root.dMuted
            }
          }
        }

      }
    }

    // Confirmación de borrado DENTRO del panel. Una ventana externa (zenity)
    // queda siempre debajo del layer-shell Overlay, así que se dibuja aquí.
    Rectangle {
      id: removeConfirm
      anchors.fill: parent
      visible: root.pendingRemove !== ""
      color: Util.alpha(Color.background, 0.55)
      z: 1000

      // Bloquea clics al fondo y a la tarjeta mientras está abierto.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Rectangle {
        width: 360
        height: 150
        anchors.centerIn: parent
        radius: 14
        color: root.dBg
        border { color: root.dBorder; width: 1 }

        Column {
          anchors.fill: parent
          anchors.margins: 16
          spacing: 10

          Text {
            width: parent.width
            text: strings.t("delete.title")
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.6
            textFormat: Text.PlainText
            color: root.dDanger
          }
          Text {
            width: parent.width
            text: root.baseName(root.pendingRemove)
            font.pixelSize: 12
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: root.dText
          }
          Text {
            width: parent.width
            text: strings.t("delete.body")
            font.pixelSize: 10
            textFormat: Text.PlainText
            color: root.dMuted
          }
          Row {
            anchors.right: parent.right
            spacing: 8
            Rectangle {
              width: 96
              height: 32
              radius: 16
              color: root.dSurface
              border { color: root.dBorder; width: 1 }
              Text {
                anchors.centerIn: parent
                text: strings.t("delete.cancel")
                font.pixelSize: 10
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
                color: root.dMuted
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pendingRemove = ""
              }
            }
            Rectangle {
              width: 96
              height: 32
              radius: 16
              color: Util.alpha(root.dDanger, 0.12)
              border { color: root.dDanger; width: 1 }
              Text {
                anchors.centerIn: parent
                text: strings.t("delete.confirm")
                font.pixelSize: 10
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
                color: root.dDanger
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var p = root.pendingRemove
                  root.pendingRemove = ""
                  root.removeItem(p)
                }
              }
            }
          }
        }
      }
    }

    // Receptáculo de teclado: garantiza que Escape llegue aunque el foco
    // ande por otro widget del panel.
    Item {
      id: keyCatcher
      anchors.fill: parent
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.pendingRemove !== "") root.pendingRemove = ""
          else root.close()
          event.accepted = true
        }
      }
    }
  }

  onThemeNameChanged: {
    console.log("[picker.WM] themeName='" + root.themeName + "'")
    if (root.themeName) Qt.callLater(root.scan)
  }

  onPanelScreenChanged: if (root.opened) Qt.callLater(root.positionCard)

  Component.onCompleted: {
    themeNameView.reload()
    root.refreshMonitors()
    root.scan()
    root.readCurrent()
    root.resumePausedOnStart()
    root.loadThemeList()
    Qt.callLater(root.maybeRestoreVideo)
    console.log("[picker.WM] listo, fondos=" + root.themeDir)
    console.log("[picker.WM] tema: " + root.themeName
      + " | bg=" + root.bg + " fg=" + root.fg + " accent=" + root.accent
      + " muted=" + root.muted + " scrim=" + root.scrimColor
      + " selTile=" + root.selectedTileColor)
  }
}