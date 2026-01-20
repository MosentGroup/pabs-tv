
# 🍓 Guía de Instalación PABS-TV en Raspberry Pi (Paso a Paso)

Esta guía deja PABS-TV instalado como **servicio systemd**, cargando `.env` correctamente y con configuración de entorno para que **mpv pueda abrir display** cuando corre como servicio (no solo en terminal).

---

## 0) Requisitos y Suposiciones

### Hardware / OS
- Raspberry Pi 3+ (recomendado Pi 4 / 2GB+)
- Raspberry Pi OS (Desktop recomendado si se reproduce en HDMI local)
- SD 16GB+ (recomendado 32GB)

### Acceso
- SSH o monitor/teclado
- Internet

### MQTT
- Host/puerto/credenciales del broker
- Un **CLIENT_ID único** por pantalla (para no “pisarse”)

---

## 1) Preparación del sistema (Raspberry Pi OS)

### 1.1 Actualizar paquetes
```bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
````

### 1.2 Instalar dependencias del sistema

```bash
sudo apt install -y \
  git \
  python3 python3-pip python3-venv \
  mpv \
  cec-utils \
  net-tools \
  mosquitto-clients \
  curl wget
```

Verifica:

```bash
python3 --version
mpv --version | head -n 1
```

---

## 2) Clonar el proyecto

### 2.1 Elegir directorio de instalación

Esta guía asume que se instala en:

* `~/pabs-tv`

Clonar:

```bash
cd ~
git clone https://github.com/MosentGroup/pabs-tv.git
cd pabs-tv
```

Verifica que estés en el repo:

```bash
ls -la
```

---

## 3) Crear entorno virtual (venv) e instalar dependencias Python

### 3.1 Crear venv

```bash
python3 -m venv env
```

### 3.2 Activar venv

```bash
source env/bin/activate
```

Verifica:

```bash
which python
python --version
```

### 3.3 Instalar requirements

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

> Si tu código usa dotenv, asegúrate de que `python-dotenv` esté en requirements (si no está, agrégalo y reinstala).
> En una instalación ya estable, se recomienda que `requirements.txt` incluya lo necesario para ejecutar.

---

## 4) Estructura de carpetas del proyecto (media/cache)

Crea la estructura requerida:

```bash
mkdir -p media/videos
mkdir -p media/images
mkdir -p cache
```

Verifica:

```bash
find media -maxdepth 2 -type d -print
```

---

## 5) Configuración `.env`

Archivo: `~/pabs-tv/.env`

### 5.1 Crear `.env` (si no existe)

```bash
cd ~/pabs-tv
test -f .env || nano .env
```

### 5.2 Variables de entorno (canon)

**MQTT**

* `PABS_CLIENT_ID` (recomendado obligatorio) → ID único por pantalla
* `PABS_MQTT_HOST`
* `PABS_MQTT_PORT`
* `PABS_MQTT_USER`
* `PABS_MQTT_PASS`
* `PABS_TOPIC_BASE` (default recomendado: `pabs-tv`)

**Logs**

* `PABS_LOGFILE` (default: `/tmp/pabs-tv-client.log`)
* `PABS_MPV_LOGFILE` (default: `/tmp/mpv.log`)

**Display (cuando corre como servicio)**

* `DISPLAY` (normalmente `:0`)
* Opcional si aplica (solo si tu sesión es Wayland):

  * `XDG_SESSION_TYPE=wayland`
  * `WAYLAND_DISPLAY=wayland-0`

**MPV (recomendado)**

* `PABS_MPV_HWDEC` (default: `no`)
* `PABS_MPV_YTDL_FORMAT` (default recomendado)
* `PABS_MPV_VO` (vacío = no forzar)
* `PABS_MPV_GPU_CONTEXT` (vacío = no forzar)

> Compatibilidad legacy: el cliente también acepta `CLIENT_ID`, `MQTT_BROKER`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASSWORD`, `MQTT_TOPIC_BASE`.

### 5.3 Ejemplo mínimo funcional (copiar/pegar y editar)

```env
# ===== Identidad (UNICO por pantalla) =====
PABS_CLIENT_ID=pabstv-sala-01

# ===== MQTT =====
PABS_MQTT_HOST=tu-broker.com
PABS_MQTT_PORT=1883
PABS_MQTT_USER=usuario
PABS_MQTT_PASS=password
PABS_TOPIC_BASE=pabs-tv

# ===== Logs =====
PABS_LOGFILE=/tmp/pabs-tv-client.log
PABS_MPV_LOGFILE=/tmp/mpv.log

# ===== Display (HDMI local) =====
DISPLAY=:0

# Si tu sesión gráfica es Wayland, descomenta:
# XDG_SESSION_TYPE=wayland
# WAYLAND_DISPLAY=wayland-0

# ===== MPV =====
PABS_MPV_HWDEC=no
PABS_MPV_YTDL_FORMAT=bestvideo[height<=720]+bestaudio/best/best
```

---

## 6) Playlist (`playlist.json`)

Archivo: `~/pabs-tv/playlist.json`

### 6.1 Crear/editar

```bash
cd ~/pabs-tv
nano playlist.json
```

### 6.2 Formato

El cliente acepta:

