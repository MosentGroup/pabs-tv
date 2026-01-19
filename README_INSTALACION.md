# 🍓 Instalación Rápida en Raspberry Pi

## Instalación en 3 Pasos

### 1️⃣ Clonar el repositorio
```bash
cd ~
git clone <tu-repositorio-url> pabs-tv
cd pabs-tv
```

### 2️⃣ Ejecutar instalador automático
```bash
chmod +x install-raspberry.sh
bash install-raspberry.sh
```

### 3️⃣ Configurar y lanzar
```bash
# Editar configuración MQTT
nano .env

# Editar playlist
nano playlist.json

# Reiniciar servicio
sudo systemctl restart pabs-tv.service
```

## 📋 Requisitos Mínimos

- **Hardware:** Raspberry Pi 3 o superior (recomendado: Pi 4 con 2GB+ RAM)
- **Sistema:** Raspberry Pi OS (Lite o Desktop)
- **Almacenamiento:** Tarjeta SD de 16GB mínimo
- **Red:** Conexión a Internet y acceso al broker MQTT

## 🎯 ¿Qué hace el instalador?

El script `install-raspberry.sh` instala automáticamente:

✅ Actualizaciones del sistema  
✅ Python 3 + pip + venv  
✅ MPV (reproductor multimedia)  
✅ yt-dlp (descarga de videos)  
✅ cec-utils (control HDMI-CEC de la TV)  
✅ Dependencias Python (paho-mqtt, python-dotenv)  
✅ Servicio systemd para inicio automático  
✅ Estructura de directorios  

## 📱 Uso Básico

### Ver estado del servicio
```bash
sudo systemctl status pabs-tv.service
```

### Ver logs en tiempo real
```bash
journalctl -u pabs-tv.service -f
```

### Reiniciar después de cambios
```bash
sudo systemctl restart pabs-tv.service
```

### Detener el servicio
```bash
sudo systemctl stop pabs-tv.service
```

## 🔧 Configuración

### Archivo .env (Configuración MQTT)
```env
PABS_CLIENT_ID=sala-01-raspberry
MQTT_BROKER=tu-broker.com
MQTT_PORT=1883
MQTT_USER=usuario
MQTT_PASSWORD=contraseña
```

### Archivo playlist.json (Lista de reproducción)
```json
{
  "schedule_enabled": true,
  "schedule_start": "08:00",
  "schedule_end": "22:00",
  "show_time": true,
  "list": [
    {
      "type": "video",
      "src": "media/videos/video1.mp4",
      "duration": 30
    },
    {
      "type": "image",
      "src": "media/images/imagen1.jpg",
      "duration": 10
    },
    {
      "type": "youtube",
      "src": "https://www.youtube.com/watch?v=VIDEO_ID",
      "duration": 60
    }
  ]
}
```

## 🌩️ Sincronización con Nextcloud (Opcional)

```bash
# Ejecutar script de configuración
chmod +x setup-nextcloud-sync.sh
bash setup-nextcloud-sync.sh

# Sincronizar manualmente
bash sync-nextcloud.sh
```

## 🎮 Control Remoto por MQTT

### Recargar playlist
```bash
mosquitto_pub -h broker.com -t "pabs-tv/sala-01/commands" \
  -m '{"action":"reload_playlist"}'
```

### Configurar horarios
```bash
mosquitto_pub -h broker.com -t "pabs-tv/sala-01/commands" \
  -m '{"action":"loop.schedule","enabled":true,"start_time":"08:00","end_time":"22:00"}'
```

### Encender/Apagar TV (HDMI-CEC)
```bash
# Encender
mosquitto_pub -h broker.com -t "pabs-tv/sala-01/commands" \
  -m '{"action":"hdmi.power_on"}'

# Apagar
mosquitto_pub -h broker.com -t "pabs-tv/sala-01/commands" \
  -m '{"action":"hdmi.power_off"}'
```

## 🐛 Solución de Problemas

### El servicio no inicia
```bash
# Ver errores detallados
sudo journalctl -u pabs-tv.service -n 100

# Ejecutar manualmente para depurar
cd ~/pabs-tv
source env/bin/activate
python3 pabs-tv-client2.py
```

### MQTT no conecta
```bash
# Probar conexión al broker
mosquitto_sub -h tu-broker.com -t "#" -v

# Verificar conectividad
ping tu-broker.com

# Revisar archivo .env
cat ~/pabs-tv/.env
```

### Videos no reproducen
```bash
# Probar MPV manualmente
mpv --fs ~/pabs-tv/media/videos/test.mp4

# Verificar archivos
ls -la ~/pabs-tv/media/videos/

# Ver logs de MPV
tail -f /tmp/mpv.log
```

### Diagnóstico completo
```bash
cd ~/pabs-tv
chmod +x check-mqtt-connections.sh
bash check-mqtt-connections.sh
```

## 📚 Documentación Completa

Para instrucciones detalladas, ver:
- **[INSTALACION_RASPBERRY.md](INSTALACION_RASPBERRY.md)** - Guía completa de instalación
- **[NUEVAS_FUNCIONALIDADES.md](NUEVAS_FUNCIONALIDADES.md)** - Funcionalidades y configuración
- **[SCHEDULER_MQTT.md](SCHEDULER_MQTT.md)** - Control por MQTT

## 🆘 Ayuda

### Comandos útiles

```bash
# Ver procesos de pabs-tv
ps aux | grep pabs-tv

# Ver conexiones MQTT activas
ss -tunap | grep 1883

# Ver uso de CPU/RAM
top -p $(pgrep -f pabs-tv)

# Espacio en disco
df -h

# Ver temperatura de la Raspberry
vcgencmd measure_temp
```

### Archivos importantes

- `/etc/systemd/system/pabs-tv.service` - Servicio systemd
- `~/pabs-tv/.env` - Configuración MQTT
- `~/pabs-tv/playlist.json` - Lista de reproducción
- `/tmp/pabs-tv-client.log` - Logs de la aplicación
- `/tmp/mpv.log` - Logs del reproductor

## 🎉 ¡Listo!

Tu sistema PABS-TV debería estar funcionando. Si tienes problemas:

1. ✅ Revisa los logs: `journalctl -u pabs-tv.service -f`
2. ✅ Ejecuta diagnóstico: `bash check-mqtt-connections.sh`
3. ✅ Verifica archivo .env y playlist.json
4. ✅ Consulta la documentación completa

---

**Desarrollado para control de cartelería digital en Raspberry Pi** 🍓📺
