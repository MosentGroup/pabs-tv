#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}============================================${NC}"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$f" "${f}.bak-${ts}" 2>/dev/null || cp -a "$f" "${f}.bak-${ts}"
    print_warning "Backup creado: ${f}.bak-${ts}"
  fi
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    print_error "Falta comando requerido: $c"
    exit 1
  fi
}

# Leer default desde .env si existe (sin source para evitar expansión de $)
env_get() {
  local key="$1"
  local file="$2"
  if [ -f "$file" ]; then
    local line
    line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
    if [ -n "$line" ]; then
      echo "$line" | sed -E "s/^[[:space:]]*${key}=//" | sed -E 's/^"(.*)"$/\1/' | sed -E "s/^'(.*)'\$/\1/"
      return 0
    fi
  fi
  return 1
}

ask() {
  # ask "prompt" "default" -> stdout value
  local prompt="$1"
  local def="$2"
  local out
  read -r -p "${prompt} [${def}]: " out
  echo "${out:-$def}"
}

ask_confirmed() {
  # ask_confirmed "prompt" "default" -> stdout value (typed twice)
  local prompt="$1"
  local def="$2"

  while true; do
    local a b
    a="$(ask "${prompt} (1/2)" "${def}")"
    b="$(ask "${prompt} (2/2)" "${def}")"

    if [ "$a" != "$b" ]; then
      print_warning "No coincide. Vuelve a escribirlo (debe ser idéntico)."
      continue
    fi

    echo ""
    print_info "Valor capturado: ${a}"
    read -r -p "¿Está correcto? (s/n) " -n 1 REPLY
    echo ""
    if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
      echo "$a"
      return 0
    fi
    print_info "Ok, vuelve a capturarlo."
  done
}

# ===========================
# OBLIGAR chmod +x
# ===========================
if [ ! -x "$0" ]; then
  echo -e "${RED}✗ Este instalador debe ejecutarse con permisos de ejecución.${NC}"
  echo -e "${BLUE}ℹ Corre esto y vuelve a intentarlo:${NC}"
  echo -e "  chmod +x ./install-raspberry.sh"
  echo -e "  ./install-raspberry.sh"
  exit 1
fi

if [ "${EUID}" -eq 0 ]; then
  print_error "No ejecutes este script como root."
  print_info "Ejecuta: ./install-raspberry.sh"
  exit 1
fi

require_cmd sudo
require_cmd bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"

# Detectar cliente (compat)
CLIENT_MAIN=""
if [ -f "${INSTALL_DIR}/pabs-tv-client.py" ]; then
  CLIENT_MAIN="pabs-tv-client.py"
elif [ -f "${INSTALL_DIR}/pabs-tv-client2.py" ]; then
  CLIENT_MAIN="pabs-tv-client2.py"
else
  print_error "No se encontró pabs-tv-client.py ni pabs-tv-client2.py en ${INSTALL_DIR}"
  print_info "Ejecuta este script desde la raíz del proyecto."
  exit 1
fi

SERVICE_USER="${SERVICE_USER:-$USER}"
SERVICE_HOME="$(eval echo "~${SERVICE_USER}")"
SERVICE_UID="$(id -u "${SERVICE_USER}")"

ENV_FILE="${INSTALL_DIR}/.env"

HOSTNAME_SHORT="$(hostname | tr -d '[:space:]')"

# Defaults (prioridad: .env existente -> defaults)
DEFAULT_CLIENT_ID="$(env_get PABS_CLIENT_ID "${ENV_FILE}" || true)"
DEFAULT_CLIENT_ID="${DEFAULT_CLIENT_ID:-pabstv-${HOSTNAME_SHORT}}"

DEFAULT_TOPIC_BASE="$(env_get PABS_TOPIC_BASE "${ENV_FILE}" || true)"
DEFAULT_TOPIC_BASE="${DEFAULT_TOPIC_BASE:-pabs-tv}"

