
````md
# 🍓 Guía de Instalación PABS-TV en Raspberry Pi

Este documento deja PABS-TV **instalado como servicio systemd**, con `.env` cargado correctamente y con una configuración de display/mpv que evita los errores típicos al correr como servicio.

---

## 📌 Requisitos

- Raspberry Pi 3+ (recomendado Pi 4 / 2GB+)
- Raspberry Pi OS (Desktop recomendado si vas a reproducir en pantalla local)
- Acceso a Internet
- Acceso SSH o monitor/teclado
- Broker MQTT accesible (host/puerto/credenciales)

---

## ✅ Variables de entorno (canon)

Archivo: `~/pabs-tv/.env`

**MQTT**
- `PABS_CLIENT_ID` (obligatorio recomendado) → ID único por pantalla
- `PABS_MQTT_HOST`
- `PABS_MQTT_PORT`
- `PABS_MQTT_USER`
- `PABS_MQTT_PASS`
- `PABS_TOPIC_BASE` (default: `pabs-tv`)

**Rutas**
- `PABS_PROJECT_DIR` (default: raíz del repo)
- `PABS_MEDIA_DIR` (default: `<repo>/media`)
- `PABS_PLAYLIST_FILE` (default: `<repo>/playlist.json`)
- `PABS_CACHE_DIR` (default: `<repo>/cache`)

**Logs**
- `PABS_LOGFILE` (default: `/tmp/pabs-tv-client.log`)
- `PABS_MPV_LOGFILE` (default: `/tmp/mpv.log`)

**Display (cuando corre como servicio)**
- `DISPLAY` (normalmente `:0`)
- `XDG_RUNTIME_DIR` (systemd lo puede resolver con `/run/user/%U`)
- Opcional si aplica:
  - `XDG_SESSION_TYPE=wayland`
  - `WAYLAND_DISPLAY=wayland-0`

**MPV (recomendado)**
- `PABS_MPV_VO` (vacío = no forzar; mpv decide / usa `mpv.conf`)
- `PABS_MPV_GPU_CONTEXT` (vacío = no forzar)
- `PABS_MPV_HWDEC` (default: `no`)
- `PABS_MPV_YTDL_FORMAT` (default: `bestvideo[height<=720]+bestaudio/best/best`)
- `PABS_MPV_EXTRA_OPTS` (opcional; flags adicionales de mpv)

> Compatibilidad legacy: el cliente también acepta `CLIENT_ID`, `MQTT_BROKER`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASSWORD`, `MQTT_TOPIC_BASE`.

---

## 🚀 Instalación Rápida (recomendado)

### 1) Clonar repositorio
```bash
cd ~
git clone https://github.com/MosentGroup/pabs-tv.git
cd pabs-tv
````

### 2) Ejecutar instalador

```bash
chmod +x install-raspberry.sh
bash install-raspberry.sh
```

El instalador:

* Instala dependencias del sistema
* Crea `env/` (venv) e instala requirements
* Crea `media/videos`, `media/images`, `cache`
* Crea `.env` base (si no existe)
* Crea y habilita `pabs-tv.service` (opcional)

### 3) Editar `.env`

```bash
nano ~/pabs-tv/.env
```

Ejemplo mínimo:

```env
PABS_CLIENT_ID=pabstv-sala-01
PABS_MQTT_HOST=tu-broker.com
PABS_MQTT_PORT=1883
PABS_MQTT_USER=usuario
PABS_MQTT_PASS=password
PABS_TOPIC_BASE=pabs-tv

DISPLAY=:0
PABS_MPV_HWDEC=no
```

### 4) Reiniciar servicio

```bash
sudo systemctl restart pabs-tv.service
sudo systemctl status pabs-tv.service
```

Logs:

```bash
journalctl -u pabs-tv.service -f
```

---

## 🧩 Playlist

Archivo: `~/pabs-tv/playlist.json`

El cliente acepta:

* `items` (preferido)
* `list` (compatibilidad; el cliente lo normaliza)

Cada item puede usar:

* `kind` (preferido) o `type` (compatibilidad): `image` | `video` | `youtube`
* `src`: ruta o URL
* `duration`: para imágenes (mpv image-display-duration)
* `start_at`: para videos/youtube
* `prefetch`: para youtube (descarga al cache y reproduce local)

Ejemplo:

```json
{
  "schedule_enabled": true,
  "schedule_start": "08:00",
  "schedule_end": "22:00",
  "show_time": true,
  "items": [
    { "kind": "image", "src": "media/images/ejemplo.jpg", "duration": 10 },
    { "kind": "video", "src": "media/videos/ejemplo.mp4" },
    { "kind": "youtube", "src": "https://www.youtube.com/watch?v=XXXX", "prefetch": true }
  ]
}
```

---

## 🧠 Diagnóstico rápido

### Estado del servicio

```bash
sudo systemctl status pabs-tv.service
```

### Logs del servicio (últimos 200)

