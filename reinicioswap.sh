#!/usr/bin/env bash
# =============================================================================
# reinicioswap.sh — Elimina por completo cualquier instalación previa de
# llama-swap (servicios, binarios, paquetes, configuraciones, cachés y logs)
# sin borrar tus modelos GGUF ni llama-server de LarryOS.
# =============================================================================
set -Eeuo pipefail
trap 'echo "[ERROR] Línea $LINENO: $BASH_COMMAND" >&2' ERR

LARRY_HOME="${LARRY_HOME:-$HOME/.local/share/larryos}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/larryos"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }

rm_safe() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ -w "$(dirname "$target")" ]; then
      rm -rf "$target"
      echo "  - Eliminado: $target"
    elif command -v sudo >/dev/null 2>&1; then
      sudo rm -rf "$target"
      echo "  - Eliminado (sudo): $target"
    else
      warn "Sin permisos para borrar: $target"
    fi
  fi
}

log "1/6 Deteniendo procesos y servicios systemd de llama-swap"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user stop llama-swap.service 2>/dev/null || true
  systemctl --user disable llama-swap.service 2>/dev/null || true
  if systemctl is-active --quiet llama-swap.service 2>/dev/null || systemctl is-enabled --quiet llama-swap.service 2>/dev/null; then
    sudo systemctl stop llama-swap.service 2>/dev/null || true
    sudo systemctl disable llama-swap.service 2>/dev/null || true
  fi
fi

if pgrep -x llama-swap >/dev/null 2>&1; then
  pkill -x llama-swap 2>/dev/null || true
  sleep 1
  pgrep -x llama-swap >/dev/null 2>&1 && (pkill -9 -x llama-swap 2>/dev/null || sudo pkill -9 -x llama-swap 2>/dev/null || true)
fi
ok "Procesos detenidos"

log "2/6 Eliminando unidades systemd y symlinks residuales"
rm_safe "$UNIT_DIR/llama-swap.service"
rm_safe "$UNIT_DIR/llama-swap.service.d"
find "$UNIT_DIR" -maxdepth 2 -name "*llama-swap*" -exec rm -rf {} + 2>/dev/null || true
rm_safe "/etc/systemd/system/llama-swap.service"
rm_safe "/etc/systemd/system/llama-swap.service.d"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed 2>/dev/null || true
fi
ok "Unidades systemd limpiadas"

log "3/6 Comprobando paquetes instalados vía pacman / AUR"
if command -v pacman >/dev/null 2>&1; then
  mapfile -t PKGS < <(pacman -Qq 2>/dev/null | grep -E '^llama-swap(-bin|-git)?$' || true)
  if [ ${#PKGS[@]} -gt 0 ]; then
    echo "  - Paquetes detectados: ${PKGS[*]}"
    sudo pacman -Rns --noconfirm "${PKGS[@]}"
  fi
fi
ok "Gestor de paquetes limpio"

log "4/6 Eliminando binarios de llama-swap"
CANDIDATE_BINS=(
  "$LARRY_HOME/bin/llama-swap"
  "$HOME/.local/bin/llama-swap"
  "$HOME/bin/llama-swap"
  "/usr/local/bin/llama-swap"
  "/usr/bin/llama-swap"
  "/opt/llama-swap/llama-swap"
)

# Añadir cualquier binario extra que aparezca en el PATH actual
while IFS= read -r found_bin; do
  [ -n "$found_bin" ] && CANDIDATE_BINS+=("$found_bin")
done < <(which -a llama-swap 2>/dev/null || true)

for b in "${CANDIDATE_BINS[@]}"; do
  rm_safe "$b"
done
hash -r 2>/dev/null || true
ok "Binarios eliminados"

log "5/6 Eliminando configuraciones, cachés, descargas y logs de llama-swap"
rm_safe "$CFG_DIR/llama-swap.yaml"
rm_safe "$CFG_DIR/llama-swap.yaml.bak"
rm_safe "$HOME/.config/llama-swap"
rm_safe "$HOME/.cache/llama-swap"
rm_safe "$HOME/.local/share/llama-swap"
rm_safe "/etc/llama-swap"
rm_safe "/etc/llama-swap.yaml"

# Limpiar descargas, logs y temporales asociados sin tocar models/ ni db/
find "$LARRY_HOME/downloads" -maxdepth 1 -name "llama-swap*" -exec rm -rf {} + 2>/dev/null || true
find "$LARRY_HOME/logs" -maxdepth 1 -name "*llama-swap*" -exec rm -rf {} + 2>/dev/null || true
find /tmp -maxdepth 1 -name "*llama-swap*" -user "$USER" -exec rm -rf {} + 2>/dev/null || true
ok "Configuración y archivos residuales eliminados (modelos GGUF y SQLite intactos)"

log "6/6 Verificando que no quedan rastros"
LEFTOVERS=0

if pgrep -x llama-swap >/dev/null 2>&1; then
  warn "Sigue activo un proceso llama-swap"
  LEFTOVERS=1
fi

if which -a llama-swap >/dev/null 2>&1; then
  warn "Sigue existiendo un binario en PATH: $(which -a llama-swap)"
  LEFTOVERS=1
fi

REMAINING_FILES="$(find "$HOME" -maxdepth 4 -name "*llama-swap*" 2>/dev/null || true)"
if [ -n "$REMAINING_FILES" ]; then
  warn "Quedan archivos en \$HOME:"
  printf '%s\n' "$REMAINING_FILES"
  LEFTOVERS=1
fi

if [ "$LEFTOVERS" -eq 0 ]; then
  ok "Limpieza completa: cero rastros de llama-swap."
  printf '\nAhora puedes reinstalarlo limpio ejecutando:\n  ./setup-larryos.sh build config services verify\n'
else
  warn "Revisa los avisos anteriores antes de reinstalar."
  exit 1
fi
