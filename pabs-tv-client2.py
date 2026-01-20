#!/usr/bin/env python3
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

def _safe_json_dumps(obj):
    return json.dumps(obj, ensure_ascii=False)

def _atomic_write_json(path: Path, data: dict):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
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

TOPIC_CMD = f"{TOPIC_BASE}/{CLIENT_ID}/cmd"
TOPIC_STATUS = f"{TOPIC_BASE}/{CLIENT_ID}/status"
TOPIC_NOWPLAY = f"{TOPIC_BASE}/{CLIENT_ID}/now_playing"

PROJECT_DIR = Path(_env_get(["PABS_PROJECT_DIR"], str(Path(__file__).resolve().parent))).expanduser().resolve()
MEDIA_DIR = Path(_env_get(["PABS_MEDIA_DIR", "MEDIA_DIR"], str(PROJECT_DIR / "media"))).expanduser()
PLAYLIST_FILE = Path(_env_get(["PABS_PLAYLIST_FILE"], str(PROJECT_DIR / "playlist.json"))).expanduser()
CACHE_DIR = Path(_env_get(["PABS_CACHE_DIR"], str(PROJECT_DIR / "cache"))).expanduser()

MEDIA_VIDEO_DIR = MEDIA_DIR / "videos"
MEDIA_IMAGE_DIR = MEDIA_DIR / "images"

LAST_PLAYLIST_FILE = CACHE_DIR / "last_playlist.json"  # backup persistente (último playlist recibido por MQTT)

for p in (MEDIA_VIDEO_DIR, MEDIA_IMAGE_DIR, CACHE_DIR):
    try:
        p.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

log.info("===== CONFIG =====")
log.info("CLIENT_ID: %s", CLIENT_ID)
log.info("MQTT: %s:%s", MQTT_HOST, MQTT_PORT)
log.info("TOPIC_CMD: %s", TOPIC_CMD)
log.info("PROJECT_DIR: %s", PROJECT_DIR)
log.info("MEDIA_DIR: %s", MEDIA_DIR)
log.info("PLAYLIST_FILE: %s", PLAYLIST_FILE)
log.info("LAST_PLAYLIST_FILE: %s", LAST_PLAYLIST_FILE)
log.info("CACHE_DIR: %s", CACHE_DIR)
log.info("DISPLAY: %s", os.environ.get("DISPLAY"))
log.info("WAYLAND_DISPLAY: %s", os.environ.get("WAYLAND_DISPLAY"))
log.info("==================")

# ----------------------------
# MPV + IPC (PAUSE/RESUME)
# ----------------------------
MPV = shutil.which("mpv") or "/usr/bin/mpv"
MPV_LOG = _env_get(["PABS_MPV_LOGFILE"], "/tmp/mpv.log")
MPV_YTDL_FORMAT = _env_get(["PABS_MPV_YTDL_FORMAT"], "bestvideo[height<=720]+bestaudio/best/best")
MPV_HWDEC = _env_get(["PABS_MPV_HWDEC"], "no")

MPV_VO = _env_get(["PABS_MPV_VO"], "").strip()
MPV_GPU_CONTEXT = _env_get(["PABS_MPV_GPU_CONTEXT"], "").strip()
MPV_EXTRA_OPTS_RAW = _env_get(["PABS_MPV_EXTRA_OPTS"], "").strip()

MPV_IPC = f"/tmp/pabs-tv-mpv-{CLIENT_ID}.sock"
mpv_ipc_lock = threading.Lock()

MPV_BASE_OPTS = [
    MPV,
    "--fs",
    "--no-osc",
    "--no-osd-bar",
    "--keep-open=no",
    f"--log-file={MPV_LOG}",
    f"--ytdl-format={MPV_YTDL_FORMAT}",
    f"--hwdec={MPV_HWDEC}",
    f"--input-ipc-server={MPV_IPC}",  # <- CLAVE para pause/resume via MQTT
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
    "loop_playlist_file": str(PLAYLIST_FILE),
    "loop_black_between": 0,
    "loop_shuffle": False,
    "retries": 0,
    "current_item": None,
    "current_src": "ninguno",
    "last_error": None,
    "show_time": False,
    "schedule_enabled": False,
    "schedule_start": None,
    "schedule_end": None,
    "scheduled_playlists": [],
    "active_scheduled_playlist": None,
    "paused": False,  # <- estado lógico (mpv)
}

