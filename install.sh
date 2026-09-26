#!/usr/bin/env bash
# Instalación en un clic del plugin Wallpaper picker para Omarchy.
#   - instala la dependencia mpvpaper (solo necesaria para fondos de vídeo)
#   - copia el plugin a ~/.config/omarchy/plugins/
#   - habilita el plugin y recarga el shell
set -u

PLUGIN_ID="madmasx.wallpaper-picker"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "==> [1/3] Dependencias (fondos de vídeo)"
if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm mpvpaper socat \
    || echo "  (aviso: instala mpvpaper y socat manualmente si quieres vídeos)"
else
  echo "  (no detecté pacman; instala mpvpaper y socat con el gestor de tu distro)"
fi

echo "==> [2/3] Instalando plugin en $DEST"
if [ "$SRC" != "$DEST" ]; then
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  cp -r "$SRC" "$DEST"
  rm -f "$DEST/install.sh"
fi

echo "==> [3/3] Habilitando y recargando el shell"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  omarchy restart shell >/dev/null 2>&1 || true
else
  echo "  (no detecté omarchy; reinicia tu shell manualmente)"
fi

echo "Listo. Abre el picker con SUPER + ALT + W."