# Defaults Nextcloud sync
DEFAULT_SYNC_ENABLE="$(env_get PABS_SYNC_ENABLE "${ENV_FILE}" || true)"
DEFAULT_SYNC_ENABLE="${DEFAULT_SYNC_ENABLE:-0}"

DEFAULT_RCLONE_REMOTE_NAME="$(env_get PABS_RCLONE_REMOTE_NAME "${ENV_FILE}" || true)"
DEFAULT_RCLONE_REMOTE_NAME="${DEFAULT_RCLONE_REMOTE_NAME:-nextcloud}"

# ==========================================================
# MQTT FIJO (NO PREGUNTAR / SIEMPRE ESTOS VALORES)
# OJO: el password tiene $$, por eso va en comillas simples
# ==========================================================
FIXED_MQTT_HOST="3.18.167.209"
FIXED_MQTT_PORT="1883"
FIXED_MQTT_USER="pabs_admin"
FIXED_MQTT_PASS='58490Ged$$kgd-op3EdEB'

# ==========================================================
# Nextcloud remote path FIJO (NO PREGUNTAR)
# ==========================================================
FIXED_RCLONE_REMOTE_PATH="pabs-tv/media"

clear
print_header "INSTALADOR DE PABS-TV (con Nextcloud sync integrado)"
echo ""
echo "Directorio del proyecto: ${INSTALL_DIR}"
echo "Archivo cliente:         ${CLIENT_MAIN}"
echo "Usuario del servicio:    ${SERVICE_USER} (${SERVICE_HOME})"
echo ""

read -r -p "¿Continuar con la instalación? (s/n) " -n 1 REPLY
echo ""
if [[ ! "${REPLY}" =~ ^[Ss]$ ]]; then
  print_info "Instalación cancelada"
  exit 0
fi

echo ""
# CLIENT ID con doble confirmación
PABS_CLIENT_ID="$(ask_confirmed "PABS_CLIENT_ID" "${DEFAULT_CLIENT_ID}")"

# Valores fijos (hardcodeados)
PABS_MQTT_HOST="${FIXED_MQTT_HOST}"
PABS_MQTT_PORT="${FIXED_MQTT_PORT}"
PABS_MQTT_USER="${FIXED_MQTT_USER}"
PABS_MQTT_PASS="${FIXED_MQTT_PASS}"

# Mantener lógica existente para topic base, pero sin preguntar
PABS_TOPIC_BASE="${DEFAULT_TOPIC_BASE}"

print_info "MQTT fijo:"
print_info "  PABS_MQTT_HOST=${PABS_MQTT_HOST}"
print_info "  PABS_MQTT_PORT=${PABS_MQTT_PORT}"
print_info "  PABS_MQTT_USER=${PABS_MQTT_USER}"
print_info "  PABS_TOPIC_BASE=${PABS_TOPIC_BASE}"
print_info "  (PABS_MQTT_PASS hardcodeado)"

# Detectar sesión (informativo)
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
DISPLAY_CAND="${DISPLAY:-:0}"
WAYLAND_DISPLAY_CAND="${WAYLAND_DISPLAY:-wayland-0}"
print_info "Sesión detectada (informativa): XDG_SESSION_TYPE=${SESSION_TYPE}, DISPLAY=${DISPLAY_CAND}, WAYLAND_DISPLAY=${WAYLAND_DISPLAY_CAND}"

print_header "PASO 1: Actualizando sistema"
sudo apt update
sudo apt upgrade -y
print_success "Sistema actualizado"

print_header "PASO 2: Instalando dependencias del sistema"
PACKAGES=(
  git
  python3
  python3-pip
  python3-venv
  mpv
  cec-utils
  net-tools
  mosquitto-clients
  curl
  wget
  x11-xserver-utils
  util-linux
  alsa-utils
)
sudo apt install -y "${PACKAGES[@]}"
print_success "Paquetes base instalados"