stop_all_event = threading.Event()
loop_should_run = threading.Event()
direct_queue = queue.Queue()
mpv_proc = None
mpv_proc_lock = threading.Lock()
schedule_change_event = threading.Event()

mqtt_connected = threading.Event()

# ----------------------------
# MQTT publish
# ----------------------------
def publish(client, topic, payload):
    try:
        payload_json = _safe_json_dumps(payload)
    except Exception as e:
        log.error("[MQTT][SEND] json error (%s): %s", topic, e)
        return
    try:
        log.info("[MQTT][SEND] %s | %s", topic, payload_json)
        return client.publish(topic, payload_json, qos=1, retain=False)
    except Exception as e:
        log.error("[MQTT][SEND] publish error (%s): %s", topic, e)

def set_state(**kwargs):
    with state_lock:
        state.update(kwargs)

def get_state():
    with state_lock:
        return dict(state)

# ----------------------------
# MPV IPC helpers
# ----------------------------
def _mpv_ipc_send(command_obj, timeout=0.8):
    """
    command_obj ejemplo:
      {"command": ["set_property", "pause", True]}
    """
    path = MPV_IPC
    if not os.path.exists(path):
        return False, {"error": "ipc_socket_missing", "path": path}

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(path)
        s.sendall((json.dumps(command_obj) + "\n").encode("utf-8"))

        # leer una respuesta (1 línea)
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()

        if not data:
            return True, {"ok": True}
        try:
            return True, json.loads(data.decode("utf-8", errors="ignore"))
        except Exception:
            return True, {"raw": data.decode("utf-8", errors="ignore")}
    except Exception as e:
        return False, {"error": str(e)}

def _mpv_is_running():
    with mpv_proc_lock:
        if mpv_proc is None:
            return False
        return mpv_proc.poll() is None

def mpv_set_pause(paused: bool):
    with mpv_ipc_lock:
        if not _mpv_is_running():
            return False, {"error": "mpv_not_running"}
        ok, resp = _mpv_ipc_send({"command": ["set_property", "pause", bool(paused)]})
        if ok:
            set_state(paused=bool(paused))
        return ok, resp

def mpv_toggle_pause():
    with mpv_ipc_lock:
        if not _mpv_is_running():
            return False, {"error": "mpv_not_running"}
        ok, resp = _mpv_ipc_send({"command": ["cycle", "pause"]})
        if ok:
            # Intento leer estado de pause (best-effort)
            ok2, resp2 = _mpv_ipc_send({"command": ["get_property", "pause"]})
            if ok2 and isinstance(resp2, dict) and "data" in resp2:
                set_state(paused=bool(resp2["data"]))
        return ok, resp

# ----------------------------
# Playback helpers
# ----------------------------
def run_cmd(cmd):
    global mpv_proc

    # Limpia socket IPC viejo (si quedó)
    try:
        if os.path.exists(MPV_IPC):
            os.remove(MPV_IPC)
    except Exception:
        pass

    try:
        log.info("[MPV] %s", " ".join(cmd))
        with mpv_proc_lock:
            mpv_proc = subprocess.Popen(cmd)

        while True:
            if stop_all_event.is_set():
                with mpv_proc_lock:
                    p = mpv_proc
                try:
                    if p and p.poll() is None:
                        p.terminate()
                        try:
                            p.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            p.kill()
                except Exception:
                    pass
                return False

            with mpv_proc_lock:
                p = mpv_proc
            if p is None:
                return False
            ret = p.poll()
            if ret is not None:
                return ret == 0
            time.sleep(0.1)
    finally:
        with mpv_proc_lock:
            mpv_proc = None
        try:
            if os.path.exists(MPV_IPC):
                os.remove(MPV_IPC)
        except Exception:
            pass
        set_state(paused=False)

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

def play_image(src, duration):
    cmd = MPV_BASE_OPTS + [f"--image-display-duration={int(duration or 8)}", "--loop-file=no", src]
    return run_cmd(cmd)

def play_video(src, duration=None, start_at=None):
    cmd = MPV_BASE_OPTS.copy()
    if start_at:
        cmd += [f"--start={start_at}"]
    cmd += [src]
    return run_cmd(cmd)

