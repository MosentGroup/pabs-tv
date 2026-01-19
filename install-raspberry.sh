#!/bin/bash
# =====================================================
# Script de Instalación Automática de PABS-TV
# Para Raspberry Pi OS (Debian/Ubuntu)
# =====================================================

set -e  # Salir si hay algún error

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables
INSTALL_DIR="$HOME/pabs-tv"
PYTHON_VERSION="3.9"
SERVICE_USER="$USER"

# Funciones de utilidad
print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Verificar si se ejecuta como root
if [ "$EUID" -eq 0 ]; then 
    print_error "No ejecutes este script como root (sin sudo)"
    print_info "Ejecuta: bash install-raspberry.sh"
    exit 1
fi

# Banner
clear
print_header "INSTALADOR DE PABS-TV"
echo ""
echo "Este script instalará PABS-TV y todas sus dependencias"
echo "en tu Raspberry Pi."
echo ""
echo "Directorio de instalación: $INSTALL_DIR"
echo "Usuario del sistema: $SERVICE_USER"
echo ""
read -p "¿Continuar con la instalación? (s/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    print_info "Instalación cancelada"
    exit 0
fi

# =====================================================
# PASO 1: Actualizar Sistema
# =====================================================
print_header "PASO 1: Actualizando sistema"

print_info "Actualizando lista de paquetes..."
sudo apt update

print_info "Actualizando paquetes instalados..."
sudo apt upgrade -y

print_success "Sistema actualizado"

# =====================================================
# PASO 2: Instalar Dependencias del Sistema
# =====================================================
print_header "PASO 2: Instalando dependencias del sistema"

PACKAGES=(
    "git"
    "python3"
    "python3-pip"
    "python3-venv"
    "mpv"
    "cec-utils"
    "net-tools"
    "curl"
    "wget"
)

for package in "${PACKAGES[@]}"; do
    if dpkg -l | grep -q "^ii  $package "; then
        print_success "$package ya está instalado"
    else
        print_info "Instalando $package..."
        sudo apt install -y "$package"
        print_success "$package instalado"
    fi
done

# yt-dlp (puede no estar en repos antiguos)
if command -v yt-dlp &> /dev/null; then
    print_success "yt-dlp ya está instalado"
else
    print_info "Instalando yt-dlp..."
    sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    sudo chmod a+rx /usr/local/bin/yt-dlp
    print_success "yt-dlp instalado"
fi

# rclone (opcional, para Nextcloud)
read -p "¿Deseas instalar rclone para sincronización con Nextcloud? (s/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    if command -v rclone &> /dev/null; then
        print_success "rclone ya está instalado"
    else
        print_info "Instalando rclone..."
        curl https://rclone.org/install.sh | sudo bash
        print_success "rclone instalado"
    fi
else
    print_info "Saltando instalación de rclone"
fi

print_success "Todas las dependencias del sistema instaladas"

# =====================================================
# PASO 3: Configurar Directorio del Proyecto
# =====================================================
print_header "PASO 3: Configurando directorio del proyecto"

if [ ! -d "$INSTALL_DIR" ]; then
    print_error "El directorio $INSTALL_DIR no existe"
    print_info "Este script debe ejecutarse desde el directorio del proyecto clonado"
    print_info "Ejecuta primero: git clone <tu-repo> $INSTALL_DIR"
    exit 1
fi

cd "$INSTALL_DIR"
print_success "Directorio configurado: $INSTALL_DIR"

# Crear directorios necesarios
mkdir -p "$INSTALL_DIR/media/videos"
mkdir -p "$INSTALL_DIR/media/images"
print_success "Directorios de medios creados"

# =====================================================
# PASO 4: Configurar Entorno Virtual Python
# =====================================================
print_header "PASO 4: Configurando entorno virtual Python"

if [ -d "$INSTALL_DIR/env" ]; then
    print_warning "Entorno virtual ya existe, se usará el existente"
else
    print_info "Creando entorno virtual..."
    python3 -m venv "$INSTALL_DIR/env"
    print_success "Entorno virtual creado"
fi

# Activar entorno virtual
source "$INSTALL_DIR/env/bin/activate"

# Actualizar pip
print_info "Actualizando pip..."
pip install --upgrade pip

# Instalar dependencias Python
print_info "Instalando dependencias Python..."
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    pip install -r "$INSTALL_DIR/requirements.txt"
    print_success "Dependencias Python instaladas"
else
    print_warning "No se encontró requirements.txt, instalando paquetes básicos..."
    pip install paho-mqtt yt-dlp python-dotenv
fi

print_success "Entorno Python configurado"

# =====================================================
# PASO 5: Configurar Variables de Entorno
# =====================================================
print_header "PASO 5: Configurando variables de entorno"

if [ -f "$INSTALL_DIR/.env" ]; then
    print_warning "Archivo .env ya existe"
    read -p "¿Deseas sobrescribirlo? (s/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        print_info "Manteniendo archivo .env existente"
        SKIP_ENV=true
    fi
fi

if [ "$SKIP_ENV" != true ]; then
    print_info "Creando archivo .env de ejemplo..."
    cat > "$INSTALL_DIR/.env" << 'EOF'
# Identificación del cliente
PABS_CLIENT_ID=sala-01-raspberry

# Configuración MQTT
MQTT_BROKER=localhost
MQTT_PORT=1883
MQTT_USER=
MQTT_PASSWORD=
MQTT_TOPIC_BASE=pabs-tv