print_header "PASO 2.1: Permisos de audio/video (recomendado)"
# ayuda para HDMI audio/video, DRM, etc.
sudo usermod -aG video,render,audio,input "${SERVICE_USER}" || true
print_success "Usuario agregado a grupos: video, render, audio, input (si aplica)"

print_header "PASO 2.2: Ajuste de pantalla (quitar overscan / barras negras)"
BOOT_CFG="/boot/firmware/config.txt"
if [ -f "${BOOT_CFG}" ]; then
  backup_file "${BOOT_CFG}"
  if grep -qE '^[[:space:]]*disable_overscan=' "${BOOT_CFG}"; then
    sudo sed -i -E 's/^[[:space:]]*disable_overscan=.*/disable_overscan=1/' "${BOOT_CFG}"
  else
    echo "" | sudo tee -a "${BOOT_CFG}" >/dev/null
    echo "disable_overscan=1" | sudo tee -a "${BOOT_CFG}" >/dev/null
  fi
  print_success "Configurado: disable_overscan=1 en ${BOOT_CFG}"
  print_info "Nota: si ya estaba ok, no cambia nada. Este ajuste suele quitar franjas por escalado."
else
  print_warning "No existe ${BOOT_CFG}. Saltando ajuste overscan."
fi

# Si MQTT es localhost, ofrecer broker mosquitto
if [[ "${PABS_MQTT_HOST}" == "localhost" || "${PABS_MQTT_HOST}" == "127.0.0.1" ]]; then
  echo ""
  read -r -p "MQTT host es local. ¿Instalar/activar mosquitto broker en este equipo? (s/n) " -n 1 REPLY
  echo ""
  if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
    sudo apt install -y mosquitto
    sudo systemctl enable mosquitto
    sudo systemctl restart mosquitto || true
    print_success "Mosquitto broker instalado/habilitado"
  else
    print_info "Saltando instalación de mosquitto broker"
  fi
fi

# yt-dlp
if command -v yt-dlp >/dev/null 2>&1; then
  print_success "yt-dlp ya está instalado"
else
  print_info "Instalando yt-dlp (binario oficial)..."
  sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
  sudo chmod a+rx /usr/local/bin/yt-dlp
  print_success "yt-dlp instalado"
fi

print_header "PASO 3: Estructura de carpetas"
mkdir -p "${INSTALL_DIR}/media/videos" "${INSTALL_DIR}/media/images" "${INSTALL_DIR}/cache" "${INSTALL_DIR}/scripts"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/media" "${INSTALL_DIR}/cache" "${INSTALL_DIR}/scripts" || true
print_success "Carpetas creadas: media/videos, media/images, cache, scripts"

print_header "PASO 4: Entorno virtual + dependencias Python"
if [ ! -d "${INSTALL_DIR}/env" ]; then
  print_info "Creando entorno virtual..."
  python3 -m venv "${INSTALL_DIR}/env"
  print_success "Entorno virtual creado"
else
  print_warning "Entorno virtual existente, se reutiliza"
fi

# shellcheck disable=SC1091
source "${INSTALL_DIR}/env/bin/activate"
python3 -m pip install --upgrade pip

if [ -f "${INSTALL_DIR}/requirements.txt" ]; then
  python3 -m pip install -r "${INSTALL_DIR}/requirements.txt"
else
  print_warning "No existe requirements.txt; instalando mínimos"
  python3 -m pip install paho-mqtt yt-dlp
fi

python3 -m pip install python-dotenv
print_success "Dependencias Python instaladas"

print_header "PASO 5: Detección REAL de MPV (evitar x11 si no existe)"
require_cmd mpv

MPV_VO_HELP="$(mpv --vo=help 2>/dev/null || true)"
MPV_GPUCTX_HELP="$(mpv --gpu-context=help 2>/dev/null || true)"

has_vo() { echo "${MPV_VO_HELP}" | grep -qiE "(^|[[:space:]])${1}($|[[:space:]])"; }
has_gpuctx() { echo "${MPV_GPUCTX_HELP}" | grep -qiE "(^|[[:space:]])${1}($|[[:space:]])"; }

