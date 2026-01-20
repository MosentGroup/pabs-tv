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
    cp -a "$f" "${f}.bak-${ts}"
    print_warning "Backup creado: ${f}.bak-${ts}"
  fi
}

if [ "${EUID}" -eq 0 ]; then
  print_error "No ejecutes este script como root."
  print_info "Ejecuta: bash install-raspberry.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"

if [ ! -f "${INSTALL_DIR}/pabs-tv-client2.py" ]; then
  print_error "No se encontró pabs-tv-client2.py en ${INSTALL_DIR}"
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

if command -v yt-dlp >/dev/null 2>&1; then
  print_success "yt-dlp ya está instalado"
else
  print_info "Instalando yt-dlp (binario oficial)..."
  sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
  sudo chmod a+rx /usr/local/bin/yt-dlp
  print_success "yt-dlp instalado"
fi

echo ""
read -r -p "¿Deseas instalar rclone para sincronización Nextcloud? (s/n) " -n 1 REPLY
echo ""
if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
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
mkdir -p "${INSTALL_DIR}/media/videos" "${INSTALL_DIR}/media/images" "${INSTALL_DIR}/cache"
print_success "Carpetas creadas: media/videos, media/images, cache"

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

# Asegurar dotenv (tu cliente lo usa)
python3 -m pip install python-dotenv
print_success "Dependencias Python instaladas"

print_header "PASO 5: Detección de display y configuración MPV (evitar Vulkan)"
SESSION_TYPE="${XDG_SESSION_TYPE:-}"
DISPLAY_CAND="${DISPLAY:-:0}"
WAYLAND_DISPLAY_CAND="${WAYLAND_DISPLAY:-wayland-0}"

HAS_X11="0"
if command -v xset >/dev/null 2>&1; then
  if sudo -u "${SERVICE_USER}" env \
      DISPLAY="${DISPLAY_CAND}" \
      XDG_RUNTIME_DIR="/run/user/${SERVICE_UID}" \
      xset q >/dev/null 2>&1; then
    HAS_X11="1"
  fi
fi

MPV_VO=""
MPV_GPU_CONTEXT=""
PABS_DISPLAY_ENV=""

if [ "${HAS_X11}" = "1" ]; then
  print_success "Display accesible vía X11 (DISPLAY=${DISPLAY_CAND})"
  MPV_VO="x11"
  MPV_GPU_CONTEXT="x11"
  PABS_DISPLAY_ENV="${DISPLAY_CAND}"
else
  if [ -e /dev/dri/card0 ]; then
    print_warning "No se pudo validar X11; usando salida DRM (sin X11)."
    MPV_VO="drm"
    MPV_GPU_CONTEXT=""
    PABS_DISPLAY_ENV=""
  else
    print_warning "No se detectó X11 ni /dev/dri/card0. Se deja MPV sin forzar VO."
    MPV_VO=""
    MPV_GPU_CONTEXT=""
    PABS_DISPLAY_ENV=""
  fi
fi

print_header "PASO 6: Variables de entorno (.env) y playlist"
ENV_FILE="${INSTALL_DIR}/.env"
backup_file "${ENV_FILE}"

cat > "${ENV_FILE}" <<EOF
# Identificación
PABS_CLIENT_ID=${PABS_CLIENT_ID}

# MQTT (canon)
PABS_MQTT_HOST=${PABS_MQTT_HOST}
PABS_MQTT_PORT=${PABS_MQTT_PORT}
PABS_MQTT_USER=
PABS_MQTT_PASS=
PABS_TOPIC_BASE=${PABS_TOPIC_BASE}

# Paths
PABS_PROJECT_DIR=${INSTALL_DIR}
PABS_MEDIA_DIR=${INSTALL_DIR}/media
PABS_PLAYLIST_FILE=${INSTALL_DIR}/playlist.json
PABS_CACHE_DIR=${INSTALL_DIR}/cache

# Logs
PABS_LOGFILE=/tmp/pabs-tv-client.log
PABS_MPV_LOGFILE=/tmp/mpv.log

# Display (si aplica)
EOF

if [ -n "${PABS_DISPLAY_ENV}" ]; then
  echo "DISPLAY=${PABS_DISPLAY_ENV}" >> "${ENV_FILE}"
fi

if [ "${SESSION_TYPE}" = "wayland" ]; then
  {
    echo "XDG_SESSION_TYPE=wayland"
    echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY_CAND}"
  } >> "${ENV_FILE}"
fi

cat >> "${ENV_FILE}" <<EOF

# MPV (evitar Vulkan/libplacebo en Raspberry)
# Si están vacíos, mpv decide / usa mpv.conf
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

print_header "PASO 7: Servicio systemd (se sobrescribe si existe)"
SERVICE_FILE="/etc/systemd/system/pabs-tv.service"
backup_file "${SERVICE_FILE}"

# Construir Environment= para display si aplica
SERVICE_ENV_DISPLAY=""
if [ -n "${PABS_DISPLAY_ENV}" ]; then
  SERVICE_ENV_DISPLAY=$'Environment="DISPLAY='"${PABS_DISPLAY_ENV}"$'"\n'
fi

SERVICE_ENV_WAYLAND=""
if [ "${SESSION_TYPE}" = "wayland" ]; then
  SERVICE_ENV_WAYLAND=$'Environment="XDG_SESSION_TYPE=wayland"\nEnvironment="WAYLAND_DISPLAY='"${WAYLAND_DISPLAY_CAND}"$'"\n'
fi

sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target display-manager.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment="PATH=${INSTALL_DIR}/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=${SERVICE_HOME}"
Environment="XDG_CONFIG_HOME=${SERVICE_HOME}/.config"
Environment="XDG_RUNTIME_DIR=/run/user/%U"
${SERVICE_ENV_DISPLAY}${SERVICE_ENV_WAYLAND}ExecStart=${INSTALL_DIR}/env/bin/python3 ${INSTALL_DIR}/pabs-tv-client2.py
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
    print_info "Logs: journalctl -u pabs-tv.service -n 150 --no-pager"
  fi
else
  print_info "Servicio creado pero no iniciado."
fi

print_header "INSTALACIÓN COMPLETADA"
echo ""
echo "Siguientes pasos:"
echo "1) Revisa .env:       nano ${ENV_FILE}"
echo "2) Revisa playlist:   nano ${INSTALL_DIR}/playlist.json"
echo "3) Ver logs servicio: journalctl -u pabs-tv.service -f"
echo "4) Ver logs mpv:      tail -n 200 /tmp/mpv.log"
echo ""
print_success "Listo"