# Configuración de logs
PABS_LOGFILE=/tmp/pabs-tv-client.log

# Rutas de medios
MEDIA_DIR=/home/pi/pabs-tv/media
EOF
    print_success "Archivo .env creado"
    print_warning "IMPORTANTE: Edita el archivo .env con tus configuraciones"
    print_info "Ejecuta: nano $INSTALL_DIR/.env"
fi

# =====================================================
# PASO 6: Configurar Playlist
# =====================================================
print_header "PASO 6: Configurando playlist"

if [ -f "$INSTALL_DIR/playlist.json" ]; then
    print_success "playlist.json ya existe"
else
    if [ -f "$INSTALL_DIR/playlist-example-with-schedule.json" ]; then
        print_info "Copiando playlist de ejemplo..."
        cp "$INSTALL_DIR/playlist-example-with-schedule.json" "$INSTALL_DIR/playlist.json"
        print_success "playlist.json creado desde ejemplo"
    else
        print_info "Creando playlist.json básico..."
        cat > "$INSTALL_DIR/playlist.json" << 'EOF'
{
  "schedule_enabled": true,
  "schedule_start": "08:00",
  "schedule_end": "22:00",
  "show_time": true,
  "list": [
    {
      "type": "image",
      "src": "media/images/ejemplo.jpg",
      "duration": 10
    }
  ]
}
EOF
        print_success "playlist.json creado"
        print_warning "Agrega tus videos e imágenes a la playlist"
    fi
fi

# =====================================================
# PASO 7: Configurar Servicio Systemd
# =====================================================
print_header "PASO 7: Configurando servicio systemd"

read -p "¿Deseas configurar PABS-TV como servicio del sistema? (s/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    print_info "Creando archivo de servicio..."
    
    sudo tee /etc/systemd/system/pabs-tv.service > /dev/null << EOF
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/env/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$INSTALL_DIR/env/bin/python3 $INSTALL_DIR/pabs-tv-client2.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    print_success "Servicio creado"
    
    print_info "Habilitando servicio..."
    sudo systemctl daemon-reload
    sudo systemctl enable pabs-tv.service
    print_success "Servicio habilitado"
    
    read -p "¿Deseas iniciar el servicio ahora? (s/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        sudo systemctl start pabs-tv.service
        sleep 2
        if sudo systemctl is-active --quiet pabs-tv.service; then
            print_success "Servicio iniciado correctamente"
        else
            print_error "Error al iniciar el servicio"
            print_info "Revisa los logs: journalctl -u pabs-tv.service -n 50"
        fi
    fi
else
    print_info "Saltando configuración de servicio"
    print_info "Puedes iniciar manualmente con: python3 pabs-tv-client2.py"
fi

# =====================================================
# PASO 8: Verificar Instalación
# =====================================================
print_header "PASO 8: Verificando instalación"

print_info "Verificando componentes..."

# Verificar Python
if python3 --version &> /dev/null; then
    PYTHON_VER=$(python3 --version)
    print_success "Python: $PYTHON_VER"
else
    print_error "Python no encontrado"
fi

# Verificar MPV
if command -v mpv &> /dev/null; then
    MPV_VER=$(mpv --version | head -n 1)
    print_success "MPV: $MPV_VER"
else
    print_error "MPV no encontrado"
fi

# Verificar yt-dlp
if command -v yt-dlp &> /dev/null; then
    YT_VER=$(yt-dlp --version)
    print_success "yt-dlp: $YT_VER"
else
    print_warning "yt-dlp no encontrado"
fi

# Verificar CEC
if command -v cec-client &> /dev/null; then
    print_success "cec-utils: instalado"
else
    print_warning "cec-utils no encontrado"
fi

# Verificar archivos
if [ -f "$INSTALL_DIR/.env" ]; then
    print_success "Archivo .env: existe"
else
    print_warning "Archivo .env: no encontrado"
fi

if [ -f "$INSTALL_DIR/playlist.json" ]; then
    print_success "Archivo playlist.json: existe"
else
    print_warning "Archivo playlist.json: no encontrado"
fi

# =====================================================
# RESUMEN
# =====================================================
print_header "INSTALACIÓN COMPLETADA"

echo ""
echo -e "${GREEN}✓ PABS-TV ha sido instalado correctamente${NC}"
echo ""
echo "Próximos pasos:"
echo ""
echo "1. Configurar MQTT en el archivo .env:"
echo "   nano $INSTALL_DIR/.env"
echo ""
echo "2. Editar la playlist:"
echo "   nano $INSTALL_DIR/playlist.json"
echo ""
echo "3. Agregar archivos multimedia:"
echo "   - Videos en: $INSTALL_DIR/media/videos/"
echo "   - Imágenes en: $INSTALL_DIR/media/images/"
echo ""
echo "4. Ver estado del servicio:"
echo "   sudo systemctl status pabs-tv.service"
echo ""
echo "5. Ver logs en tiempo real:"
echo "   journalctl -u pabs-tv.service -f"
echo ""
echo "6. Reiniciar servicio después de cambios:"
echo "   sudo systemctl restart pabs-tv.service"
echo ""
echo "7. Ejecutar diagnóstico:"
echo "   cd $INSTALL_DIR && bash check-mqtt-connections.sh"
echo ""
echo -e "${BLUE}Para más información, consulta: INSTALACION_RASPBERRY.md${NC}"
echo ""
print_success "¡Disfruta de PABS-TV! 🎉"
