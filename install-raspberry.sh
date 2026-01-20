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

if [ "${EUID}" -eq 0 ]; then
  print_error "No ejecutes este script como root."
  print_info "Ejecuta: bash install-raspberry.sh"
  exit 1
fi

require_cmd sudo
require_cmd bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"

# Detectar archivo principal del cliente (sin romper compatibilidad)
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

HOSTNAME_SHORT="$(hostname | tr -d '[:space:]')"
DEFAULT_CLIENT_ID="pabstv-${HOSTNAME_SHORT}"
DEFAULT_MQTT_HOST="localhost"
DEFAULT_MQTT_PORT="1883"
DEFAULT_TOPIC_BASE="pabs-tv"

clear
print_header "INSTALADOR DE PABS-TV"
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
read -r -p "PABS_CLIENT_ID [${DEFAULT_CLIENT_ID}]: " PABS_CLIENT_ID_INPUT
PABS_CLIENT_ID="${PABS_CLIENT_ID_INPUT:-$DEFAULT_CLIENT_ID}"

read -r -p "PABS_MQTT_HOST [${DEFAULT_MQTT_HOST}]: " MQTT_HOST_INPUT
PABS_MQTT_HOST="${MQTT_HOST_INPUT:-$DEFAULT_MQTT_HOST}"

read -r -p "PABS_MQTT_PORT [${DEFAULT_MQTT_PORT}]: " MQTT_PORT_INPUT
PABS_MQTT_PORT="${MQTT_PORT_INPUT:-$DEFAULT_MQTT_PORT}"

read -r -p "PABS_TOPIC_BASE [${DEFAULT_TOPIC_BASE}]: " TOPIC_BASE_INPUT
PABS_TOPIC_BASE="${TOPIC_BASE_INPUT:-$DEFAULT_TOPIC_BASE}"

# Detectar sesión (informativo). En Wayland suele haber DISPLAY=:0 por XWayland.
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
DISPLAY_CAND="${DISPLAY:-:0}"
WAYLAND_DISPLAY_CAND="${WAYLAND_DISPLAY:-wayland-0}"

echo ""
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
)
sudo apt install -y "${PACKAGES[@]}"
print_success "Paquetes base instalados"

# Si MQTT es localhost, ofrecer instalar broker mosquitto (para evitar “host offline” por no tener broker)
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

if command -v yt-dlp >/dev/null 2>&1; then
  print_success "yt-dlp ya está instalado"
else
  print_info "Instalando yt-dlp (binario oficial)..."
  sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
  sudo chmod a+rx /usr/local/bin/yt-dlp
  print_success "yt-dlp instalado"
fi

echo ""
read -r -p "¿Deseas instalar rclone para sincronización (Nextcloud/Drive/etc.)? (s/n) " -n 1 REPLY
echo ""
INSTALL_RCLONE="0"
if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
  INSTALL_RCLONE="1"
  if command -v rclone >/dev/null 2>&1; then
    print_success "rclone ya está instalado"
  else
    print_info "Instalando rclone..."
    curl https://rclone.org/install.sh | sudo bash
    print_success "rclone instalado"
  fi
else
  print_info "Saltando rclone"
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

# Listas reales soportadas por MPV (esto evita tu error: gpu-context=x11 isn't supported)
MPV_VO_HELP="$(mpv --vo=help 2>/dev/null || true)"
MPV_GPUCTX_HELP="$(mpv --gpu-context=help 2>/dev/null || true)"

has_vo() {
  local v="$1"
  echo "${MPV_VO_HELP}" | grep -qiE "(^|[[:space:]])${v}($|[[:space:]])"
}
has_gpuctx() {
  local g="$1"
  echo "${MPV_GPUCTX_HELP}" | grep -qiE "(^|[[:space:]])${g}($|[[:space:]])"
}

# Preferencias:
# - Si hay Wayland disponible Y mpv soporta wayland: usar gpu/wayland
# - Si no, preferir drm si existe (ideal para systemd sin sesión gráfica)
# - Si no, no forzar (mpv decide)
MPV_VO=""
MPV_GPU_CONTEXT=""
PABS_DISPLAY_ENV=""
PABS_WAYLAND_ENV="0"

# ¿Existe runtime dir en este momento?
RUNTIME_DIR="/run/user/${SERVICE_UID}"
WAYLAND_SOCKET="${RUNTIME_DIR}/${WAYLAND_DISPLAY_CAND}"

