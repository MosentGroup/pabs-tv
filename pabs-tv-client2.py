#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import logging
import os
import queue
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, time as dt_time
from logging.handlers import RotatingFileHandler
from pathlib import Path

# ----------------------------
# Helpers
# ----------------------------
def _env_get(keys, default=None):
    for k in keys:
        v = os.environ.get(k)
        if v is not None and str(v).strip() != "":
            return v
    return default

def _safe_name(s: str) -> str:
    out = []
    for ch in str(s):
        if ch.isalnum() or ch in ("-", "_", ".", "@"):
            out.append(ch)
        else:
            out.append("_")
    return "".join(out)[:80]

def _atomic_write_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}")
    txt = json.dumps(data, ensure_ascii=False, indent=2)
    tmp.write_text(txt, encoding="utf-8")
    tmp.replace(path)

# ----------------------------
# Logging
# ----------------------------
LOG_FILE = _env_get(
    ["PABS_LOGFILE", "PABS_LOG_FILE", "PABS_LOG_PATH"],
    os.path.join(tempfile.gettempdir(), "pabs-tv-client.log"),
)

handlers = []
try:
    fh = RotatingFileHandler(LOG_FILE, maxBytes=10 * 1024 * 1024, backupCount=2)
    fh.setLevel(logging.INFO)
    handlers.append(fh)
except Exception:
    pass

sh = logging.StreamHandler(sys.stdout)
sh.setLevel(logging.DEBUG)
handlers.append(sh)

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=handlers,
)
log = logging.getLogger("pabs-tv")

# ----------------------------
# dotenv (optional)
# ----------------------------
try:
    from dotenv import load_dotenv
    base_guess = Path(__file__).resolve().parent
    load_dotenv(dotenv_path=str(base_guess / ".env"), override=False)
except Exception:
    pass

# ----------------------------
# Config
# ----------------------------
HOSTNAME = socket.gethostname()
CLIENT_ID = _env_get(["PABS_CLIENT_ID", "CLIENT_ID"], None)
if not CLIENT_ID:
    CLIENT_ID = f"sala-01-{HOSTNAME}-{os.getpid()}"

MQTT_HOST = _env_get(["PABS_MQTT_HOST", "MQTT_BROKER", "MQTT_HOST"], "localhost")
MQTT_PORT = int(_env_get(["PABS_MQTT_PORT", "MQTT_PORT"], "1883"))
MQTT_USER = _env_get(["PABS_MQTT_USER", "MQTT_USER", "MQTT_USERNAME"], "") or None
MQTT_PASS = _env_get(["PABS_MQTT_PASS", "MQTT_PASSWORD", "MQTT_PASS"], "") or None

TOPIC_BASE = _env_get(["PABS_TOPIC_BASE", "MQTT_TOPIC_BASE"], "pabs-tv").strip().strip("/")

TOPIC_CMD = _env_get(["PABS_TOPIC_CMD"], f"{TOPIC_BASE}/{CLIENT_ID}/cmd")
TOPIC_STATUS = _env_get(["PABS_TOPIC_STATUS"], f"{TOPIC_BASE}/{CLIENT_ID}/status")
TOPIC_NOWPLAY = _env_get(["PABS_TOPIC_NOWPLAY"], f"{TOPIC_BASE}/{CLIENT_ID}/now_playing")

PROJECT_DIR = Path(_env_get(["PABS_PROJECT_DIR"], str(Path(__file__).resolve().parent))).expanduser().resolve()
MEDIA_DIR = Path(_env_get(["PABS_MEDIA_DIR", "MEDIA_DIR"], str(PROJECT_DIR / "media"))).expanduser()
LOCAL_PLAYLIST_FILE = Path(_env_get(["PABS_PLAYLIST_FILE"], str(PROJECT_DIR / "playlist.json"))).expanduser()
CACHE_DIR = Path(_env_get(["PABS_CACHE_DIR"], str(PROJECT_DIR / "cache"))).expanduser()

REMOTE_PLAYLIST_FILE = Path(
    _env_get(["PABS_REMOTE_PLAYLIST_FILE"], str(PROJECT_DIR / "playlist.remote.json"))
).expanduser()

PERSIST_REMOTE_PLAYLIST = _env_get(["PABS_PERSIST_REMOTE_PLAYLIST"], "1").lower() in ("1", "true", "yes", "y")
OVERWRITE_LOCAL_PLAYLIST = _env_get(["PABS_OVERWRITE_LOCAL_PLAYLIST", "PABS_OVERWRITE_PLAYLIST_JSON"], "0").lower() in ("1", "true", "yes", "y")

MEDIA_VIDEO_DIR = MEDIA_DIR / "videos"
MEDIA_IMAGE_DIR = MEDIA_DIR / "images"
for p in (MEDIA_VIDEO_DIR, MEDIA_IMAGE_DIR, CACHE_DIR):
    try:
        p.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

log.info("===== CONFIG =====")
log.info("CLIENT_ID: %s", CLIENT_ID)
log.info("MQTT: %s:%s", MQTT_HOST, MQTT_PORT)
log.info("TOPIC_CMD: %s", TOPIC_CMD)
log.info("TOPIC_STATUS: %s", TOPIC_STATUS)
log.info("TOPIC_NOWPLAY: %s", TOPIC_NOWPLAY)
log.info("PROJECT_DIR: %s", PROJECT_DIR)
log.info("MEDIA_DIR: %s", MEDIA_DIR)
log.info("LOCAL_PLAYLIST_FILE: %s", LOCAL_PLAYLIST_FILE)
log.info("REMOTE_PLAYLIST_FILE: %s", REMOTE_PLAYLIST_FILE)
log.info("CACHE_DIR: %s", CACHE_DIR)
log.info("DISPLAY: %s", os.environ.get("DISPLAY"))
log.info("XDG_SESSION_TYPE: %s", os.environ.get("XDG_SESSION_TYPE"))
log.info("WAYLAND_DISPLAY: %s", os.environ.get("WAYLAND_DISPLAY"))
log.info("==================")

