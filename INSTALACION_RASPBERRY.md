# Instalación (Raspberry Pi) – PABS‑TV (versión resumida)

Este proyecto se instala **con un solo script**: `install-raspberry.sh`.  

---

## 1) Requisitos

- Raspberry Pi OS / Debian/Ubuntu (con `apt`)
- Acceso a internet para instalar dependencias
- Recomendado: tener el repo en una ruta tipo: `/home/<usuario>/pabs-tv`

---

## 2) Instalación (2 comandos)

Desde la raíz del proyecto:

```bash
chmod +x install-raspberry.sh
bash install-raspberry.sh
```

El instalador:
- instala dependencias (Python, mpv, etc.)
- crea el **venv** en `./env`
- crea carpetas `./media`, `./cache`, `./scripts`
- genera/actualiza `.env`
- crea/actualiza el servicio `pabs-tv.service`
- opcional: configura **rclone/Nextcloud** y crea un **timer** que sincroniza cada 30 min

> Es **idempotente**: si algo ya existe, lo reutiliza o lo actualiza sin romper.

---

## 3) Campos que te pedirá el instalador (qué poner y para qué sirve)

### PABS_CLIENT_ID
Identificador único del player.  
Ejemplos:
- `pabstvLmpiso-04`
- `sala-01`
- `recepcion-tv`

**Para qué sirve:** el servidor/monitor lo usa para saber qué pantalla es y para construir los tópicos MQTT.

---

### PABS_MQTT_HOST
IP o dominio del broker MQTT.  
Ejemplos:
- `3.18.167.209`
- `localhost` (si el broker está en la misma Raspberry)

**Para qué sirve:** donde el cliente se conecta para recibir comandos y mandar estado.

---

### PABS_MQTT_PORT
Normalmente `1883`.

---

### PABS_TOPIC_BASE
Base de tópicos. Normalmente `pabs-tv`.

**Resultado típico:** el cliente usará:
- `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/cmd`
- `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/status`
- `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/now_playing`

---

### PABS_MQTT_USER / PABS_MQTT_PASS
Credenciales del broker .

**Nota:** `.env` contiene secretos → **no lo subas al repo**.

---

### Sync con Nextcloud (opcional)
El instalador puede habilitar sync por **rclone** cada 30 minutos.

- Si ya existe el remote `nextcloud:` en rclone → lo reutiliza.
- Si no existe → abre `rclone config` para crearlo.

Te pedirá:

#### REMOTE_PATH (ruta remota dentro de nextcloud)
Ejemplos:
- `pabs-tv/media`
- `TV_MEDIA/media`

**Para qué sirve:** de ahí se baja el contenido hacia `./media/` (videos e imágenes).

**Logs del sync:**
- `./cron-sync.log`

**Ver timer:**
```bash
systemctl status pabs-tv-media-sync.timer
```

---

## 4) Estructura de carpetas importante

- `media/videos/` → videos locales
- `media/images/` → imágenes locales
- `playlist.json` → lista de reproducción local
- `.env` → configuración (MQTT, paths, mpv, sync)
- `scripts/` → scripts auxiliares creados por el instalador (ej. sync)

---

## 5) Comandos útiles

### Ver logs del servicio
```bash
journalctl -u pabs-tv.service -f
```

### Reiniciar servicio
```bash
sudo systemctl restart pabs-tv.service
```

### Ver log de mpv
```bash
tail -n 200 /tmp/mpv.log
```

### Forzar sincronización (si está habilitada)
```bash
bash sync-nextcloud.sh
```

---

## 6) Notas rápidas

- Si usas Wayland/XWayland, el instalador detecta qué soporta tu `mpv` y evita forzar `x11` cuando no existe.
- Si tu broker MQTT marca “offline” a veces es por:
  - `CLIENT_ID` distinto al que espera el servidor, o
  - tópicos base diferentes, o
  - el servidor espera un “online” retain (depende de cómo esté hecho del lado servidor).