HAS_WAYLAND_SOCKET="0"
if [ -S "${WAYLAND_SOCKET}" ]; then
  HAS_WAYLAND_SOCKET="1"
fi

# ¿Es “usable” X11 desde este script? (a veces sí, pero MPV puede no tener x11 igual)
HAS_X11="0"
if command -v xset >/dev/null 2>&1; then
  if sudo -u "${SERVICE_USER}" env \
      DISPLAY="${DISPLAY_CAND}" \
      XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
      xset q >/dev/null 2>&1; then
    HAS_X11="1"
  fi
fi

# Decidir configuración final basada en lo que MPV soporta
if [ "${HAS_WAYLAND_SOCKET}" = "1" ] && has_vo "gpu" && has_gpuctx "wayland"; then
  MPV_VO="gpu"
  MPV_GPU_CONTEXT="wayland"
  PABS_WAYLAND_ENV="1"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"  # por si tu app lo usa, pero el vo/gpuctx será wayland
  print_success "MPV soporta Wayland. Config: vo=gpu, gpu-context=wayland (WAYLAND socket detectado)"
elif [ -e /dev/dri/card0 ] && has_vo "drm"; then
  MPV_VO="drm"
  MPV_GPU_CONTEXT=""   # drm no necesita gpu-context x11/wayland
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV=""  # no depender de DISPLAY
  print_success "Config robusta sin sesión gráfica: vo=drm (KMS/DRM)"
elif [ "${HAS_X11}" = "1" ] && has_vo "x11" && has_gpuctx "x11"; then
  MPV_VO="x11"
  MPV_GPU_CONTEXT="x11"
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
  print_success "MPV soporta X11. Config: vo=x11, gpu-context=x11 (DISPLAY=${DISPLAY_CAND})"
else
  # No forzar nada (evita exactamente tu error)
  MPV_VO=""
  MPV_GPU_CONTEXT=""
  PABS_WAYLAND_ENV="0"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
  print_warning "No se encontró una combinación segura para forzar VO/GPUCTX. Se deja vacío para que mpv decida."
  print_info "Esto evita errores tipo: gpu-context 'x11' isn't supported."
fi

print_info "Resumen MPV: PABS_MPV_VO='${MPV_VO}'  PABS_MPV_GPU_CONTEXT='${MPV_GPU_CONTEXT}'"

print_header "PASO 6: Variables de entorno (.env) y playlist"
ENV_FILE="${INSTALL_DIR}/.env"
backup_file "${ENV_FILE}"

cat > "${ENV_FILE}" <<EOF
# Identificación
PABS_CLIENT_ID=${PABS_CLIENT_ID}

# MQTT
PABS_MQTT_HOST=${PABS_MQTT_HOST}
PABS_MQTT_PORT=${PABS_MQTT_PORT}
PABS_MQTT_USER=pabs_admin
PABS_MQTT_PASS=58490Ged$$kgd-op3EdEB
PABS_TOPIC_BASE=${PABS_TOPIC_BASE}

# Paths
PABS_PROJECT_DIR=${INSTALL_DIR}
PABS_MEDIA_DIR=${INSTALL_DIR}/media
PABS_PLAYLIST_FILE=${INSTALL_DIR}/playlist.json
PABS_CACHE_DIR=${INSTALL_DIR}/cache

# Logs
PABS_LOGFILE=/tmp/pabs-tv-client.log
PABS_MPV_LOGFILE=/tmp/mpv.log

# Display (informativo; si el servicio usa DRM puede ir vacío)
EOF

if [ -n "${PABS_DISPLAY_ENV}" ]; then
  echo "DISPLAY=${PABS_DISPLAY_ENV}" >> "${ENV_FILE}"
fi

if [ "${PABS_WAYLAND_ENV}" = "1" ]; then
  {
    echo "XDG_SESSION_TYPE=wayland"
    echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY_CAND}"
  } >> "${ENV_FILE}"
fi

cat >> "${ENV_FILE}" <<EOF

# MPV (NO forzar x11 si tu MPV no lo soporta)
# Si están vacíos, tu app/mpv decide.
PABS_MPV_VO=${MPV_VO}
PABS_MPV_GPU_CONTEXT=${MPV_GPU_CONTEXT}
PABS_MPV_HWDEC=no
PABS_MPV_YTDL_FORMAT=bestvideo[height<=720]+bestaudio/best/best
PABS_MPV_EXTRA_OPTS=
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

