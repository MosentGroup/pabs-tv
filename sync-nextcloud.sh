#!/usr/bin/env bash
set -euo pipefail

REMOTE_NAME="${REMOTE_NAME:-nextcloud}"
REMOTE_PATH="${REMOTE_PATH:-pabs-tv/media}"     # Remote real: nextcloud:pabs-tv/media
PROJECT_DIR="${PROJECT_DIR:-/home/pabstvroot/pabs-tv}"
LOCAL_MEDIA_DIR="${LOCAL_MEDIA_DIR:-${PROJECT_DIR}/media}"

LOG_FILE="${LOG_FILE:-${PROJECT_DIR}/cron-sync.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/pabs-tv-nextcloud-sync.lock}"

RCLONE_BIN="$(command -v rclone || true)"
DATE_BIN="$(command -v date || true)"

if [[ -z "${RCLONE_BIN}" ]]; then
  echo "[ERROR] rclone no está instalado o no está en PATH" >&2
  exit 1
fi

mkdir -p "${LOCAL_MEDIA_DIR}" "$(dirname "${LOG_FILE}")"

log() {
  echo "[${DATE_BIN:+$(${DATE_BIN} '+%Y-%m-%d %H:%M:%S')}] $*" | tee -a "${LOG_FILE}"
}

# Evitar ejecuciones simultáneas
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "[WARN] Ya hay una sincronización corriendo. Saliendo."
  exit 0
fi

REMOTE_FULL="${REMOTE_NAME}:${REMOTE_PATH}"

log "==== Sync START ===="
log "Remote: ${REMOTE_FULL}"
log "Local : ${LOCAL_MEDIA_DIR}"

# Asegurar estructura esperada
mkdir -p "${LOCAL_MEDIA_DIR}/videos" "${LOCAL_MEDIA_DIR}/images"

# Sincroniza TODO el arbol media/ (incluye videos/ e images/)
"${RCLONE_BIN}" sync "${REMOTE_FULL}" "${LOCAL_MEDIA_DIR}" \
  --create-empty-src-dirs \
  --transfers 4 \
  --checkers 8 \
  --timeout 30s \
  --contimeout 15s \
  --retries 3 \
  --low-level-retries 10 \
  --stats 30s \
  --log-level INFO \
  --log-file "${LOG_FILE}"

log "==== Sync END ===="
log "Local totals:"
find "${LOCAL_MEDIA_DIR}" -type f | wc -l | xargs -I{} log "  files: {}"
log ""