* `items` (preferido)
* `list` (compatibilidad; el cliente lo normaliza)

Cada item acepta:

* `kind` (preferido) o `type` (compatibilidad): `image` | `video` | `youtube`
* `src` (ruta o URL)
* `duration` (para imágenes)
* `start_at` (videos/youtube)
* `prefetch` (youtube; descarga al cache y reproduce local)

Ejemplo recomendado:

```json
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
```

> Copia tus archivos a:

* `~/pabs-tv/media/images/`
* `~/pabs-tv/media/videos/`

---

## 7) Crear el servicio systemd (final)

Archivo: `/etc/systemd/system/pabs-tv.service`

### 7.1 Crear/editar unit

```bash
sudo nano /etc/systemd/system/pabs-tv.service
```

### 7.2 Contenido FINAL (copiar/pegar)

> Ajusta solo si tus rutas/usuario cambian.

```ini
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target display-manager.service
Wants=network-online.target

[Service]
Type=simple
User=pabstvroot
WorkingDirectory=/home/pabstvroot/pabs-tv

EnvironmentFile=-/home/pabstvroot/pabs-tv/.env

Environment="PATH=/home/pabstvroot/pabs-tv/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=/home/pabstvroot"
Environment="XDG_CONFIG_HOME=/home/pabstvroot/.config"
Environment="XDG_RUNTIME_DIR=/run/user/%U"

Environment="DISPLAY=:0"
Environment="XDG_SESSION_TYPE=wayland"
Environment="WAYLAND_DISPLAY=wayland-0"

ExecStart=/home/pabstvroot/pabs-tv/env/bin/python3 /home/pabstvroot/pabs-tv/pabs-tv-client2.py

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

> Si tu Raspberry NO usa Wayland (X11), comenta en el servicio:

* `XDG_SESSION_TYPE=wayland`
* `WAYLAND_DISPLAY=wayland-0`

y deja `DISPLAY=:0`.

### 7.3 Recargar systemd, habilitar y arrancar

```bash
sudo systemctl daemon-reload
sudo systemctl enable pabs-tv.service
sudo systemctl restart pabs-tv.service
```

### 7.4 Confirmar estado

```bash
sudo systemctl status pabs-tv.service
```

Logs:

```bash
journalctl -u pabs-tv.service -f
```

---

## 8) Verificación de display (clave para mpv)

### 8.1 Verificar variables básicas (en tu sesión)

```bash
echo "$DISPLAY"
echo "$XDG_SESSION_TYPE"
```

### 8.2 Probar que el usuario del servicio puede abrir display

Cambia `pabstvroot` por tu usuario real:

```bash
sudo -u pabstvroot DISPLAY=:0 xset q
```

Si responde con información (y no error), el servicio puede “ver” el display.

---

## 9) Diagnóstico de errores típicos

### 9.1 Ver últimos 200 logs del servicio

```bash
journalctl -u pabs-tv.service -n 200 --no-pager
```

### 9.2 Buscar errores comunes de video/vo

```bash
journalctl -u pabs-tv.service -n 400 --no-pager | grep -E "Failed initializing|Video: no video|Error opening|vo="
```

### 9.3 Ver logs de mpv

```bash
tail -n 200 /tmp/mpv.log
```

---

## 10) Pruebas MQTT rápidas

Topic de comandos:

* `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/cmd`

### 10.1 Loop start

```bash
mosquitto_pub -h tu-broker.com -p 1883 \
  -t "pabs-tv/pabstv-sala-01/cmd" \
  -m '{"action":"loop.start"}'
```

### 10.2 Play once

```bash
mosquitto_pub -h tu-broker.com -p 1883 \
  -t "pabs-tv/pabstv-sala-01/cmd" \
  -m '{"action":"play.once","item":{"kind":"video","src":"media/videos/ejemplo.mp4"},"return_to_loop":true}'
```

### 10.3 Apagar/encender TV (si aplica)

```bash
mosquitto_pub -h tu-broker.com -p 1883 \
  -t "pabs-tv/pabstv-sala-01/cmd" \
  -m '{"action":"tv.power","state":"on"}'
```

```bash
mosquitto_pub -h tu-broker.com -p 1883 \
  -t "pabs-tv/pabstv-sala-01/cmd" \
  -m '{"action":"tv.power","state":"off"}'
```

---

## 11) Instalación usando `install-raspberry.sh` (modo guiado)

Si prefieres automático:

```bash
cd ~/pabs-tv
chmod +x install-raspberry.sh
bash install-raspberry.sh
```

Después:

```bash
nano .env
nano playlist.json
sudo systemctl restart pabs-tv.service
journalctl -u pabs-tv.service -f
```

---

## 12) Checklist final

* [ ] `~/pabs-tv/.env` con `PABS_CLIENT_ID` único
* [ ] MQTT configurado y accesible
* [ ] Carpetas creadas: `media/videos`, `media/images`, `cache`
* [ ] `playlist.json` válido (con `items` o `list`)
* [ ] Servicio creado: `/etc/systemd/system/pabs-tv.service`
* [ ] `systemctl status pabs-tv.service` OK
* [ ] `sudo -u <user> DISPLAY=:0 xset q` responde OK
* [ ] `tail -f /tmp/mpv.log` sin errores de `--vo`

---