def play_youtube(url, duration=None, start_at=None):
    cmd = MPV_BASE_OPTS.copy() + YTDL_OPTS
    if start_at:
        cmd += [f"--start={start_at}"]
    cmd += [url]
    ok = run_cmd(cmd)
    if ok:
        return True

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
                cmd2 = MPV_BASE_OPTS.copy()
                if start_at:
                    cmd2 += [f"--start={start_at}"]
                cmd2 += [du]
                if run_cmd(cmd2):
                    return True
        except Exception:
            continue

    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        out_pattern = str(CACHE_DIR / "%(id)s.%(ext)s")
        dl_cmd = [ytdlp, "-f", "bv*+ba/b", "-o", out_pattern, url]
        ok = subprocess.call(dl_cmd) == 0
        if ok:
            try:
                vid = subprocess.check_output([ytdlp, "--get-id", url], text=True).strip()
            except Exception:
                vid = None
            if vid:
                for ext in ("mp4", "mkv", "webm"):
                    cand = CACHE_DIR / f"{vid}.{ext}"
                    if cand.exists():
                        return play_video(str(cand), duration=duration, start_at=start_at)
            files = list(CACHE_DIR.glob("*.*"))
            if files:
                files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
                return play_video(str(files[0]), duration=duration, start_at=start_at)
    except Exception as e:
        log.error("[YOUTUBE] fallback descarga error: %s", e)

    return False

# ----------------------------
# TV power
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
# Playlist helpers
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

def load_playlist_from_file(path):
    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    return normalize_playlist(raw)

def persist_playlist_from_mqtt(playlist: dict):
    """
    Guarda la playlist enviada por MQTT para que:
    - Offline: se siga reproduciendo lo último
    - Reboot: quede persistente
    """
    playlist = normalize_playlist(playlist or {})
    if not playlist.get("items"):
        return False, "playlist_without_items"

    try:
        # backup en cache
        _atomic_write_json(LAST_PLAYLIST_FILE, playlist)
        # sobrescribir playlist.json principal (lo que tú pediste)
        _atomic_write_json(PLAYLIST_FILE, playlist)
        return True, "saved"
    except Exception as e:
        return False, str(e)

# ----------------------------
# Playback logic
# ----------------------------
def handle_item_play(item, retries, publish_fn=None, show_time=False):
    it = maybe_prefetch(item, publish_fn=publish_fn)
    kind = it.get("kind")
    src = it.get("src")
    dur = it.get("duration")
    start = it.get("start_at")

    full_path = build_media_path(src, kind)
    set_state(current_src=full_path or "ninguno")

    for _attempt in range(int(retries or 0) + 1):
        if stop_all_event.is_set():
            return "stopped"

        payload_start = {"event": "start", "item": it}
        if show_time:
            payload_start["timestamp"] = datetime.now().strftime("%H:%M:%S")
        if publish_fn:
            publish_fn(payload_start)

        ok = True
        if kind == "image":
            ok = play_image(full_path, dur or 8)
        elif kind == "video":
            ok = play_video(full_path, duration=dur, start_at=start)
        elif kind == "youtube":
            ok = play_youtube(full_path, duration=dur, start_at=start)

        payload_end = {"event": "end", "item": it, "ok": bool(ok)}
        if show_time:
            payload_end["timestamp"] = datetime.now().strftime("%H:%M:%S")
        if publish_fn:
            publish_fn(payload_end)

        if ok:
            return "ok"
        time.sleep(0.5)

    return "error"