# ----------------------------
# MPV
# ----------------------------
MPV = shutil.which("mpv") or "/usr/bin/mpv"
MPV_LOG = _env_get(["PABS_MPV_LOGFILE"], "/tmp/mpv.log")
MPV_YTDL_FORMAT = _env_get(["PABS_MPV_YTDL_FORMAT"], "bestvideo[height<=720]+bestaudio/best/best")
MPV_HWDEC = _env_get(["PABS_MPV_HWDEC"], "no")

MPV_VO = _env_get(["PABS_MPV_VO"], "").strip()
MPV_GPU_CONTEXT = _env_get(["PABS_MPV_GPU_CONTEXT"], "").strip()
MPV_EXTRA_OPTS_RAW = _env_get(["PABS_MPV_EXTRA_OPTS"], "").strip()

MPV_IPC_PATH = Path(_env_get(
    ["PABS_MPV_IPC_SOCKET"],
    f"/tmp/pabs-tv-mpv-{_safe_name(CLIENT_ID)}.sock"
))

# mpv persistente: se queda abierto y solo cambiamos contenido por IPC
MPV_BASE_OPTS = [
    MPV,
    "--fs",
    "--no-osc",
    "--no-osd-bar",
    "--idle=yes",
    "--keep-open=yes",
    "--force-window=yes",
    "--volume=100",
    "--volume-max=100",
    f"--log-file={MPV_LOG}",
    f"--ytdl-format={MPV_YTDL_FORMAT}",
    f"--hwdec={MPV_HWDEC}",
    f"--input-ipc-server={str(MPV_IPC_PATH)}",
]

if MPV_VO:
    MPV_BASE_OPTS.append(f"--vo={MPV_VO}")
if MPV_GPU_CONTEXT:
    MPV_BASE_OPTS.append(f"--gpu-context={MPV_GPU_CONTEXT}")
if MPV_EXTRA_OPTS_RAW:
    MPV_BASE_OPTS.extend(MPV_EXTRA_OPTS_RAW.split())

YTDL_OPTS = ["--ytdl"]
YTDL_FORMAT_TRIES = [
    "bestvideo[height<=720]+bestaudio/best/best",
    "bestvideo[height<=1080]+bestaudio/best/best",
    "bestvideo+bestaudio/best",
    "best",
]

# ----------------------------
# State
# ----------------------------
state_lock = threading.Lock()
MODE_LOOP = "LOOP"
MODE_DIRECT = "DIRECT"

state = {
    "mode": MODE_LOOP,
    "loop_running": False,
    "loop_playlist": None,
    "loop_playlist_file": None,
    "loop_black_between": 0,
    "loop_shuffle": False,
    "retries": 0,
    "current_item": None,
    "current_src": "ninguno",
    "paused": False,
    "last_error": None,
    "show_time": False,
    "schedule_enabled": False,
    "schedule_start": None,
    "schedule_end": None,
    "scheduled_playlists": [],
    "active_scheduled_playlist": None,
    "mqtt_connected": False,
}

stop_all_event = threading.Event()
loop_should_run = threading.Event()
direct_queue = queue.Queue()
schedule_change_event = threading.Event()

mpv_proc = None
mpv_lock = threading.Lock()

mqtt_connected_evt = threading.Event()

# ----------------------------
# MQTT helpers
# ----------------------------
def publish(client, topic, payload, retain=False):
    try:
        payload_json = json.dumps(payload, ensure_ascii=False)
    except Exception as e:
        log.error("[MQTT][SEND] json error (%s): %s", topic, e)
        return
    try:
        log.info("[MQTT][SEND] %s | %s", topic, payload_json)
        return client.publish(topic, payload_json, qos=1, retain=bool(retain))
    except Exception as e:
        log.error("[MQTT][SEND] publish error (%s): %s", topic, e)

def set_state(**kwargs):
    with state_lock:
        state.update(kwargs)

def get_state():
    with state_lock:
        return dict(state)

def publish_status_snapshot(mqttc, event="status"):
    st = get_state()
    payload = {
        "event": event,
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "mode": st.get("mode", MODE_LOOP),
        "client_id": CLIENT_ID,
        "src": st.get("current_src", "ninguno"),
        "paused": bool(st.get("paused", False)),
        "mqtt_connected": bool(st.get("mqtt_connected", False)),
    }
    publish(mqttc, TOPIC_STATUS, payload, retain=True)