print_header "PASO 6.1 (Opcional): Sincronización automática de media con rclone (cada 30 min)"
SYNC_ENABLED="0"
RCLONE_REMOTE_PATH=""
if [ "${INSTALL_RCLONE}" = "1" ]; then
  echo ""
  print_info "Para que se copien videos/imágenes automáticamente, necesitas un remote configurado en rclone."
  print_info "Ejemplos: nextcloud:TV_MEDIA  |  gdrive:carpeta/pabs"
  echo ""
  read -r -p "¿Configurar sync automático de media con rclone cada 30 min? (s/n) " -n 1 REPLY
  echo ""
  if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
    SYNC_ENABLED="1"
    read -r -p "Ruta remota rclone (ej: nextcloud:TV_MEDIA): " RCLONE_REMOTE_PATH
    if [ -z "${RCLONE_REMOTE_PATH}" ]; then
      print_warning "No diste ruta remota. Se omite sync."
      SYNC_ENABLED="0"
    fi
  fi
fi

SYNC_SCRIPT="${INSTALL_DIR}/scripts/sync-media.sh"
cat > "${SYNC_SCRIPT}" <<EOF
#!/bin/bash
set -euo pipefail

REMOTE="${RCLONE_REMOTE_PATH}"
DEST="${INSTALL_DIR}/media"
LOG="/tmp/pabs-tv-rclone.log"

if [ -z "\${REMOTE}" ]; then
  echo "[sync-media] REMOTE vacío. Edita ${ENV_FILE} o el timer/script." >> "\${LOG}"
  exit 0
fi

# Sync completo a media/ (incluye videos/ e images/ si existen en el remoto)
# Ajusta filtros si quieres: --include "videos/**" --include "images/**" --exclude "*"
rclone sync "\${REMOTE}" "\${DEST}" \
  --create-empty-src-dirs \
  --checksum \
  --fast-list \
  --transfers 4 \
  --checkers 8 \
  --log-level INFO \
  --log-file "\${LOG}"

chown -R ${SERVICE_USER}:${SERVICE_USER} "\${DEST}" >/dev/null 2>&1 || true
EOF
chmod +x "${SYNC_SCRIPT}"
sudo chown "${SERVICE_USER}:${SERVICE_USER}" "${SYNC_SCRIPT}" || true

if [ "${SYNC_ENABLED}" = "1" ]; then
  print_info "Creando service/timer systemd para sync cada 30 min..."
  SYNC_SERVICE="/etc/systemd/system/pabs-tv-media-sync.service"
  SYNC_TIMER="/etc/systemd/system/pabs-tv-media-sync.timer"

  backup_file "${SYNC_SERVICE}"
  backup_file "${SYNC_TIMER}"

  sudo tee "${SYNC_SERVICE}" >/dev/null <<EOF
[Unit]
Description=PABS-TV Media Sync (rclone)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
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
  print_success "Sync habilitado: pabs-tv-media-sync.timer (cada 30 min)"
  print_info "Log sync: tail -n 200 /tmp/pabs-tv-rclone.log"
else
  print_info "Sync de media no habilitado (puedes habilitarlo luego)."
fi

print_header "PASO 7: Servicio systemd (se sobrescribe si existe)"
SERVICE_FILE="/etc/systemd/system/pabs-tv.service"
backup_file "${SERVICE_FILE}"

# Nota: Para no depender de sesión gráfica, el servicio funciona perfecto con vo=drm.
# Si tu caso es Wayland y quieres salida por Wayland desde systemd, normalmente debes correr como servicio de usuario (systemd --user).
# Aun así, dejamos variables por si tu app las usa.

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
# OJO: /run/user/UID puede no existir si nadie inició sesión. Con VO=drm no importa.
Environment="XDG_RUNTIME_DIR=/run/user/${SERVICE_UID}"
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
echo "4) Ver logs mpv (si tu app lo usa): tail -n 200 /tmp/mpv.log"
echo "5) Si habilitaste sync:         systemctl status pabs-tv-media-sync.timer"
echo "                                tail -n 200 /tmp/pabs-tv-rclone.log"
echo ""
print_success "Listo"