def loop_thread_fn(mqttc):
    last_mtime = None
    tv_state_on = False

    while True:
        loop_should_run.wait()
        set_state(loop_running=True, mode=MODE_LOOP)
        schedule_change_event.clear()

        st = get_state()
        playlist = st.get("loop_playlist")
        path = st.get("loop_playlist_file")

        # Si no hay playlist en memoria, intenta archivo; si no existe, usa LAST_PLAYLIST_FILE
        if (not path) or (path and not Path(path).exists()):
            if LAST_PLAYLIST_FILE.exists():
                path = str(LAST_PLAYLIST_FILE)
                set_state(loop_playlist_file=path)

        try:
            if playlist is None and path and Path(path).exists():
                playlist = load_playlist_from_file(path)
                try:
                    last_mtime = Path(path).stat().st_mtime
                except Exception:
                    last_mtime = None
            else:
                playlist = normalize_playlist(playlist or {})
        except Exception as e:
            set_state(last_error=str(e))
            publish(mqttc, TOPIC_STATUS, {"event": "error", "error": str(e)})
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
                publish(mqttc, TOPIC_STATUS, {"event": "schedule.tv_on", "ok": bool(ok), "detail": detail})
            elif not within and tv_state_on:
                ok, detail = tv_power_control("off")
                tv_state_on = False if ok else tv_state_on
                publish(mqttc, TOPIC_STATUS, {"event": "schedule.tv_off", "ok": bool(ok), "detail": detail})

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
            set_state(current_item=it)

            res = handle_item_play(
                it,
                retries,
                publish_fn=lambda p: publish(mqttc, TOPIC_NOWPLAY, p),
                show_time=show_time,
            )

            set_state(current_item=None)
            if res == "stopped":
                break
            if black_between > 0 and loop_should_run.is_set():
                time.sleep(black_between)

        # Autoreload si cambió el archivo
        try:
            if path and Path(path).exists():
                mtime = Path(path).stat().st_mtime
                if last_mtime and mtime != last_mtime:
                    publish(mqttc, TOPIC_STATUS, {"event": "playlist.reload"})
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
        set_state(mode=MODE_DIRECT, current_item=item)
        handle_item_play(item, retries, publish_fn=lambda p: publish(mqttc, TOPIC_NOWPLAY, p), show_time=show_time)
        set_state(current_item=None)

        if return_to_loop:
            set_state(mode=MODE_LOOP)
            loop_should_run.set()

        direct_queue.task_done()

def heartbeat_thread_fn(mqttc):
    while True:
        time.sleep(300)
        st = get_state()
        publish(
            mqttc,
            TOPIC_STATUS,
            {
                "event": "heartbeat",
                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "mode": st.get("mode", MODE_LOOP),
                "client_id": CLIENT_ID,
                "src": st.get("current_src", "ninguno"),
                "paused": bool(st.get("paused", False)),
                "mqtt_connected": bool(mqtt_connected.is_set()),
            },
        )

def _install_lockfile():
    lockfile = Path(tempfile.gettempdir()) / f"pabs-tv-{CLIENT_ID}.lock"
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

def _handle_signal(signum, frame):
    log.warning("Signal %s recibido, deteniendo...", signum)
    loop_should_run.clear()
    stop_all_event.set()
    with mpv_proc_lock:
        p = mpv_proc
    try:
        if p and p.poll() is None:
            p.terminate()
    except Exception:
        pass
    time.sleep(0.2)
    raise SystemExit(0)

