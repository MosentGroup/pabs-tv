
# PABS TV — Documentación (Markdown)

## Índice
- [1. Qué es PABS TV](#1-qué-es-pabs-tv)
- [2. Componentes del sistema](#2-componentes-del-sistema)
- [3. Conceptos principales](#3-conceptos-principales)
- [4. Operación del player (Raspberry Pi)](#4-operación-del-player-raspberry-pi)
- [5. Instalación en Raspberry Pi (script)](#5-instalación-en-raspberry-pi-script)
- [6. Estructura de carpetas](#6-estructura-de-carpetas)
- [7. Comandos útiles](#7-comandos-útiles)
- [8. Troubleshooting (lo más común)](#8-troubleshooting-lo-más-común)

---

## 1. Qué es PABS TV
PABS TV es un sistema para **transmitir y administrar contenido multimedia en pantallas a distancia** usando:
- **Raspberry Pi 5** como reproductor (player).
- **Backend/Frontend (Node + React)** para gestión: dispositivos, colecciones, salas, horarios, loops, estado.

Permite:
- Reproducción simultánea en múltiples pantallas.
- Gestión remota de playlists/loops.
- Detener, re-sincronizar y recuperar reproducción cuando hay desfase.

---

## 2. Componentes del sistema
- **Dashboard (Web)**: administración y monitoreo (dispositivos, schedules, loops, configuración).
- **Player (Raspberry Pi)**:
  - Reproduce contenido local.
  - Se sincroniza con remoto cuando hay internet.
  - Reporta estado (online/offline / now playing).

---

## 3. Conceptos principales
- **Dispositivo/Player**: Raspberry registrada con un `CLIENT_ID` (ej: `pabstvLmpiso-04`).
- **Contenido**: videos/imágenes descargados localmente en `./media`.
- **Loop / Playlist**:
  - Existe una **playlist local** (JSON) que define el orden de reproducción.
  - Es **actualizable** desde remoto cuando hay conexión.
- **Modo Streaming vs Offline**:
  - Online: se sincroniza, reporta estado y se actualiza contenido/loop.
  - Offline: reproduce en loop lo último disponible en local.

---

## 4. Operación del player (Raspberry Pi)
Premisas (en este orden):
1. **La Raspberry debe estar conectada a Wi-Fi todo el tiempo.**
2. Si **se desconecta de Wi-Fi**, seguirá reproduciendo en loop el contenido que tenga en local dentro de `./media`.
3. El loop local es un **JSON** (playlist) con el contenido y **orden de reproducción**.
4. Al **reconectarse a Wi-Fi**:
   - Reporta nuevamente al sistema.
   - Se actualiza contenido local + playlist/loop.
   - Cambia a **modo streaming** y el monitor/dash vuelve a reflejar el estado.

---

## 5. Instalación en Raspberry Pi (script)
> Instalación con **un solo script**: `install-raspberry.sh` (idempotente).

### 5.1 Requisitos
- Raspberry Pi OS / Debian/Ubuntu (con `apt`)
- Acceso a internet para instalar dependencias
- Recomendado clonar en: `/home/<usuario>/pabs-tv`

### 5.2 Instalación (2 comandos)
```bash
cd /home/<usuario>/pabs-tv
chmod +x install-raspberry.sh
bash install-raspberry.sh
````

El instalador:

* instala dependencias (ej. Python, `mpv`, etc.)
* crea el **venv** en `./env`
* crea carpetas `./media`, `./cache`, `./scripts`
* genera/actualiza `.env`
* crea/actualiza el servicio `pabs-tv.service`
* opcional: configura **rclone/Nextcloud** y crea un **timer** que sincroniza cada 30 min

### 5.3 Variables que pide el instalador

#### `PABS_CLIENT_ID`

Identificador único del player.
Ejemplos:

* `pabstvLmpiso-04`
* `sala-01`
* `recepcion-tv`

Uso: el servidor/monitor lo usa para identificar la pantalla y construir tópicos MQTT.

#### `PABS_MQTT_HOST`

IP o dominio del broker MQTT.
Ejemplos:

* `3.18.167.209`
* `localhost`

#### `PABS_MQTT_PORT`

Normalmente: `1883`

#### `PABS_TOPIC_BASE`

Base de tópicos (normalmente: `pabs-tv`).

Tópicos típicos:

* `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/cmd`
* `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/status`
* `${PABS_TOPIC_BASE}/${PABS_CLIENT_ID}/now_playing`

#### `PABS_MQTT_USER` / `PABS_MQTT_PASS`

Credenciales del broker.

> `.env` contiene secretos: **no subir al repo**.

### 5.4 Sync con Nextcloud (opcional)

Si se habilita sync por **rclone**, sincroniza cada 30 min:

* Si existe remote `nextcloud:` → se reutiliza
* Si no existe → corre `rclone config`

`REMOTE_PATH` (ruta remota dentro de Nextcloud), ejemplos:

* `pabs-tv/media`
* `TV_MEDIA/media`

Logs del sync:

* `./cron-sync.log`

Ver timer:

```bash
cd /home/<usuario>/pabs-tv
systemctl status pabs-tv-media-sync.timer
```

---

## 6. Estructura de carpetas

* `./media/videos/` → videos locales
* `./media/images/` → imágenes locales
* `./playlist.json` → lista de reproducción local
* `./.env` → configuración (MQTT, paths, mpv, sync)
* `./scripts/` → scripts auxiliares (ej. sync)

---

## 7. Comandos útiles

### 7.1 Ver logs del servicio

```bash
cd /home/<usuario>/pabs-tv
journalctl -u pabs-tv.service -f
```

### 7.2 Reiniciar servicio

```bash
cd /home/<usuario>/pabs-tv
sudo systemctl restart pabs-tv.service
```

### 7.3 Ver log de mpv

```bash
cd /home/<usuario>/pabs-tv
tail -n 200 /tmp/mpv.log
```

### 7.4 Forzar sincronización (si está habilitada)

```bash
cd /home/<usuario>/pabs-tv
bash sync-nextcloud.sh
```

---

## 8. Troubleshooting (lo más común)

### 8.1 Un dispositivo aparece “offline” o no se ve conectado

1. **Primero** verificar Wi-Fi en la Raspberry:

* Conectar **mouse + teclado** a la Raspberry.
* Ir a configuración Wi-Fi gráficamente.
* Confirmar que tenga internet.

2. Si **sí tiene Wi-Fi**, acceder por TeamViewer:

* Entrar con el **ID y contraseña** registrados en la tabla anexa “TeamViewer dispositivos”.
* Revisar logs del servicio y reiniciar si aplica.

```bash
cd /home/<usuario>/pabs-tv
journalctl -u pabs-tv.service -f
```

```bash
cd /home/<usuario>/pabs-tv
sudo systemctl restart pabs-tv.service
```

### 8.2 Reproduce contenido viejo cuando vuelve el internet

* Esto es esperado si estuvo offline: reproduce el loop local.
* Al reconectar, debe:

  * reportar estado,
  * actualizar `./media` y `./playlist.json`,
  * volver a reflejarse en el monitor/dash.

Acciones rápidas:

```bash
cd /home/<usuario>/pabs-tv
sudo systemctl restart pabs-tv.service
```

Si existe sync:

```bash
cd /home/<usuario>/pabs-tv
bash sync-nextcloud.sh
```

### 8.3 MQTT “Connected” pero estado no cuadra en dashboard

Revisar consistencia:

* `PABS_CLIENT_ID` (debe coincidir con el esperado por el servidor/monitor)
* `PABS_TOPIC_BASE`
* host/puerto/credenciales del broker

```bash
cd /home/<usuario>/pabs-tv
cat .env
```

```

Si quieres, pégame aquí:
- el contenido actual de tu `.env` (sin password, o enmascarado),
- y/o la estructura exacta del `playlist.json`,
y te dejo una sección “Configuración” y “Formato de playlist” bien cerrada y sin texto de más.
```
