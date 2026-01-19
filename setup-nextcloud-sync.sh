#!/bin/bash
# =====================================================
# Script de Configuración de Sincronización Nextcloud
# Para PABS-TV
# =====================================================

set -e

# Colores
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

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

clear
print_header "CONFIGURACIÓN DE NEXTCLOUD SYNC"
echo ""

# Verificar rclone
if ! command -v rclone &> /dev/null; then
    print_error "rclone no está instalado"
    echo ""
    read -p "¿Deseas instalarlo ahora? (s/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        print_info "Instalando rclone..."
        curl https://rclone.org/install.sh | sudo bash
        print_success "rclone instalado"
    else
        print_error "No se puede continuar sin rclone"
        exit 1
    fi
fi

# Configurar rclone
print_header "CONFIGURACIÓN DE RCLONE"
echo ""
print_info "A continuación se abrirá el asistente de configuración de rclone"
print_info "Sigue estos pasos:"
echo ""
echo "1. Selecciona: n (New remote)"
echo "2. Nombre: nextcloud"
echo "3. Tipo: 36 (WebDAV)"
echo "4. URL: https://tu-nextcloud.com/remote.php/dav/files/tu-usuario/"
echo "5. Vendor: 1 (Nextcloud)"
echo "6. Usuario: tu-usuario"
echo "7. Contraseña: tu-contraseña (o token de aplicación)"
echo "8. Bearer token: [Enter para saltar]"
echo "9. Advanced config: n"
echo "10. Remote config OK: y"
echo "11. Quit: q"
echo ""
read -p "Presiona Enter para continuar..."

rclone config

# Verificar configuración
if ! rclone listremotes | grep -q "^nextcloud:$"; then
    print_error "No se encontró la configuración 'nextcloud'"
    print_info "Reintenta ejecutando este script"
    exit 1
fi

print_success "rclone configurado correctamente"

# Configurar variables
print_header "CONFIGURACIÓN DE RUTAS"
echo ""

DEFAULT_LOCAL_DIR="$HOME/pabs-tv/media"
DEFAULT_REMOTE_PATH="pabs-tv/media"

read -p "Ruta local para medios [$DEFAULT_LOCAL_DIR]: " LOCAL_DIR
LOCAL_DIR="${LOCAL_DIR:-$DEFAULT_LOCAL_DIR}"

read -p "Ruta remota en Nextcloud [$DEFAULT_REMOTE_PATH]: " REMOTE_PATH
REMOTE_PATH="${REMOTE_PATH:-$DEFAULT_REMOTE_PATH}"

echo ""
print_info "Configuración:"
echo "  Local:  $LOCAL_DIR"
echo "  Remote: nextcloud:$REMOTE_PATH"
echo ""

# Crear directorio local
mkdir -p "$LOCAL_DIR"
print_success "Directorio local creado"

# Probar conexión
print_info "Probando conexión con Nextcloud..."
if rclone lsd "nextcloud:" > /dev/null 2>&1; then
    print_success "Conexión exitosa con Nextcloud"
else
    print_error "No se pudo conectar con Nextcloud"
    print_info "Verifica tus credenciales y URL"
    exit 1
fi

# Crear carpeta remota si no existe
print_info "Verificando carpeta remota..."
rclone mkdir "nextcloud:$REMOTE_PATH" 2>/dev/null || true
print_success "Carpeta remota verificada"

# Actualizar script de sincronización
SYNC_SCRIPT="$HOME/pabs-tv/sync-nextcloud.sh"
if [ -f "$SYNC_SCRIPT" ]; then
    print_info "Actualizando variables en sync-nextcloud.sh..."
    
    # Crear backup
    cp "$SYNC_SCRIPT" "$SYNC_SCRIPT.bak"
    
    # Actualizar variables
    sed -i "s|^LOCAL_DIR=.*|LOCAL_DIR=\"$LOCAL_DIR\"|" "$SYNC_SCRIPT"
    sed -i "s|^REMOTE_PATH=.*|REMOTE_PATH=\"$REMOTE_PATH\"|" "$SYNC_SCRIPT"
    
    print_success "Script actualizado"
else
    print_info "Creando nuevo script de sincronización..."
    
    cat > "$SYNC_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
# Script de sincronización automática con Nextcloud usando rclone

# Configuración
RCLONE_REMOTE="nextcloud"
LOCAL_DIR="LOCAL_DIR_PLACEHOLDER"
REMOTE_PATH="REMOTE_PATH_PLACEHOLDER"
LOG_FILE="$HOME/pabs-tv/nextcloud-sync.log"
SYNC_MODE="bidirectional"

# Crear carpeta local si no existe
mkdir -p "$LOCAL_DIR"

# Función para logging con timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Verificar rclone
if ! command -v rclone &> /dev/null; then
    log "❌ ERROR: rclone no está instalado"
    exit 1
fi

# Verificar remote
if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
    log "❌ ERROR: Remote '${RCLONE_REMOTE}' no configurado"
    exit 1
