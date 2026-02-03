#!/usr/bin/env bash
set -euo pipefail

# Instala TeamViewer Host y deja credenciales en un txt.
# Uso:
#   chmod +x ./install-teamviewer-host.sh
#   ./install-teamviewer-host.sh
#
# Opcional (para definir tu propia contraseña):
#   TV_PASSWORD="TuPassSegura123" ./install-teamviewer-host.sh

log() { echo -e "[TV] $*"; }
die() { echo -e "[TV][ERROR] $*" >&2; exit 1; }

if [ "${EUID}" -eq 0 ]; then
  die "No lo corras como root. Úsalo como usuario normal (el script usa sudo)."
fi

command -v sudo >/dev/null 2>&1 || die "Falta sudo"
command -v dpkg >/dev/null 2>&1 || die "Falta dpkg"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT_FILE="${SCRIPT_DIR}/teamviewer-credentials.txt"
DEB_FILE="${SCRIPT_DIR}/teamviewer-host.deb"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  arm64) URL="https://download.teamviewer.com/download/linux/teamviewer-host_arm64.deb" ;;
  armhf) URL="https://download.teamviewer.com/download/linux/teamviewer-host_armhf.deb" ;;
  *)
    die "Arquitectura no soportada por este script: ${ARCH} (esperaba arm64 o armhf)"
    ;;
esac

log "Directorio: $SCRIPT_DIR"
log "Arquitectura: $ARCH"
log "Descargando: $URL"

# Descarga
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$DEB_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$DEB_FILE" "$URL"
else
  die "Falta curl o wget para descargar."
fi

log "Instalando paquete .deb..."
sudo apt update -y
sudo apt install -y "$DEB_FILE"

# Aceptar licencia (best-effort)
if command -v teamviewer >/dev/null 2>&1; then
  log "Aceptando licencia (si aplica)..."
  sudo teamviewer --acceptlicense >/dev/null 2>&1 || true
else
  die "No se encontró 'teamviewer' después de instalar. Revisa la instalación."
fi

# Habilitar daemon/servicio (best-effort)
log "Habilitando daemon..."
sudo teamviewer daemon enable >/dev/null 2>&1 || sudo teamviewer --daemon enable >/dev/null 2>&1 || true
sudo teamviewer daemon start  >/dev/null 2>&1 || true

# Crear contraseña (unattended)
TV_PASSWORD="${TV_PASSWORD:-}"
if [ -z "$TV_PASSWORD" ]; then
  # Generar password aleatorio (12 chars alfanum)
  TV_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true)"
  if [ -z "$TV_PASSWORD" ]; then
    die "No pude generar contraseña. Ejecuta con TV_PASSWORD='...'"
  fi
  log "Contraseña generada automáticamente (se guardará en el txt)."
else
  log "Usando contraseña proporcionada por variable TV_PASSWORD."
fi

log "Configurando contraseña no atendida..."
sudo teamviewer passwd "$TV_PASSWORD" >/dev/null 2>&1 || die "No pude setear la contraseña con 'teamviewer passwd'."

# Obtener TeamViewer ID (best-effort)
log "Obteniendo TeamViewer ID..."
TV_ID=""
INFO_OUT="$(teamviewer info 2>/dev/null || true)"
TV_ID="$(echo "$INFO_OUT" | awk -F': ' '/TeamViewer ID/ {print $2; exit}' | tr -d '\r' || true)"

# Guardar credenciales
log "Escribiendo credenciales en: $OUT_FILE"
{
  echo "TeamViewer Host instalado"
  echo "Fecha: $(date)"
  echo "Arquitectura: $ARCH"
  echo ""
  echo "TeamViewer ID: ${TV_ID:-NO_ENCONTRADO (corre: teamviewer info)}"
  echo "Password: $TV_PASSWORD"
  echo ""
  echo "Comandos útiles:"
  echo "  teamviewer info"
  echo "  sudo teamviewer status"
  echo "  sudo teamviewer daemon status"
  echo "  sudo systemctl status teamviewerd 2>/dev/null || true"
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"
chown "$USER:$USER" "$OUT_FILE" 2>/dev/null || true

log "Listo."
log "Archivo generado (permiso 600): $OUT_FILE"
log "Tip: para ver ID luego: teamviewer info"