```bash
journalctl -u pabs-tv.service -n 200 --no-pager
```

### Logs de mpv

```bash
tail -n 200 /tmp/mpv.log
```

### Confirmar que el servicio “ve” el display

```bash
sudo -u "$USER" DISPLAY=:0 xset q
```

Si esto falla con “unable to open display”, entonces el problema está en:

* no hay sesión gráfica (modo Lite/console sin X)
* `DISPLAY` incorrecto
* permisos de sesión gráfica

---

## 🎮 Control por MQTT (acciones)

Topic de comandos:

* `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/cmd`

Ejemplos de payload:

Loop:

```json
{ "action": "loop.start" }
```

Stop:

```json
{ "action": "loop.stop" }
```

Reproducir una vez:

```json
{
  "action": "play.once",
  "item": { "kind": "video", "src": "media/videos/ejemplo.mp4" },
  "return_to_loop": true
}
```

Horario:

```json
{ "action": "loop.schedule", "enabled": true, "start_time": "08:00", "end_time": "22:00" }
```

Encender/apagar TV:

```json
{ "action": "tv.power", "state": "on" }
```

```json
{ "action": "tv.power", "state": "off" }
```

---

## 🧱 Instalación Manual (si no quieres script)

### Dependencias del sistema

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git python3 python3-pip python3-venv mpv cec-utils net-tools mosquitto-clients curl wget
```

### Repo + venv

```bash
cd ~
git clone https://github.com/MosentGroup/pabs-tv.git
cd pabs-tv
python3 -m venv env
source env/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

### Carpetas

```bash
mkdir -p media/videos media/images cache
```

### Servicio systemd

```bash
sudo nano /etc/systemd/system/pabs-tv.service
```

Contenido recomendado:

```ini
[Unit]
Description=PABS-TV Digital Signage Client
After=network-online.target display-manager.service
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/pabs-tv
EnvironmentFile=/home/pi/pabs-tv/.env
Environment="PATH=/home/pi/pabs-tv/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=/home/pi"
Environment="XDG_CONFIG_HOME=/home/pi/.config"
Environment="XDG_RUNTIME_DIR=/run/user/%U"
ExecStart=/home/pi/pabs-tv/env/bin/python3 /home/pi/pabs-tv/pabs-tv-client2.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Activar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable pabs-tv.service
sudo systemctl start pabs-tv.service
```

---

## ✅ Checklist

* [ ] `.env` con `PABS_CLIENT_ID` único por Raspberry
* [ ] MQTT host/port correctos
* [ ] `DISPLAY=:0` si reproduce en pantalla local
* [ ] `playlist.json` con `items`/`list`
* [ ] `systemctl status pabs-tv.service` OK
* [ ] `tail -f /tmp/mpv.log` sin errores de `--vo`

---

````


---

## `README_INSTALACION.md` (reemplazar completo)

```md
# 🍓 PABS-TV — Instalación Rápida (Raspberry Pi)

## Instalación en 3 pasos

### 1) Clonar
```bash
cd ~
git clone https://github.com/MosentGroup/pabs-tv.git
cd pabs-tv
````

### 2) Ejecutar instalador

```bash
chmod +x install-raspberry.sh
bash install-raspberry.sh
```

### 3) Configurar y reiniciar

```bash
nano .env
nano playlist.json
sudo systemctl restart pabs-tv.service
```

Logs:

```bash
journalctl -u pabs-tv.service -f
```

---

## Variables mínimas (`.env`)

Archivo: `~/pabs-tv/.env`

```env
PABS_CLIENT_ID=pabstv-sala-01
PABS_MQTT_HOST=tu-broker.com
PABS_MQTT_PORT=1883
PABS_MQTT_USER=
PABS_MQTT_PASS=
PABS_TOPIC_BASE=pabs-tv

DISPLAY=:0
PABS_MPV_HWDEC=no
```

---

## Playlist (`playlist.json`)

Formato recomendado:

* `items` (aunque acepta `list` por compatibilidad)

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

---

## Comandos útiles

Estado:

```bash
sudo systemctl status pabs-tv.service
```

Reiniciar:

```bash
sudo systemctl restart pabs-tv.service
```

Logs (últimos 200):

```bash
journalctl -u pabs-tv.service -n 200 --no-pager
```

Logs mpv:

```bash
tail -n 200 /tmp/mpv.log
```

Verificar display:

```bash
sudo -u "$USER" DISPLAY=:0 xset q
```

---

## Acciones MQTT

Topic:

* `pabs-tv/<CLIENT_ID>/cmd`

Loop:

```json
{ "action": "loop.start" }
```

Stop:

```json
{ "action": "loop.stop" }
```

Play once:

```json
{
  "action": "play.once",
  "item": { "kind": "video", "src": "media/videos/ejemplo.mp4" },
  "return_to_loop": true
}
```

TV Power:

```json
{ "action": "tv.power", "state": "on" }
```

---

```

---
```