# ----------------------------
# MPV IPC
# ----------------------------
def _mpv_ipc_send(cmd_obj: dict, timeout=0.4):
    import socket as pysocket
    if not MPV_IPC_PATH.exists():
        return None, "ipc_socket_missing"
    s = pysocket.socket(pysocket.AF_UNIX, pysocket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(str(MPV_IPC_PATH))
        msg = (json.dumps(cmd_obj) + "\n").encode("utf-8")
        s.sendall(msg)
        try:
            data = s.recv(65535)
            if not data:
                return None, "no_response"
            try:
                return json.loads(data.decode("utf-8", errors="ignore")), None
            except Exception:
                return None, "bad_response"
        except Exception:
            return None, "recv_error"
    except Exception as e:
        return None, str(e)
    finally:
        try:
            s.close()
        except Exception:
            pass

def _mpv_get_property(prop: str):
    resp, err = _mpv_ipc_send({"command": ["get_property", prop]})
    if err is not None or not isinstance(resp, dict):
        return None
    return resp.get("data")

def _mpv_set_property(prop: str, value):
    resp, err = _mpv_ipc_send({"command": ["set_property", prop, value]})
    return err is None

def mpv_set_pause(paused: bool) -> bool:
    with mpv_lock:
        global mpv_proc
        resp, err = _mpv_ipc_send({"command": ["set_property", "pause", bool(paused)]})
        if err is None:
            set_state(paused=bool(paused))
            return True

        if mpv_proc is not None:
            try:
                if paused:
                    os.kill(mpv_proc.pid, signal.SIGSTOP)
                else:
                    os.kill(mpv_proc.pid, signal.SIGCONT)
                set_state(paused=bool(paused))
                return True
            except Exception:
                pass
    return False

def mpv_toggle_pause() -> bool:
    st = get_state()
    target = not bool(st.get("paused", False))
    return mpv_set_pause(target)

def mpv_quit() -> bool:
    resp, err = _mpv_ipc_send({"command": ["quit"]})
    if err is None:
        return True
    with mpv_lock:
        global mpv_proc
        if mpv_proc is not None:
            try:
                mpv_proc.terminate()
                return True
            except Exception:
                return False
    return False

def _mpv_stop_playback():
    _mpv_ipc_send({"command": ["stop"]})

def _ensure_mpv_running():
    global mpv_proc
    with mpv_lock:
        if mpv_proc is not None:
            if mpv_proc.poll() is None:
                return True
            mpv_proc = None

        # limpiar socket viejo antes de arrancar
        try:
            if MPV_IPC_PATH.exists():
                MPV_IPC_PATH.unlink()
        except Exception:
            pass

        try:
            log.info("[MPV] arrancando persistente: %s", " ".join(MPV_BASE_OPTS))
            mpv_proc = subprocess.Popen(MPV_BASE_OPTS)
        except Exception as e:
            log.error("[MPV] no se pudo iniciar mpv: %s", e)
            mpv_proc = None
            return False

    # esperar socket
    t0 = time.time()
    while time.time() - t0 < 2.0:
        if MPV_IPC_PATH.exists():
            # aplicar volumen por si acaso
            _mpv_set_property("volume", 100)
            _mpv_set_property("mute", False)
            return True
        time.sleep(0.02)

    log.warning("[MPV] mpv inició pero no apareció el socket IPC")
    return False

def _mpv_loadfile(src: str, start_at=None):
    if not _ensure_mpv_running():
        return False

    # Garantizar volumen alto siempre
    _mpv_set_property("volume", 100)
    _mpv_set_property("mute", False)
    _mpv_set_property("pause", False)

    # start= (para videos/urls)
    if start_at:
        resp, err = _mpv_ipc_send({"command": ["loadfile", src, "replace", f"start={start_at}"]})
    else:
        resp, err = _mpv_ipc_send({"command": ["loadfile", src, "replace"]})

    if err is None:
        return True

    log.warning("[MPV] loadfile error: %s", err)
    return False

def _wait_until_idle(max_wait=None):
    # idle-active: True cuando no está reproduciendo nada
    t0 = time.time()
    while True:
        if stop_all_event.is_set():
            _mpv_stop_playback()
            return "stopped"

        idle = _mpv_get_property("idle-active")
        if idle is True:
            return "idle"

        if max_wait is not None and (time.time() - t0) > max_wait:
            return "timeout"

        time.sleep(0.2)

# ----------------------------
# Media / Playback
# ----------------------------
def build_media_path(src, kind):
    if not src:
        return src
    if src.startswith("/") or src.startswith("http://") or src.startswith("https://"):
        return src
    if "/" in src or "\\" in src:
        return src
    if kind == "video":
        return str(MEDIA_VIDEO_DIR / src)
    if kind == "image":
        return str(MEDIA_IMAGE_DIR / src)
    return src

def play_image_persistent(src, duration):
    # Cargar la imagen y mantenerla en pantalla el tiempo indicado,
    # sin cerrar mpv (evita “flash” del escritorio).
    ok = _mpv_loadfile(src)
    if not ok:
        return False

    secs = int(duration or 8)
    t0 = time.time()
    while (time.time() - t0) < secs:
        if stop_all_event.is_set():
            _mpv_stop_playback()
            return False
        time.sleep(0.1)

    # detener para quedar idle y pasar al siguiente item
    _mpv_stop_playback()
    _wait_until_idle(max_wait=2)
    return True

def play_video_persistent(src, start_at=None):
    ok = _mpv_loadfile(src, start_at=start_at)
    if not ok:
        return False

    # esperar a que termine el video (idle-active vuelve True)
    res = _wait_until_idle(max_wait=None)
    return res == "idle"

def play_youtube_persistent(url, start_at=None):
    ok = _mpv_loadfile(url, start_at=start_at)
    if ok:
        res = _wait_until_idle(max_wait=None)
        return res == "idle"

    # fallback igual que antes (yt-dlp)
    log.warning("[YOUTUBE] mpv directo falló, intentando fallback yt-dlp: %s", url)
    ytdlp = shutil.which("yt-dlp") or shutil.which("youtube-dl")
    if not ytdlp:
        log.error("[YOUTUBE] yt-dlp/youtube-dl no encontrado")
        return False

    for fmt in YTDL_FORMAT_TRIES:
        try:
            out = subprocess.check_output([ytdlp, "-f", fmt, "--get-url", url], text=True, stderr=subprocess.STDOUT, timeout=20)
            urls = [l.strip() for l in out.splitlines() if l.strip()]
            for du in urls:
                ok2 = _mpv_loadfile(du, start_at=start_at)
                if ok2:
                    res = _wait_until_idle(max_wait=None)
                    if res == "idle":
                        return True
        except Exception:
            continue

    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        out_pattern = str(CACHE_DIR / "%(id)s.%(ext)s")
        dl_cmd = [ytdlp, "-f", "bv*+ba/b", "-o", out_pattern, url]
        okd = subprocess.call(dl_cmd) == 0
        if okd:
            try:
                vid = subprocess.check_output([ytdlp, "--get-id", url], text=True).strip()
            except Exception:
                vid = None
            if vid:
                for ext in ("mp4", "mkv", "webm"):
                    cand = CACHE_DIR / f"{vid}.{ext}"
                    if cand.exists():
                        return play_video_persistent(str(cand), start_at=start_at)
            files = list(CACHE_DIR.glob("*.*"))
            if files:
                files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
                return play_video_persistent(str(files[0]), start_at=start_at)
    except Exception as e:
        log.error("[YOUTUBE] fallback descarga error: %s", e)

    return False

# ----------------------------
# TV power control (igual que antes)
# ----------------------------
def tv_power_control(state_req):
    state_req = (state_req or "").lower()
    if state_req not in ("on", "off"):
        return False, "invalid state"

    cec_only = os.environ.get("PABS_TV_CEC_ONLY", "0") in ("1", "true", "True")

    if not cec_only:
        tvs = shutil.which("tvservice")
        if tvs:
            try:
                cmd = [tvs, "-p"] if state_req == "on" else [tvs, "-o"]
                res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                out = (res.stdout or b"").decode("utf-8", errors="ignore").strip()
                err = (res.stderr or b"").decode("utf-8", errors="ignore").strip()
                if res.returncode == 0:
                    return True, out or "tvservice success"
                log.warning("[TV] tvservice falló: %s", err or out)
            except Exception as e:
                log.error("[TV] tvservice excepción: %s", e)

        vcgen = shutil.which("vcgencmd")
        if vcgen:
            try:
                power_val = "1" if state_req == "on" else "0"
                res = subprocess.run([vcgen, "display_power", power_val], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                out = (res.stdout or b"").decode("utf-8", errors="ignore").strip()
                err = (res.stderr or b"").decode("utf-8", errors="ignore").strip()
                if res.returncode == 0 and "not registered" not in (out + err).lower():
                    return True, out or "vcgencmd success"
            except Exception as e:
                log.error("[TV] vcgencmd excepción: %s", e)

        xset = shutil.which("xset")
        if xset and os.environ.get("DISPLAY"):
            try:
                cmd = [xset, "dpms", "force", "on"] if state_req == "on" else [xset, "dpms", "force", "off"]
                res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                if res.returncode == 0:
                    return True, "xset dpms success"
            except Exception as e:
                log.error("[TV] xset excepción: %s", e)

    cec = shutil.which("cec-client")
    if cec:
        try:
            cmd = [cec, "-s", "-d", "1"]
            inp = "on 0\n" if state_req == "on" else "standby 0\n"
            res = subprocess.run(cmd, input=inp, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            out = (res.stdout or "").strip()
            err = (res.stderr or "").strip()
            combined = (out + "\n" + err).lower()
            bad = any(p in combined for p in ["cec_transmit failed", "failed to open", "no device", "errno="])
            if res.returncode == 0 and not bad:
                return True, out or "cec success"
            return False, err or out or "cec failed"
        except Exception as e:
            return False, str(e)

    return False, "no method available"

# ----------------------------
# Schedule helpers
# ----------------------------
def parse_time_str(time_str):
    if not time_str:
        return None
    try:
        parts = time_str.strip().split(":")
        if len(parts) != 2:
            return None
        h, m = int(parts[0]), int(parts[1])
        return dt_time(hour=h, minute=m)
    except Exception:
        return None

def is_within_schedule(start_time_str, end_time_str):
    if not start_time_str and not end_time_str:
        return True

    start_t = parse_time_str(start_time_str)
    end_t = parse_time_str(end_time_str)

    if not start_t:
        return True

    now = datetime.now().time()

    if not end_t:
        return now >= start_t

    if start_t <= end_t:
        return start_t <= now <= end_t
    return now >= start_t or now <= end_t

# ----------------------------
# Playlist normalize/load/persist
# ----------------------------
def normalize_playlist(data):
    if not isinstance(data, dict):
        return {"items": []}

    if "items" not in data and "list" in data:
        data["items"] = data.pop("list")

    items = data.get("items") or []
    norm_items = []
    for it in items:
        if not isinstance(it, dict):
            continue
        if "kind" not in it and "type" in it:
            it["kind"] = it.pop("type")
        norm_items.append(it)

    data["items"] = norm_items
    data.setdefault("shuffle", False)
    data.setdefault("black_between", 0)
    data.setdefault("retries", 0)
    data.setdefault("show_time", False)
    data.setdefault("schedule_enabled", False)
    data.setdefault("schedule_start", None)
    data.setdefault("schedule_end", None)
    return data

def load_playlist_from_file(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    return normalize_playlist(raw)

def persist_remote_playlist(playlist: dict):
    if not PERSIST_REMOTE_PLAYLIST:
        return
    pl = normalize_playlist(dict(playlist))
    try:
        _atomic_write_json(REMOTE_PLAYLIST_FILE, pl)
        log.info("[PLAYLIST] Guardada playlist remota: %s", REMOTE_PLAYLIST_FILE)
    except Exception as e:
        log.error("[PLAYLIST] Error guardando playlist remota: %s", e)

    if OVERWRITE_LOCAL_PLAYLIST:
        try:
            _atomic_write_json(LOCAL_PLAYLIST_FILE, pl)
            log.info("[PLAYLIST] (overwrite) Guardada también en local: %s", LOCAL_PLAYLIST_FILE)
        except Exception as e:
            log.error("[PLAYLIST] Error overwrite local: %s", e)

def choose_boot_playlist_file() -> Path:
    try:
        if REMOTE_PLAYLIST_FILE.exists():
            return REMOTE_PLAYLIST_FILE
    except Exception:
        pass
    return LOCAL_PLAYLIST_FILE

# ----------------------------
# Prefetch YouTube (igual que antes)
# ----------------------------
def maybe_prefetch(item, publish_fn=None):
    if item.get("kind") != "youtube" or not item.get("prefetch"):
        return item
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        return item

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        vid = subprocess.check_output([ytdlp, "--get-id", item["src"]], text=True).strip()
    except Exception:
        return item

    for ext in ("mp4", "mkv", "webm"):
        cand = CACHE_DIR / f"{vid}.{ext}"
        if cand.exists():
            new_item = dict(item)
            new_item["kind"] = "video"
            new_item["src"] = str(cand)
            new_item.pop("prefetch", None)
            return new_item

    out_pattern = str(CACHE_DIR / "%(id)s.%(ext)s")
    cmd = [ytdlp, "-f", "bv*+ba/b", "-o", out_pattern, item["src"]]
    if publish_fn:
        publish_fn({"event": "prefetch.start", "url": item["src"]})
    ok = subprocess.call(cmd) == 0
    if not ok:
        if publish_fn:
            publish_fn({"event": "prefetch.error", "url": item["src"]})
        return item

    for ext in ("mp4", "mkv", "webm"):
        cand = CACHE_DIR / f"{vid}.{ext}"
        if cand.exists():
            new_item = dict(item)
            new_item["kind"] = "video"
            new_item["src"] = str(cand)
            new_item.pop("prefetch", None)
            return new_item

    return item

# ----------------------------
# Playback handlers
# ----------------------------
def handle_item_play(item, retries, publish_fn=None, show_time=False):
    it = maybe_prefetch(item, publish_fn=publish_fn)
    kind = it.get("kind")
    src = it.get("src")
    dur = it.get("duration")
    start = it.get("start_at")

    full_path = build_media_path(src, kind)
    set_state(current_src=full_path or "ninguno", paused=False)

    for _attempt in range(int(retries or 0) + 1):
        if stop_all_event.is_set():
            _mpv_stop_playback()
            return "stopped"

        payload_start = {"event": "start", "item": it}
        if show_time:
            payload_start["timestamp"] = datetime.now().strftime("%H:%M:%S")
        if publish_fn:
            publish_fn(payload_start)

        ok = True
        if kind == "image":
            ok = play_image_persistent(full_path, dur or 8)
        elif kind == "video":
            ok = play_video_persistent(full_path, start_at=start)
        elif kind == "youtube":
            ok = play_youtube_persistent(full_path, start_at=start)

        payload_end = {"event": "end", "item": it, "ok": bool(ok)}
        if show_time:
            payload_end["timestamp"] = datetime.now().strftime("%H:%M:%S")
        if publish_fn:
            publish_fn(payload_end)

        if ok:
            return "ok"
        time.sleep(0.5)

    return "error"

# ----------------------------
# Threads
# ----------------------------
def loop_thread_fn(mqttc):
    last_mtime = None
    tv_state_on = False

    # asegurar mpv desde el inicio para evitar flashes
    _ensure_mpv_running()

    while True:
        loop_should_run.wait()
        set_state(loop_running=True, mode=MODE_LOOP)
        schedule_change_event.clear()

        st = get_state()
        playlist = st.get("loop_playlist")
        path_str = st.get("loop_playlist_file")

        if not path_str and playlist is None:
            path_str = str(choose_boot_playlist_file())
            set_state(loop_playlist_file=path_str)

        try:
            if playlist is None and path_str:
                path = Path(path_str).expanduser()
                if not path.is_absolute():
                    path = (PROJECT_DIR / path).resolve()
                playlist = load_playlist_from_file(path)
                try:
                    last_mtime = path.stat().st_mtime
                except Exception:
                    last_mtime = None
            else:
                playlist = normalize_playlist(playlist or {})
                path = None
        except Exception as e:
            set_state(last_error=str(e))
            publish(mqttc, TOPIC_STATUS, {"event": "error", "error": str(e)}, retain=True)
            time.sleep(2)
            continue

        if not playlist.get("items"):
            time.sleep(1)
            continue

        retries = int(playlist.get("retries", 0))
        black_between = int(playlist.get("black_between", st.get("loop_black_between", 0)))
        show_time = bool(playlist.get("show_time", st.get("show_time", False)))
        schedule_enabled = bool(playlist.get("schedule_enabled", st.get("schedule_enabled", False)))
        schedule_start = playlist.get("schedule_start", st.get("schedule_start"))
        schedule_end = playlist.get("schedule_end", st.get("schedule_end"))

        items = list(playlist["items"])
        if playlist.get("shuffle", st.get("loop_shuffle", False)):
            random.shuffle(items)

        if schedule_enabled:
            within = is_within_schedule(schedule_start, schedule_end)
            if within and not tv_state_on:
                ok, detail = tv_power_control("on")
                tv_state_on = bool(ok)
                publish(mqttc, TOPIC_STATUS, {"event": "schedule.tv_on", "ok": bool(ok), "detail": detail}, retain=False)
            elif not within and tv_state_on:
                ok, detail = tv_power_control("off")
                tv_state_on = False if ok else tv_state_on
                publish(mqttc, TOPIC_STATUS, {"event": "schedule.tv_off", "ok": bool(ok), "detail": detail}, retain=False)

            if not within:
                while not is_within_schedule(schedule_start, schedule_end) and loop_should_run.is_set():
                    time.sleep(30)
                continue

        for it in items:
            if not loop_should_run.is_set():
                break
            if schedule_change_event.is_set():
                break
            if schedule_enabled and not is_within_schedule(schedule_start, schedule_end):
                break

            stop_all_event.clear()
            set_state(current_item=it, paused=False)

            res = handle_item_play(
                it,
                retries,
                publish_fn=lambda p: publish(mqttc, TOPIC_NOWPLAY, p, retain=False),
                show_time=show_time,
            )

            set_state(current_item=None, paused=False)
            if res == "stopped":
                break

            if black_between > 0 and loop_should_run.is_set():
                # sin “home”: mpv sigue abierto, solo hacemos pausa antes del siguiente item
                t0 = time.time()
                while (time.time() - t0) < black_between:
                    if stop_all_event.is_set():
                        break
                    time.sleep(0.1)

        try:
            if path is not None and path.exists():
                mtime = path.stat().st_mtime
                if last_mtime and mtime != last_mtime:
                    publish(mqttc, TOPIC_STATUS, {"event": "playlist.reload"}, retain=False)
                    last_mtime = mtime
        except Exception:
            pass

def scheduler_thread_fn(mqttc):
    last_check_minute = None
    while True:
        time.sleep(10)
        now = datetime.now()
        current_minute = (now.hour, now.minute)
        if current_minute == last_check_minute:
            continue
        last_check_minute = current_minute

        st = get_state()
        scheduled_playlists = st.get("scheduled_playlists", [])
        if not scheduled_playlists:
            continue

        for sched in scheduled_playlists:
            start_time_str = sched.get("start_time")
            playlist_data = sched.get("playlist")
            playlist_name = sched.get("name", "unnamed")
            if not start_time_str or not playlist_data:
                continue
            start_t = parse_time_str(start_time_str)
            if not start_t:
                continue
            if start_t.hour == now.time().hour and start_t.minute == now.time().minute:
                stop_all_event.set()
                loop_should_run.clear()
                time.sleep(0.5)
                stop_all_event.clear()
                schedule_change_event.clear()

                playlist_data = normalize_playlist(playlist_data)
                set_state(loop_playlist=playlist_data, loop_playlist_file=None, active_scheduled_playlist=playlist_name)
                loop_should_run.set()
                publish(
                    mqttc,
                    TOPIC_STATUS,
                    {
                        "event": "scheduler.playlist_activated",
                        "playlist_name": playlist_name,
                        "start_time": start_time_str,
                        "activated_at": now.strftime("%H:%M:%S"),
                        "items_count": len(playlist_data.get("items", [])),
                    },
                    retain=False,
                )

def direct_thread_fn(mqttc):
    while True:
        payload = direct_queue.get()
        if payload is None:
            continue

        item = payload.get("item")
        return_to_loop = bool(payload.get("return_to_loop", False))
        retries = int(payload.get("retries", 0))
        show_time = bool(payload.get("show_time", get_state().get("show_time", False)))

        stop_all_event.clear()
        set_state(mode=MODE_DIRECT, current_item=item, paused=False)
        handle_item_play(item, retries, publish_fn=lambda p: publish(mqttc, TOPIC_NOWPLAY, p, retain=False), show_time=show_time)
        set_state(current_item=None, paused=False)

        if return_to_loop:
            set_state(mode=MODE_LOOP)
            loop_should_run.set()

        direct_queue.task_done()

def heartbeat_thread_fn(mqttc):
    while True:
        time.sleep(300)
        publish_status_snapshot(mqttc, event="heartbeat")

# ----------------------------
# Lockfile
# ----------------------------
def _install_lockfile():
    lockfile = Path(tempfile.gettempdir()) / f"pabs-tv-{_safe_name(CLIENT_ID)}.lock"
    if lockfile.exists():
        try:
            old_pid = int(lockfile.read_text().strip())
            os.kill(old_pid, 0)
            log.error("Ya hay una instancia ejecutándose (PID: %s). Lockfile: %s", old_pid, lockfile)
            sys.exit(1)
        except (ProcessLookupError, ValueError):
            try:
                lockfile.unlink()
            except Exception:
                pass

    try:
        lockfile.write_text(str(os.getpid()))
    except Exception:
        return None

    import atexit
    def _cleanup():
        try:
            if lockfile.exists():
                lockfile.unlink()
        except Exception:
            pass

    atexit.register(_cleanup)
    return lockfile

# ----------------------------
# MQTT callbacks
# ----------------------------
def _coerce_payload_to_dict(payload_text: str):
    payload_text = (payload_text or "").strip()
    if not payload_text:
        return {}
    try:
        obj = json.loads(payload_text)
        if isinstance(obj, dict):
            return obj
        return {"action": str(obj)}
    except Exception:
        return {"action": payload_text}

def main():
    if not MPV or not Path(MPV).exists():
        log.error("mpv no encontrado. Instala: sudo apt install -y mpv")
        sys.exit(1)

    _install_lockfile()

    # Arrancar mpv persistente desde el inicio (evita “home flash” entre items)
    _ensure_mpv_running()

    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        log.error("Falta paho-mqtt. Instala en el venv: pip install paho-mqtt")
        sys.exit(1)

    mqttc = mqtt.Client(client_id=f"pabs-tv-{CLIENT_ID}", clean_session=True, protocol=mqtt.MQTTv311)
    if MQTT_USER and MQTT_PASS:
        mqttc.username_pw_set(MQTT_USER, MQTT_PASS)

    mqttc.will_set(TOPIC_STATUS, json.dumps({"event": "offline", "client_id": CLIENT_ID}), qos=1, retain=True)

    def on_connect(client, userdata, flags, rc):
        log.info("[MQTT] connected rc=%s", rc)
        if rc == 0:
            mqtt_connected_evt.set()
            set_state(mqtt_connected=True)
            client.subscribe(TOPIC_CMD, qos=1)
            publish_status_snapshot(client, event="online")
            publish(client, TOPIC_STATUS, {"event": "ready", "client_id": CLIENT_ID, "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}, retain=True)
        else:
            mqtt_connected_evt.clear()
            set_state(mqtt_connected=False)
            log.warning("[MQTT] conexión NO exitosa rc=%s (seguimos reproduciendo offline)", rc)

    def on_disconnect(client, userdata, rc):
        log.warning("[MQTT] disconnected rc=%s", rc)
        mqtt_connected_evt.clear()
        set_state(mqtt_connected=False)
        publish_status_snapshot(client, event="disconnected")

    def on_message(client, userdata, msg):
        try:
            payload_text = msg.payload.decode("utf-8", errors="ignore")
        except Exception:
            payload_text = str(msg.payload)

        log.info("[MQTT][RECV] %s | %s", msg.topic, payload_text)
        data = _coerce_payload_to_dict(payload_text)

        action = (data.get("action") or "").strip()
        if not action:
            stv = data.get("state") or data.get("power")
            if isinstance(stv, str) and stv.lower() in ("on", "off"):
                action = "tv.power"
                data["state"] = stv.lower()
            else:
                return

        action_l = action.lower().strip()

        pause_actions = {"pause", "play.pause", "player.pause", "video.pause"}
        resume_actions = {"resume", "play.resume", "play.play", "player.play", "video.resume"}
        toggle_actions = {"toggle", "toggle_pause", "pause.toggle", "play.toggle_pause", "play.pause_toggle"}

        if action_l in pause_actions:
            ok = mpv_set_pause(True)
            publish(client, TOPIC_STATUS, {"event": "player.pause", "ok": bool(ok), "paused": True, "src": get_state().get("current_src", "ninguno")}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        if action_l in resume_actions:
            ok = mpv_set_pause(False)
            publish(client, TOPIC_STATUS, {"event": "player.resume", "ok": bool(ok), "paused": False, "src": get_state().get("current_src", "ninguno")}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        if action_l in toggle_actions:
            ok = mpv_toggle_pause()
            publish(client, TOPIC_STATUS, {"event": "player.toggle_pause", "ok": bool(ok), "paused": get_state().get("paused", False)}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        if action_l in {"play.next", "loop.next", "next"}:
            stop_all_event.set()
            time.sleep(0.1)
            stop_all_event.clear()
            publish(client, TOPIC_STATUS, {"event": "play.next", "ok": True}, retain=False)
            return

        if action_l in {"status", "status.request", "ping"}:
            publish_status_snapshot(client, event="status")
            return

        if action_l in {"loop.start", "loop.set", "playlist.set"}:
            stop_all_event.set()
            loop_should_run.clear()
            set_state(mode=MODE_LOOP, paused=False)

            playlist = data.get("playlist")
            playlist_file = data.get("playlist_file")

            if playlist:
                playlist = normalize_playlist(playlist)
                persist_remote_playlist(playlist)
                set_state(loop_playlist=None, loop_playlist_file=str(REMOTE_PLAYLIST_FILE))
            else:
                if playlist_file:
                    pf = Path(str(playlist_file)).expanduser()
                    if not pf.is_absolute():
                        pf = (PROJECT_DIR / pf).resolve()
                    set_state(loop_playlist=None, loop_playlist_file=str(pf))
                else:
                    st = get_state()
                    if not st.get("loop_playlist_file"):
                        set_state(loop_playlist=None, loop_playlist_file=str(choose_boot_playlist_file()))
                    else:
                        set_state(loop_playlist=None)

            schedule_change_event.set()
            stop_all_event.clear()
            loop_should_run.set()

            publish(client, TOPIC_STATUS, {"event": "loop.starting", "src": get_state().get("current_src", "ninguno")}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        if action_l == "loop.stop":
            loop_should_run.clear()
            stop_all_event.set()
            _mpv_stop_playback()
            set_state(loop_running=False, current_src="ninguno", paused=False)
            publish(client, TOPIC_STATUS, {"event": "loop.stopped", "src": "ninguno"}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        if action_l == "loop.reload":
            schedule_change_event.set()
            stop_all_event.set()
            time.sleep(0.1)
            stop_all_event.clear()
            publish(client, TOPIC_STATUS, {"event": "loop.reload.requested"}, retain=False)
            return

        if action_l == "loop.set_black_between":
            secs = int(data.get("seconds", 0))
            set_state(loop_black_between=secs)
            publish(client, TOPIC_STATUS, {"event": "loop.black_between.set", "seconds": secs}, retain=False)
            return

        if action_l == "loop.shuffle":
            enabled = bool(data.get("enabled", False))
            set_state(loop_shuffle=enabled)
            publish(client, TOPIC_STATUS, {"event": "loop.shuffle.set", "enabled": enabled}, retain=False)
            return

        if action_l == "loop.show_time":
            enabled = bool(data.get("enabled", False))
            set_state(show_time=enabled)
            publish(client, TOPIC_STATUS, {"event": "loop.show_time.set", "enabled": enabled}, retain=False)
            return

        if action_l == "loop.schedule":
            enabled = bool(data.get("enabled", False))
            start_time = data.get("start_time")
            end_time = data.get("end_time")
            set_state(schedule_enabled=enabled, schedule_start=start_time, schedule_end=end_time)
            publish(client, TOPIC_STATUS, {"event": "loop.schedule.set", "enabled": enabled, "start_time": start_time, "end_time": end_time}, retain=False)
            return

        if action_l == "scheduler.add":
            playlist_name = data.get("name")
            start_time = data.get("start_time")
            playlist_data = data.get("playlist")

            if not playlist_name or not start_time or not playlist_data:
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "missing name/start_time/playlist"}, retain=False)
                return

            if not parse_time_str(start_time):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "invalid start_time (HH:MM)"}, retain=False)
                return

            playlist_data = normalize_playlist(playlist_data)
            if not playlist_data.get("items"):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "playlist must include items"}, retain=False)
                return

            st = get_state()
            scheduled = st.get("scheduled_playlists", [])
            if any(s.get("name") == playlist_name and s.get("start_time") == start_time for s in scheduled):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.warning", "message": "already exists"}, retain=False)
                return

            scheduled.append({"name": playlist_name, "start_time": start_time, "playlist": playlist_data})
            set_state(scheduled_playlists=scheduled)
            publish(client, TOPIC_STATUS, {"event": "scheduler.add.success", "name": playlist_name, "start_time": start_time, "total": len(scheduled)}, retain=False)
            return

        if action_l == "scheduler.remove":
            playlist_name = data.get("name")
            if not playlist_name:
                publish(client, TOPIC_STATUS, {"event": "scheduler.remove.error", "error": "missing name"}, retain=False)
                return
            st = get_state()
            scheduled = st.get("scheduled_playlists", [])
            new_scheduled = [s for s in scheduled if s.get("name") != playlist_name]
            set_state(scheduled_playlists=new_scheduled)
            publish(client, TOPIC_STATUS, {"event": "scheduler.remove.success", "name": playlist_name, "total": len(new_scheduled)}, retain=False)
            return

        if action_l == "scheduler.list":
            st = get_state()
            publish(client, TOPIC_STATUS, {"event": "scheduler.list", "scheduled_playlists": st.get("scheduled_playlists", []), "total": len(st.get("scheduled_playlists", [])), "active": st.get("active_scheduled_playlist")}, retain=False)
            return

        if action_l == "tv.power":
            state_tv = (data.get("state") or "").lower()
            ok, detail = tv_power_control(state_tv)
            publish(client, TOPIC_STATUS, {"event": "tv.power", "state": state_tv, "ok": bool(ok), "detail": detail}, retain=False)
            return

        if action_l == "play.once":
            item = data.get("item")
            if not item or not isinstance(item, dict):
                publish(client, TOPIC_STATUS, {"event": "error", "error": "missing item"}, retain=False)
                return
            if "kind" not in item and "type" in item:
                item["kind"] = item.pop("type")

            stop_all_event.set()
            loop_should_run.clear()
            set_state(mode=MODE_DIRECT, paused=False)

            direct_queue.put(
                {
                    "item": item,
                    "return_to_loop": bool(data.get("return_to_loop", False)),
                    "retries": int(data.get("retries", 0)),
                    "show_time": bool(data.get("show_time", get_state().get("show_time", False))),
                }
            )
            publish(client, TOPIC_STATUS, {"event": "direct.enqueued"}, retain=False)
            return

        if action_l == "play.stop":
            stop_all_event.set()
            _mpv_stop_playback()
            set_state(current_item=None, current_src="ninguno", paused=False)
            publish(client, TOPIC_STATUS, {"event": "play.stopped", "src": "ninguno"}, retain=False)
            publish_status_snapshot(client, event="status")
            return

        publish(client, TOPIC_STATUS, {"event": "error", "error": f"unknown action: {action}"}, retain=False)

    mqttc.on_connect = on_connect
    mqttc.on_disconnect = on_disconnect
    mqttc.on_message = on_message

    mqttc.reconnect_delay_set(min_delay=1, max_delay=30)

    threading.Thread(target=lambda: loop_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: direct_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: scheduler_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: heartbeat_thread_fn(mqttc), daemon=True).start()

    boot_file = choose_boot_playlist_file()
    set_state(loop_playlist=None, loop_playlist_file=str(boot_file))
    loop_should_run.set()

    log.info("Iniciando MQTT (connect_async) hacia %s:%s ...", MQTT_HOST, MQTT_PORT)
    try:
        mqttc.connect_async(MQTT_HOST, MQTT_PORT, keepalive=60)
        mqttc.loop_start()
    except Exception as e:
        log.error("No se pudo iniciar MQTT async: %s (seguimos offline reproduciendo)", e)

    def _shutdown(_sig=None, _frame=None):
        log.warning("Cerrando PABS-TV...")
        try:
            stop_all_event.set()
            loop_should_run.clear()
        except Exception:
            pass
        try:
            mpv_quit()
        except Exception:
            pass
        try:
            mqttc.disconnect()
        except Exception:
            pass
        try:
            mqttc.loop_stop()
        except Exception:
            pass
        time.sleep(0.2)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()