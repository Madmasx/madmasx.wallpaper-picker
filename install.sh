#!/usr/bin/env bash
# Instalación del plugin Wallpaper picker para Omarchy.
#   - instala las dependencias opcionales (solo para fondos de vídeo)
#   - copia el plugin a ~/.config/omarchy/plugins/
#   - habilita el plugin y recarga el shell
#
# Uso:
#   ./install.sh            pide confirmación si ya hay algo instalado
#   ./install.sh --yes      no pregunta (para installs automatizados)
set -u

PLUGIN_ID="madmasx.wallpaper-picker"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      echo "Uso: $0 [--yes]"
      echo "  --yes   no pide confirmación al reemplazar una instalación previa"
      exit 0
      ;;
    *) echo "Opción desconocida: $arg (usa --help)"; exit 2 ;;
  esac
done

echo "==> [1/3] Dependencias (solo necesarias para fondos de vídeo)"
if ! command -v mpvpaper >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
  if command -v pacman >/dev/null 2>&1; then
    echo "  falta mpvpaper y/o socat; instalando (puede pedir sudo)…"
    sudo pacman -S --needed --noconfirm mpvpaper socat \
      || echo "  (aviso: instala mpvpaper y socat manualmente si quieres vídeos)"
  else
    echo "  (falta mpvpaper o socat; instálalos con el gestor de tu distro para usar vídeos)"
  fi
else
  echo "  mpvpaper y socat ya estaban instalados."
fi

# Archivos que pertenecen a este plugin. Solo se borran estos: nunca el
# directorio completo, para no tocar clones con cambios locales ni datos ajenos.
OWNED_FILES="interface manifest.json README.md screenshot.png LICENSE .gitignore install.sh"

echo "==> [2/3] Instalando plugin en $DEST"
if [ "$SRC" = "$DEST" ]; then
  echo "  el origen ya es el destino; no se copia nada."
else
  if [ -e "$DEST" ]; then
    if [ "$ASSUME_YES" -ne 1 ]; then
      printf "  Ya hay algo instalado en %s.\n" "$DEST"
      printf "  Se reemplazarán solo los archivos del plugin (los tuyos se conservan). ¿Continuar? [s/N] "
      read -r reply || reply=""
      case "$reply" in
        [sSyY]*) ;;
        *) echo "  Cancelado. No se modificó nada."; exit 0 ;;
      esac
    fi
    # Sustitución file-a-file en lugar de rm -rf del directorio entero.
    for f in $OWNED_FILES; do
      [ -e "${DEST:?}/$f" ] && rm -rf "${DEST:?}/$f"
    done
  fi
  mkdir -p "$DEST"
  # Copia el contenido sin el .git de origen (si el usuario clona el repo).
  ( cd "$SRC" && tar -cf - --exclude='./.git' . ) | ( cd "$DEST" && tar -xf - )
  rm -f "$DEST/install.sh"
  echo "  archivos del plugin actualizados en $DEST"
fi

echo "==> [3/3] Habilitando y recargando el shell"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  omarchy restart shell >/dev/null 2>&1 || true
else
  echo "  (no detecté omarchy; reinicia tu shell manualmente)"
fi

echo "Listo. Abre el picker con SUPER + ALT + W."
