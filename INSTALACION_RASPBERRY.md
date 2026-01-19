# 🍓 Guía de Instalación PABS-TV en Raspberry Pi

## 📋 Requisitos Previos

- **Raspberry Pi 3 o superior** (recomendado: Pi 4 con 2GB+ RAM)
- **Raspberry Pi OS** (anteriormente Raspbian) - versión Lite o Desktop
- **Conexión a Internet**
- **Tarjeta SD** (mínimo 16GB, recomendado 32GB)
- **Acceso SSH o monitor/teclado**

---

## 🚀 Instalación Rápida (Script Automatizado)

### 1. Descarga el proyecto

```bash
cd ~
git clone https://tu-repositorio/pabs-tv.git
cd pabs-tv
```

### 2. Ejecuta el script de instalación

```bash
chmod +x install-raspberry.sh
sudo ./install-raspberry.sh
```

---

## 🔧 Instalación Manual Paso a Paso

### Paso 1: Actualizar el Sistema

```bash
sudo apt update && sudo apt upgrade -y
```

### Paso 2: Instalar Dependencias del Sistema

```bash
# Herramientas básicas
sudo apt install -y git python3 python3-pip python3-venv

# Reproductor de medios MPV
sudo apt install -y mpv

# Control HDMI-CEC (para controlar TV)
sudo apt install -y cec-utils

# Utilidad de descarga de videos
sudo apt install -y yt-dlp

# Sincronización con Nextcloud (opcional)
sudo apt install -y rclone

# Herramientas de red
sudo apt install -y net-tools mosquitto-clients
```

### Paso 3: Clonar el Repositorio

```bash
cd ~
git clone https://tu-repositorio/pabs-tv.git
cd pabs-tv
```

### Paso 4: Crear Entorno Virtual Python

```bash
python3 -m venv env
source env/bin/activate
```

### Paso 5: Instalar Dependencias Python

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

**Nota:** Si `python-dotenv` no está en requirements.txt:
```bash
pip install python-dotenv
```

### Paso 6: Configurar Variables de Entorno

Crea un archivo `.env` en el directorio del proyecto:

```bash
nano .env
```

Contenido sugerido:

```env
# Identificación del cliente
PABS_CLIENT_ID=sala-01-raspberry

# Configuración MQTT
MQTT_BROKER=tu-broker-mqtt.com
MQTT_PORT=1883
MQTT_USER=usuario
MQTT_PASSWORD=contraseña
MQTT_TOPIC_BASE=pabs-tv

# Configuración de logs
PABS_LOGFILE=/home/pi/pabs-tv/pabs-tv-client.log

# Rutas de medios
MEDIA_DIR=/home/pi/pabs-tv/media
```

### Paso 7: Configurar Playlist

Crea o edita `playlist.json`:

```bash
cp playlist-example-with-schedule.json playlist.json
nano playlist.json
```

Ejemplo básico:

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
      "src": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "duration": 60
    }
  ]
}
```

### Paso 8: Configurar como Servicio Systemd

Crea el archivo de servicio:

```bash
sudo nano /etc/systemd/system/pabs-tv.service
```

Contenido:

```ini
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/pabs-tv
Environment="PATH=/home/pi/pabs-tv/env/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/home/pi/pabs-tv/env/bin/python3 /home/pi/pabs-tv/pabs-tv-client2.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Ajusta las rutas** si tu usuario no es `pi` o el proyecto está en otra ubicación.

Habilitar e iniciar el servicio:

```bash
sudo systemctl daemon-reload
sudo systemctl enable pabs-tv.service
sudo systemctl start pabs-tv.service
```

Verificar estado:

```bash
sudo systemctl status pabs-tv.service
```

Ver logs:

```bash
journalctl -u pabs-tv.service -f
```

---

## 🎮 Control HDMI-CEC (Opcional pero Recomendado)

### Verificar que CEC funcione

```bash
echo "scan" | cec-client -s -d 1
```

Deberías ver dispositivos conectados por HDMI.

### Probar comandos básicos

```bash
# Encender TV
echo "on 0" | cec-client -s -d 1

# Apagar TV
echo "standby 0" | cec-client -s -d 1

# Ver estado
echo "pow 0" | cec-client -s -d 1
```

---

## 🔄 Sincronización con Nextcloud (Opcional)

### Configurar rclone

```bash
rclone config
```

Sigue los pasos para configurar tu instancia de Nextcloud.

### Usar el script de sincronización

Edita `sync-nextcloud.sh` con tus parámetros:

```bash
nano sync-nextcloud.sh
```

Ajusta:
- `RCLONE_REMOTE="nextcloud"`
- `LOCAL_DIR="/home/pi/pabs-tv/media"`
- `REMOTE_PATH="pabs-tv/media"`

Ejecutar sincronización manual:

```bash
chmod +x sync-nextcloud.sh
./sync-nextcloud.sh
```

### Programar sincronización automática con cron

```bash
crontab -e
```

Agregar (sincronización cada 30 minutos):

