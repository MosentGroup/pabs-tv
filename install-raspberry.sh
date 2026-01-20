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
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

if [ "${EUID}" -eq 0 ]; then
  print_error "No ejecutes este script como root."
  print_info "Ejecuta: bash install-raspberry.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"
SERVICE_USER="${SERVICE_USER:-$USER}"
SERVICE_HOME="$(eval echo "~${SERVICE_USER}")"

if [ ! -f "${INSTALL_DIR}/pabs-tv-client2.py" ]; then
  print_error "No se encontró pabs-tv-client2.py en ${INSTALL_DIR}"
  print_info "Ejecuta este script desde la raíz del proyecto."
  exit 1
fi

clear
print_header "INSTALADOR DE PABS-TV"
echo ""
echo "Directorio: ${INSTALL_DIR}"
echo "Usuario de servicio: ${SERVICE_USER} (${SERVICE_HOME})"
echo ""

read -r -p "¿Continuar con la instalación? (s/n) " -n 1 REPLY
echo ""
if [[ ! "${REPLY}" =~ ^[Ss]$ ]]; then
  print_info "Instalación cancelada"
  exit 0
fi

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
python3 -m pip install -r "${INSTALL_DIR}/requirements.txt"
print_success "Dependencias Python instaladas"

print_header "PASO 5: Variables de entorno (.env)"
ENV_FILE="${INSTALL_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  print_warning ".env ya existe: ${ENV_FILE}"
else
  print_info "Creando .env base..."
  cat > "${ENV_FILE}" <<EOF
# Identificación
PABS_CLIENT_ID=pabs-tv-01

# MQTT (nombres canon)
PABS_MQTT_HOST=localhost
PABS_MQTT_PORT=1883
PABS_MQTT_USER=
PABS_MQTT_PASS=
PABS_TOPIC_BASE=pabs-tv

# Paths
PABS_PROJECT_DIR=${INSTALL_DIR}
PABS_MEDIA_DIR=${INSTALL_DIR}/media
PABS_PLAYLIST_FILE=${INSTALL_DIR}/playlist.json

# Logs
PABS_LOGFILE=/tmp/pabs-tv-client.log
PABS_MPV_LOGFILE=/tmp/mpv.log

# Display (ajustar según tu entorno)
DISPLAY=:0
# XDG_SESSION_TYPE=wayland
# WAYLAND_DISPLAY=wayland-0

# MPV (vacío = dejar que mpv decida / use mpv.conf)
# PABS_MPV_VO=x11
# PABS_MPV_GPU_CONTEXT=x11
PABS_MPV_HWDEC=no
PABS_MPV_YTDL_FORMAT=bestvideo[height<=720]+bestaudio/best/best
PABS_MPV_EXTRA_OPTS=
EOF
  print_success ".env creado"
  print_warning "Edita .env antes de producción: nano ${ENV_FILE}"
fi

print_header "PASO 6: Playlist"
if [ -f "${INSTALL_DIR}/playlist.json" ]; then
  print_success "playlist.json ya existe"
else
  print_info "Creando playlist.json de ejemplo..."
  cat > "${INSTALL_DIR}/playlist.json" <<'EOF'
{
  "schedule_enabled": true,
  "schedule_start": "08:00",
  "schedule_end": "22:00",
  "show_time": true,
  "items": [
    { "kind": "image", "src": "media/images/ejemplo.jpg", "duration": 10 },
    { "kind": "video", "src": "media/videos/ejemplo.mp4", "duration": 30 }
  ]
}
EOF
  print_success "playlist.json creado"
fi

print_header "PASO 7: Servicio systemd"
read -r -p "¿Deseas configurar PABS-TV como servicio systemd? (s/n) " -n 1 REPLY
echo ""
if [[ "${REPLY}" =~ ^[Ss]$ ]]; then
  SERVICE_FILE="/etc/systemd/system/pabs-tv.service"
  print_info "Creando servicio en ${SERVICE_FILE}..."

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
ExecStart=${INSTALL_DIR}/env/bin/python3 ${INSTALL_DIR}/pabs-tv-client2.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable pabs-tv.service
  print_success "Servicio habilitado"

  read -r -p "¿Iniciar el servicio ahora? (s/n) " -n 1 REPLY
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
  fi
else
  print_info "Saltando systemd"
fi

print_header "INSTALACIÓN COMPLETADA"
echo ""
echo "Siguientes pasos:"
echo "1) Edita .env: nano ${ENV_FILE}"
echo "2) Edita playlist: nano ${INSTALL_DIR}/playlist.json"
echo "3) Logs: journalctl -u pabs-tv.service -f"
echo ""
print_success "Listo"