# ----------------------------
# Main
# ----------------------------
def main():
    if not MPV or not Path(MPV).exists():
        log.error("mpv no encontrado. Instala: sudo apt install -y mpv")
        sys.exit(1)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    _install_lockfile()

    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        log.error("Falta paho-mqtt. Instala en el venv: pip install -r requirements.txt")
        sys.exit(1)

    mqttc = mqtt.Client(client_id=f"pabs-tv-{CLIENT_ID}", clean_session=True)
    if MQTT_USER and MQTT_PASS:
        mqttc.username_pw_set(MQTT_USER, MQTT_PASS)

    conn_count = {"count": 0}

    def on_connect(client, userdata, flags, rc, properties=None):
        conn_count["count"] += 1
        mqtt_connected.set()
        log.info("[MQTT] connected rc=%s (conn #%d)", rc, conn_count["count"])
        client.subscribe(TOPIC_CMD, qos=1)

        st = get_state()
        ev = "online" if conn_count["count"] == 1 else "reconnected"
        publish(
            client,
            TOPIC_STATUS,
            {
                "event": ev,
                "mode": st.get("mode", MODE_LOOP),
                "client_id": CLIENT_ID,
                "src": st.get("current_src", "ninguno"),
                "paused": bool(st.get("paused", False)),
            },
        )

    def on_disconnect(client, userdata, rc):
        mqtt_connected.clear()
        if rc != 0:
            log.warning("[MQTT] desconexión inesperada rc=%s", rc)
        else:
            log.info("[MQTT] desconexión limpia")

    def on_message(client, userdata, msg):
        try:
            payload_text = msg.payload.decode("utf-8", errors="ignore")
            data = json.loads(payload_text or "{}")
        except Exception as e:
            publish(client, TOPIC_STATUS, {"event": "error", "error": f"bad_json: {e}"})
            return

        action = data.get("action")
        if not action:
            stv = data.get("state") or data.get("power")
            if isinstance(stv, str) and stv.lower() in ("on", "off"):
                action = "tv.power"
                data["state"] = stv.lower()
            else:
                return

        # --------- LOOP ---------
        if action == "loop.start":
            stop_all_event.set()
            set_state(mode=MODE_LOOP)

            playlist = data.get("playlist")
            playlist_file = data.get("playlist_file") or get_state().get("loop_playlist_file") or str(PLAYLIST_FILE)

            if playlist:
                playlist = normalize_playlist(playlist)
                # Persistir para offline (esto es lo que pediste)
                ok, detail = persist_playlist_from_mqtt(playlist)
                publish(client, TOPIC_STATUS, {"event": "playlist.saved", "ok": bool(ok), "detail": detail})
                # Forzar a que el loop lea del archivo persistido (playlist.json)
                set_state(loop_playlist=None, loop_playlist_file=str(PLAYLIST_FILE))
            else:
                set_state(loop_playlist=None, loop_playlist_file=playlist_file)

            stop_all_event.clear()
            loop_should_run.set()
            publish(client, TOPIC_STATUS, {"event": "loop.starting", "src": get_state().get("current_src", "ninguno")})

        elif action == "loop.stop":
            loop_should_run.clear()
            stop_all_event.set()
            set_state(loop_running=False, current_src="ninguno")
            publish(client, TOPIC_STATUS, {"event": "loop.stopped", "src": "ninguno"})

        elif action == "loop.reload":
            st = get_state()
            if st.get("loop_playlist_file"):
                set_state(loop_playlist=None)
                publish(client, TOPIC_STATUS, {"event": "loop.reload.requested"})

        elif action == "loop.set_black_between":
            secs = int(data.get("seconds", 0))
            set_state(loop_black_between=secs)
            publish(client, TOPIC_STATUS, {"event": "loop.black_between.set", "seconds": secs})

        elif action == "loop.shuffle":
            enabled = bool(data.get("enabled", False))
            set_state(loop_shuffle=enabled)
            publish(client, TOPIC_STATUS, {"event": "loop.shuffle.set", "enabled": enabled})

        elif action == "loop.show_time":
            enabled = bool(data.get("enabled", False))
            set_state(show_time=enabled)
            publish(client, TOPIC_STATUS, {"event": "loop.show_time.set", "enabled": enabled})

        elif action == "loop.schedule":
            enabled = bool(data.get("enabled", False))
            start_time = data.get("start_time")
            end_time = data.get("end_time")
            set_state(schedule_enabled=enabled, schedule_start=start_time, schedule_end=end_time)
            publish(client, TOPIC_STATUS, {"event": "loop.schedule.set", "enabled": enabled, "start_time": start_time, "end_time": end_time})

        # --------- Scheduler ---------
        elif action == "scheduler.add":
            playlist_name = data.get("name")
            start_time = data.get("start_time")
            playlist_data = data.get("playlist")

            if not playlist_name or not start_time or not playlist_data:
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "missing name/start_time/playlist"})
                return

            if not parse_time_str(start_time):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "invalid start_time (HH:MM)"})
                return

            playlist_data = normalize_playlist(playlist_data)
            if not playlist_data.get("items"):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.error", "error": "playlist must include items"})
                return

            st = get_state()
            scheduled = st.get("scheduled_playlists", [])
            if any(s.get("name") == playlist_name and s.get("start_time") == start_time for s in scheduled):
                publish(client, TOPIC_STATUS, {"event": "scheduler.add.warning", "message": "already exists"})
                return

            scheduled.append({"name": playlist_name, "start_time": start_time, "playlist": playlist_data})
            set_state(scheduled_playlists=scheduled)
            publish(client, TOPIC_STATUS, {"event": "scheduler.add.success", "name": playlist_name, "start_time": start_time, "total": len(scheduled)})

        elif action == "scheduler.remove":
            playlist_name = data.get("name")
            if not playlist_name:
                publish(client, TOPIC_STATUS, {"event": "scheduler.remove.error", "error": "missing name"})
                return
            st = get_state()
            scheduled = st.get("scheduled_playlists", [])
            new_scheduled = [s for s in scheduled if s.get("name") != playlist_name]
            set_state(scheduled_playlists=new_scheduled)
            publish(client, TOPIC_STATUS, {"event": "scheduler.remove.success", "name": playlist_name, "total": len(new_scheduled)})

        elif action == "scheduler.list":
            st = get_state()
            publish(
                client,
                TOPIC_STATUS,
                {
                    "event": "scheduler.list",
                    "scheduled_playlists": st.get("scheduled_playlists", []),
                    "total": len(st.get("scheduled_playlists", [])),
                    "active": st.get("active_scheduled_playlist"),
                },
            )

        # --------- TV ---------
        elif action == "tv.power":
            state_tv = (data.get("state") or "").lower()
            ok, detail = tv_power_control(state_tv)
            publish(client, TOPIC_STATUS, {"event": "tv.power", "state": state_tv, "ok": bool(ok), "detail": detail})

        # --------- DIRECT ---------
        elif action == "play.once":
            item = data.get("item")
            if not item or not isinstance(item, dict):
                publish(client, TOPIC_STATUS, {"event": "error", "error": "missing item"})
                return
            if "kind" not in item and "type" in item:
                item["kind"] = item.pop("type")

            stop_all_event.set()
            loop_should_run.clear()
            set_state(mode=MODE_DIRECT)

            direct_queue.put(
                {
                    "item": item,
                    "return_to_loop": bool(data.get("return_to_loop", False)),
                    "retries": int(data.get("retries", 0)),
                    "show_time": bool(data.get("show_time", get_state().get("show_time", False))),
                }
            )
            publish(client, TOPIC_STATUS, {"event": "direct.enqueued"})

        elif action == "play.stop":
            stop_all_event.set()
            set_state(current_item=None, current_src="ninguno", paused=False)
            publish(client, TOPIC_STATUS, {"event": "play.stopped", "src": "ninguno"})

        # --------- NUEVO: PAUSE / RESUME / TOGGLE ---------
        elif action in ("play.pause", "pause"):
            ok, resp = mpv_set_pause(True)
            publish(client, TOPIC_STATUS, {"event": "play.pause", "ok": bool(ok), "resp": resp})

        elif action in ("play.resume", "resume", "play.play"):
            ok, resp = mpv_set_pause(False)
            publish(client, TOPIC_STATUS, {"event": "play.resume", "ok": bool(ok), "resp": resp})

        elif action in ("play.toggle", "play.toggle_pause", "toggle_pause"):
            ok, resp = mpv_toggle_pause()
            publish(client, TOPIC_STATUS, {"event": "play.toggle", "ok": bool(ok), "resp": resp, "paused": bool(get_state().get("paused", False))})

        else:
            publish(client, TOPIC_STATUS, {"event": "error", "error": f"unknown action: {action}"})

    mqttc.on_connect = on_connect
    mqttc.on_disconnect = on_disconnect
    mqttc.on_message = on_message
    mqttc.will_set(TOPIC_STATUS, json.dumps({"event": "offline"}), qos=1, retain=False)
    mqttc.reconnect_delay_set(min_delay=1, max_delay=30)

    max_retries = int(_env_get(["PABS_MQTT_CONNECT_RETRIES"], "5"))
    retry_delay = float(_env_get(["PABS_MQTT_RETRY_DELAY"], "5"))

    for attempt in range(1, max_retries + 1):
        try:
            log.info("Conectando MQTT %s:%s (intento %d/%d)", MQTT_HOST, MQTT_PORT, attempt, max_retries)
            mqttc.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
            break
        except Exception as e:
            log.error("MQTT connect error: %s", e)
            if attempt == max_retries:
                # Offline: igual arranca loop con lo último guardado si existe
                log.error("MQTT no disponible. Iniciando reproducción offline con playlist local/último guardado.")
                break
            time.sleep(retry_delay)

    # Threads
    threading.Thread(target=lambda: loop_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: direct_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: scheduler_thread_fn(mqttc), daemon=True).start()
    threading.Thread(target=lambda: heartbeat_thread_fn(mqttc), daemon=True).start()

    # Autostart loop (offline/online): usa playlist.json si existe; si no, last_playlist.json
    if PLAYLIST_FILE.exists():
        set_state(loop_playlist=None, loop_playlist_file=str(PLAYLIST_FILE))
        loop_should_run.set()
    elif LAST_PLAYLIST_FILE.exists():
        set_state(loop_playlist=None, loop_playlist_file=str(LAST_PLAYLIST_FILE))
        loop_should_run.set()
    else:
        log.warning("No existe playlist.json ni last_playlist.json. Crea uno y reinicia o manda loop.start por MQTT.")

    mqttc.loop_forever()

if __name__ == "__main__":
    main()