```cron
*/30 * * * * /home/pi/pabs-tv/sync-nextcloud.sh >> /home/pi/pabs-tv/cron.log 2>&1
```

---

## 📊 Monitoreo y Diagnóstico

### Script de diagnóstico

```bash
chmod +x check-mqtt-connections.sh
./check-mqtt-connections.sh
```

### Comandos útiles

```bash
# Ver logs en tiempo real
tail -f /tmp/pabs-tv-client.log

# Ver procesos de pabs-tv
ps aux | grep pabs-tv

# Ver conexiones MQTT
ss -tunap | grep 1883

# Reiniciar servicio
sudo systemctl restart pabs-tv.service

# Detener servicio
sudo systemctl stop pabs-tv.service
```

---

## 🎯 Configuración Avanzada

### Auto-login y inicio de X11 (para Raspberry Pi Desktop)

Si quieres que la Raspberry arranque directo a modo kiosko:

1. **Configurar auto-login:**
```bash
sudo raspi-config
# System Options > Boot / Auto Login > Console Autologin
```

2. **Iniciar X11 automáticamente** (si usas modo gráfico):

Edita `/home/pi/.bashrc`:
```bash
if [ -z "$DISPLAY" ] && [ $(tty) = /dev/tty1 ]; then
    startx
fi
```

### Optimizaciones de rendimiento

**Aumentar memoria GPU (para video):**
```bash
sudo raspi-config
# Performance Options > GPU Memory > 256
```

**Desactivar Bluetooth (si no se usa):**

En `/boot/config.txt`:
```
dtoverlay=disable-bt
```

**Desactivar WiFi (si usas Ethernet):**
```
dtoverlay=disable-wifi
```

---

## 🔒 Seguridad

### Cambiar contraseña por defecto
```bash
passwd
```

### Actualizar sistema regularmente
```bash
# Crear script de actualización automática
sudo nano /etc/cron.weekly/update-system.sh
```

Contenido:
```bash
#!/bin/bash
apt update && apt upgrade -y && apt autoremove -y
```

```bash
sudo chmod +x /etc/cron.weekly/update-system.sh
```

---

## 🐛 Solución de Problemas

### MPV no reproduce videos

```bash
# Verificar instalación
mpv --version

# Probar reproducción manual
mpv --fs --loop=inf /home/pi/pabs-tv/media/videos/test.mp4
```

### MQTT no conecta

```bash
# Verificar broker
mosquitto_sub -h tu-broker.com -t "#" -v

# Verificar conectividad
ping tu-broker.com

# Ver logs
journalctl -u pabs-tv.service -n 50
```

### Problema con yt-dlp

```bash
# Actualizar yt-dlp
sudo pip3 install --upgrade yt-dlp

# O usar versión del sistema
sudo apt update
sudo apt install --reinstall yt-dlp
```

### Servicio no inicia

```bash
# Ver errores detallados
sudo journalctl -u pabs-tv.service -b -n 100

# Verificar permisos
ls -la /home/pi/pabs-tv/

# Ejecutar manualmente para ver errores
cd /home/pi/pabs-tv
source env/bin/activate
python3 pabs-tv-client2.py
```

---

## 📱 Control Remoto vía MQTT

### Comandos disponibles

```json
// Cambiar playlist
{
  "action": "reload_playlist"
}

// Configurar horarios
{
  "action": "loop.schedule",
  "enabled": true,
  "start_time": "08:00",
  "end_time": "22:00"
}

// Activar/desactivar timestamp
{
  "action": "loop.show_time",
  "enabled": true
}

// Control de TV (HDMI-CEC)
{
  "action": "hdmi.power_on"
}

{
  "action": "hdmi.power_off"
}
```

---

## 📚 Recursos Adicionales

- [Documentación MPV](https://mpv.io/manual/master/)
- [HDMI-CEC Guide](https://www.raspberry-pi-geek.com/Archive/2014/03/Controlling-your-TV-with-a-Raspberry-Pi)
- [Paho MQTT Python](https://www.eclipse.org/paho/index.php?page=clients/python/index.php)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp)

---

## ✅ Checklist de Instalación

- [ ] Sistema actualizado
- [ ] Python 3 y pip instalados
- [ ] MPV instalado y funcionando
- [ ] cec-utils instalado (si usas control HDMI)
- [ ] Entorno virtual creado
- [ ] Dependencias Python instaladas
- [ ] Archivo .env configurado
- [ ] playlist.json creado
- [ ] Servicio systemd configurado
- [ ] Servicio iniciado y habilitado
- [ ] MQTT conectando correctamente
- [ ] Videos reproduciéndose
- [ ] (Opcional) Sincronización Nextcloud configurada
- [ ] (Opcional) Cron job configurado

---

## 🆘 Soporte

Para problemas o dudas:
1. Revisa los logs: `journalctl -u pabs-tv.service -f`
2. Ejecuta el script de diagnóstico: `./check-mqtt-connections.sh`
3. Verifica el archivo de configuración `.env`
4. Comprueba la conectividad de red y MQTT

---

**¡Tu instalación de PABS-TV debería estar lista! 🎉**