MPV_VO=""
MPV_GPU_CONTEXT=""
PABS_DISPLAY_ENV=""
PABS_WAYLAND_ENV="0"

RUNTIME_DIR="/run/user/${SERVICE_UID}"
WAYLAND_SOCKET="${RUNTIME_DIR}/${WAYLAND_DISPLAY_CAND}"

HAS_WAYLAND_SOCKET="0"
if [ -S "${WAYLAND_SOCKET}" ]; then HAS_WAYLAND_SOCKET="1"; fi

HAS_X11="0"
if command -v xset >/dev/null 2>&1; then
  if sudo -u "${SERVICE_USER}" env DISPLAY="${DISPLAY_CAND}" XDG_RUNTIME_DIR="${RUNTIME_DIR}" xset q >/dev/null 2>&1; then
    HAS_X11="1"
  fi
fi

if [ "${HAS_WAYLAND_SOCKET}" = "1" ] && has_vo "gpu" && has_gpuctx "wayland"; then
  MPV_VO="gpu"
  MPV_GPU_CONTEXT="wayland"
  PABS_WAYLAND_ENV="1"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
  print_success "MPV soporta Wayland: vo=gpu, gpu-context=wayland"
elif [ -e /dev/dri/card0 ] && has_vo "drm"; then
  MPV_VO="drm"
  MPV_GPU_CONTEXT=""
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV=""
  print_success "Config robusta sin sesión gráfica: vo=drm"
elif [ "${HAS_X11}" = "1" ] && has_vo "x11" && has_gpuctx "x11"; then
  MPV_VO="x11"
  MPV_GPU_CONTEXT="x11"
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
  print_success "MPV soporta X11: vo=x11, gpu-context=x11"
else
  MPV_VO=""
  MPV_GPU_CONTEXT=""
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
  print_warning "No se encontró combinación segura para forzar VO/GPUCTX. Se deja vacío (mpv decide)."
fi

print_info "Resumen MPV: PABS_MPV_VO='${MPV_VO}'  PABS_MPV_GPU_CONTEXT='${MPV_GPU_CONTEXT}'"

print_header "PASO 5.1: Script para volumen al 100% (sistema)"
VOLUME_SCRIPT="/usr/local/bin/pabs-tv-set-volume.sh"
sudo tee "${VOLUME_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Best-effort: no fallar si alguna herramienta no existe.
# 1) Pipewire/Wireplumber (Bookworm)
if command -v wpctl >/dev/null 2>&1; then
  wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 >/dev/null 2>&1 || true
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 >/dev/null 2>&1 || true
fi

# 2) ALSA fallback
if command -v amixer >/dev/null 2>&1; then
  amixer -q sset Master 100% unmute >/dev/null 2>&1 || true
  amixer -q sset PCM 100% unmute >/dev/null 2>&1 || true
  amixer -q sset HDMI 100% unmute >/dev/null 2>&1 || true
fi

exit 0
EOF
sudo chmod +x "${VOLUME_SCRIPT}"
print_success "Script de volumen creado: ${VOLUME_SCRIPT}"

print_header "PASO 6: Escribiendo .env (se sobrescribe)"
backup_file "${ENV_FILE}"

cat > "${ENV_FILE}" <<EOF
# Identificación
PABS_CLIENT_ID="${PABS_CLIENT_ID}"

# MQTT
PABS_MQTT_HOST="${PABS_MQTT_HOST}"
PABS_MQTT_PORT="${PABS_MQTT_PORT}"
PABS_MQTT_USER="${PABS_MQTT_USER}"
PABS_MQTT_PASS="${PABS_MQTT_PASS}"
PABS_TOPIC_BASE="${PABS_TOPIC_BASE}"