fi

log "🔄 Iniciando sincronización: $SYNC_MODE"
log "   Local:  $LOCAL_DIR"
log "   Remote: ${RCLONE_REMOTE}:${REMOTE_PATH}"

START_TIME=$(date +%s)

# Sincronización bidireccional
if [ "$SYNC_MODE" = "bidirectional" ]; then
    log "📥 Descargando cambios desde Nextcloud..."
    if rclone sync "${RCLONE_REMOTE}:${REMOTE_PATH}" "$LOCAL_DIR" --verbose --log-file="$LOG_FILE" --log-level INFO; then
        log "✓ Descarga completada"
    else
        log "❌ Error en descarga"
        exit 1
    fi
    
    log "📤 Subiendo cambios a Nextcloud..."
    if rclone sync "$LOCAL_DIR" "${RCLONE_REMOTE}:${REMOTE_PATH}" --verbose --log-file="$LOG_FILE" --log-level INFO; then
        log "✓ Subida completada"
    else
        log "❌ Error en subida"
        exit 1
    fi
elif [ "$SYNC_MODE" = "download" ]; then
    if rclone sync "${RCLONE_REMOTE}:${REMOTE_PATH}" "$LOCAL_DIR" --verbose --log-file="$LOG_FILE" --log-level INFO; then
        log "✓ Sincronización completada"
    else
        log "❌ Error en sincronización"
        exit 1
    fi
elif [ "$SYNC_MODE" = "upload" ]; then
    if rclone sync "$LOCAL_DIR" "${RCLONE_REMOTE}:${REMOTE_PATH}" --verbose --log-file="$LOG_FILE" --log-level INFO; then
        log "✓ Sincronización completada"
    else
        log "❌ Error en sincronización"
        exit 1
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "✅ Sincronización finalizada en ${DURATION}s"

# Mostrar estadísticas
FILES_COUNT=$(find "$LOCAL_DIR" -type f | wc -l)
DISK_USAGE=$(du -sh "$LOCAL_DIR" | cut -f1)
log "📊 Archivos locales: $FILES_COUNT | Espacio: $DISK_USAGE"
EOFSCRIPT

    # Reemplazar placeholders
    sed -i "s|LOCAL_DIR_PLACEHOLDER|$LOCAL_DIR|" "$SYNC_SCRIPT"
    sed -i "s|REMOTE_PATH_PLACEHOLDER|$REMOTE_PATH|" "$SYNC_SCRIPT"
    
    chmod +x "$SYNC_SCRIPT"
    print_success "Script de sincronización creado"
fi

# Probar sincronización
print_header "PRUEBA DE SINCRONIZACIÓN"
echo ""
read -p "¿Deseas ejecutar una sincronización de prueba? (s/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    print_info "Ejecutando sincronización..."
    bash "$SYNC_SCRIPT"
    print_success "Sincronización completada"
fi

# Configurar cron
print_header "AUTOMATIZACIÓN CON CRON"
echo ""
print_info "Puedes configurar sincronización automática con cron"
echo ""
echo "Opciones sugeridas:"
echo "  1) Cada 30 minutos: */30 * * * *"
echo "  2) Cada hora:       0 * * * *"
echo "  3) Cada 6 horas:    0 */6 * * *"
echo "  4) Diario a las 3am: 0 3 * * *"
echo ""
read -p "¿Deseas configurar cron ahora? (s/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    echo ""
    read -p "Selecciona opción (1-4) o escribe tu expresión cron: " CRON_CHOICE
    
    case $CRON_CHOICE in
        1)
            CRON_EXPR="*/30 * * * *"
            ;;
        2)
            CRON_EXPR="0 * * * *"
            ;;
        3)
            CRON_EXPR="0 */6 * * *"
            ;;
        4)
            CRON_EXPR="0 3 * * *"
            ;;
        *)
            CRON_EXPR="$CRON_CHOICE"
            ;;
    esac
    
    CRON_COMMAND="$CRON_EXPR $SYNC_SCRIPT >> $HOME/pabs-tv/cron-sync.log 2>&1"
    
    # Agregar a crontab
    (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
    
    print_success "Tarea cron configurada: $CRON_EXPR"
    print_info "Logs en: $HOME/pabs-tv/cron-sync.log"
fi

# Resumen
print_header "CONFIGURACIÓN COMPLETADA"
echo ""
print_success "Nextcloud sync configurado correctamente"
echo ""
echo "Comandos útiles:"
echo ""
echo "  Sincronizar manualmente:"
echo "    bash $SYNC_SCRIPT"
echo ""
echo "  Ver logs:"
echo "    tail -f $HOME/pabs-tv/nextcloud-sync.log"
echo ""
echo "  Listar archivos remotos:"
echo "    rclone ls nextcloud:$REMOTE_PATH"
echo ""
echo "  Ver tareas cron:"
echo "    crontab -l"
echo ""
print_success "¡Listo para usar! 🎉"