# Paths
PABS_PROJECT_DIR="${INSTALL_DIR}"
PABS_MEDIA_DIR="${INSTALL_DIR}/media"
PABS_PLAYLIST_FILE="${INSTALL_DIR}/playlist.json"
PABS_CACHE_DIR="${INSTALL_DIR}/cache"

# Logs
PABS_LOGFILE="/tmp/pabs-tv-client.log"
PABS_MPV_LOGFILE="/tmp/mpv.log"

# Display (informativo; si el servicio usa DRM puede ir vacío)
EOF

if [ -n "${PABS_DISPLAY_ENV}" ]; then
  echo "DISPLAY=\"${PABS_DISPLAY_ENV}\"" >> "${ENV_FILE}"
fi

if [ "${PABS_WAYLAND_ENV}" = "1" ]; then
  {
    echo "XDG_SESSION_TYPE=\"wayland\""
    echo "WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY_CAND}\""
  } >> "${ENV_FILE}"
fi

cat >> "${ENV_FILE}" <<EOF

# MPV
PABS_MPV_VO="${MPV_VO}"
PABS_MPV_GPU_CONTEXT="${MPV_GPU_CONTEXT}"
PABS_MPV_HWDEC="no"
PABS_MPV_YTDL_FORMAT="bestvideo[height<=720]+bestaudio/best/best"
PABS_MPV_EXTRA_OPTS=""

# Nextcloud / rclone sync (si habilitas)
PABS_SYNC_ENABLE="0"
PABS_RCLONE_REMOTE_NAME="nextcloud"
PABS_RCLONE_REMOTE_PATH="${FIXED_RCLONE_REMOTE_PATH}"
EOF

print_success ".env escrito: ${ENV_FILE}"

if [ ! -f "${INSTALL_DIR}/playlist.json" ]; then
  print_info "Creando playlist.json de ejemplo..."
  cat > "${INSTALL_DIR}/playlist.json" <<'EOF'
{
  "schedule_enabled": true,
  "schedule_start": "08:00",
  "schedule_end": "22:00",
  "show_time": true,
  "items": [
    { "kind": "image", "src": "media/images/ejemplo.jpg", "duration": 10 },
    { "kind": "video", "src": "media/videos/ejemplo.mp4" }
  ]
}
EOF
  print_success "playlist.json creado"
else
  print_success "playlist.json ya existe (no se modifica)"
fi

print_header "PASO 6.1: Nextcloud Sync (integrado) - opcional"
echo ""
print_info "Si habilitas esto, se sincroniza ${INSTALL_DIR}/media cada 30 min con rclone."
print_info "Remote path fijo: ${FIXED_RCLONE_REMOTE_PATH} (ya no pregunta)."
print_info "Regla: si rclone ya tiene el remote 'nextcloud:', se salta la configuración."
echo ""
read -r -p "¿Habilitar sync automático con Nextcloud (rclone) cada 30 min? (s/n) " -n 1 REPLY
echo ""

SYNC_ENABLED="0"
if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
  SYNC_ENABLED="1"

  # instalar rclone si falta
  if command -v rclone >/dev/null 2>&1; then
    print_success "rclone ya está instalado"
  else
    print_info "Instalando rclone..."
    curl https://rclone.org/install.sh | sudo bash
    print_success "rclone instalado"
  fi

  # verificar remote nextcloud
  if rclone listremotes 2>/dev/null | grep -q "^nextcloud:$"; then
    print_success "Remote rclone 'nextcloud:' ya existe. Saltando rclone config."
  else
    print_warning "No existe remote 'nextcloud:'. Se abrirá 'rclone config' para crearlo."
    echo ""
    print_info "Pasos sugeridos (WebDAV/Nextcloud):"
    echo "  1) n (New remote)"
    echo "  2) Nombre: nextcloud"
    echo "  3) Tipo: WebDAV"
    echo "  4) URL: https://TU_NEXTCLOUD/remote.php/dav/files/TU_USUARIO/"
    echo "  5) Vendor: Nextcloud"
    echo "  6) Usuario + contraseña/token"
    echo "  7) q para salir"
    echo ""
    read -r -p "Presiona Enter para abrir rclone config..." _
    rclone config
    if ! rclone listremotes 2>/dev/null | grep -q "^nextcloud:$"; then
      print_error "No se encontró la configuración 'nextcloud:' luego de rclone config. No se habilita sync."
      SYNC_ENABLED="0"
    else
      print_success "Remote 'nextcloud:' configurado"
    fi
  fi

  if [ "${SYNC_ENABLED}" = "1" ]; then
    RCLONE_REMOTE_PATH="${FIXED_RCLONE_REMOTE_PATH}"

    # guardar en .env (sin romper otras vars)
    tmp_env="${ENV_FILE}.tmp.$$"
    grep -vE '^(PABS_SYNC_ENABLE|PABS_RCLONE_REMOTE_NAME|PABS_RCLONE_REMOTE_PATH)=' "${ENV_FILE}" > "${tmp_env}"
    cat >> "${tmp_env}" <<EOF

PABS_SYNC_ENABLE="1"
PABS_RCLONE_REMOTE_NAME="nextcloud"
PABS_RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH}"
EOF
    mv "${tmp_env}" "${ENV_FILE}"
    print_success ".env actualizado con sync Nextcloud (ruta fija)"

    # Crear script sync
    SYNC_SCRIPT="${INSTALL_DIR}/scripts/sync-nextcloud.sh"
    cat > "${SYNC_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REMOTE_NAME="${PABS_RCLONE_REMOTE_NAME:-nextcloud}"
REMOTE_PATH="${PABS_RCLONE_REMOTE_PATH:-pabs-tv/media}"
PROJECT_DIR="${PABS_PROJECT_DIR:-/home/pabstvroot/pabs-tv}"
LOCAL_MEDIA_DIR="${PABS_MEDIA_DIR:-${PROJECT_DIR}/media}"

LOG_FILE="${PABS_RCLONE_LOG_FILE:-${PROJECT_DIR}/cron-sync.log}"
LOCK_FILE="${PABS_RCLONE_LOCK_FILE:-/tmp/pabs-tv-nextcloud-sync.lock}"

RCLONE_BIN="$(command -v rclone || true)"
DATE_BIN="$(command -v date || true)"

if [[ -z "${RCLONE_BIN}" ]]; then
  echo "[ERROR] rclone no está instalado o no está en PATH" >&2
  exit 1
fi

mkdir -p "${LOCAL_MEDIA_DIR}" "$(dirname "${LOG_FILE}")"

log() {
  echo "[${DATE_BIN:+$(${DATE_BIN} '+%Y-%m-%d %H:%M:%S')}] $*" | tee -a "${LOG_FILE}"
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "[WARN] Ya hay una sincronización corriendo. Saliendo."
  exit 0
fi

if ! rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
  log "[ERROR] Remote '${REMOTE_NAME}:' no configurado en rclone"
  exit 1
fi

REMOTE_FULL="${REMOTE_NAME}:${REMOTE_PATH}"

log "==== Sync START ===="
log "Remote: ${REMOTE_FULL}"
log "Local : ${LOCAL_MEDIA_DIR}"

mkdir -p "${LOCAL_MEDIA_DIR}/videos" "${LOCAL_MEDIA_DIR}/images"

"${RCLONE_BIN}" sync "${REMOTE_FULL}" "${LOCAL_MEDIA_DIR}" \
  --create-empty-src-dirs \
  --transfers 4 \
  --checkers 8 \
  --timeout 30s \
  --contimeout 15s \
  --retries 3 \
  --low-level-retries 10 \
  --stats 30s \
  --log-level INFO \
  --log-file "${LOG_FILE}"

log "==== Sync END ===="
count="$(find "${LOCAL_MEDIA_DIR}" -type f | wc -l)"
log "  files: ${count}"
log ""
EOF

    chmod +x "${SYNC_SCRIPT}"
    sudo chown "${SERVICE_USER}:${SERVICE_USER}" "${SYNC_SCRIPT}" || true
    print_success "Script de sync creado: ${SYNC_SCRIPT}"

    print_info "Creando/actualizando service/timer systemd (cada 30 min)..."
    SYNC_SERVICE="/etc/systemd/system/pabs-tv-media-sync.service"
    SYNC_TIMER="/etc/systemd/system/pabs-tv-media-sync.timer"

    backup_file "${SYNC_SERVICE}"
    backup_file "${SYNC_TIMER}"

    sudo tee "${SYNC_SERVICE}" >/dev/null <<EOF
[Unit]
Description=PABS-TV Media Sync (rclone nextcloud)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment="HOME=${SERVICE_HOME}"
ExecStart=${SYNC_SCRIPT}
EOF

    sudo tee "${SYNC_TIMER}" >/dev/null <<EOF
[Unit]
Description=Run PABS-TV Media Sync every 30 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now pabs-tv-media-sync.timer
    print_success "Sync habilitado: pabs-tv-media-sync.timer"

    echo ""
    read -r -p "¿Ejecutar una sincronización ahora (bajar media)? (s/n) " -n 1 REPLY
    echo ""
    if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
      print_info "Ejecutando sync ahora..."
      sudo -u "${SERVICE_USER}" env HOME="${SERVICE_HOME}" bash "${SYNC_SCRIPT}" || true
      print_success "Sync manual terminado (revisa log si hubo errores)"
      print_info "Log: tail -n 200 ${INSTALL_DIR}/cron-sync.log"
    fi
  fi
else
  print_info "Sync Nextcloud no habilitado."
fi

print_header "PASO 7: Servicio systemd del cliente (se sobrescribe si existe)"
SERVICE_FILE="/etc/systemd/system/pabs-tv.service"
backup_file "${SERVICE_FILE}"

sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment="PATH=${INSTALL_DIR}/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=${SERVICE_HOME}"
Environment="XDG_CONFIG_HOME=${SERVICE_HOME}/.config"
Environment="XDG_RUNTIME_DIR=/run/user/${SERVICE_UID}"

# Volumen al 100% (sistema) antes de iniciar el cliente
ExecStartPre=${VOLUME_SCRIPT}

ExecStart=${INSTALL_DIR}/env/bin/python3 ${INSTALL_DIR}/${CLIENT_MAIN}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pabs-tv.service
print_success "Servicio instalado/habilitado: ${SERVICE_FILE}"

echo ""
read -r -p "¿Iniciar/reiniciar el servicio ahora? (s/n) " -n 1 REPLY
echo ""
if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
  sudo systemctl restart pabs-tv.service
  sleep 2
  if sudo systemctl is-active --quiet pabs-tv.service; then
    print_success "Servicio iniciado"
  else
    print_error "El servicio no inició"
    print_info "Logs: journalctl -u pabs-tv.service -n 200 --no-pager"
  fi
else
  print_info "Servicio creado pero no iniciado."
fi

print_header "INSTALACIÓN COMPLETADA"
echo ""
echo "Siguientes pasos:"
echo "1) Revisa .env:                 nano ${ENV_FILE}"
echo "2) Revisa playlist:             nano ${INSTALL_DIR}/playlist.json"
echo "3) Ver logs servicio:           journalctl -u pabs-tv.service -f"
echo "4) Ver logs mpv:                tail -n 200 /tmp/mpv.log"
echo "5) Si habilitaste sync:         systemctl status pabs-tv-media-sync.timer"
echo "                                tail -n 200 ${INSTALL_DIR}/cron-sync.log"
echo ""
print_success "Listo"

echo ""
print_info "IMPORTANTE: El ajuste de overscan puede requerir reiniciar el equipo para verse reflejado."
print_info "Si acabas de instalar y ves franjas, reinicia la Raspberry: sudo reboot"