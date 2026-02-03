#!/usr/bin/env bash
set -euo pipefail

OUT="/home/pabstvroot/pabs-tv/remote/teamviewer-credentials.txt"
TS="$(date +%Y%m%d-%H%M%S)"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# Quitar códigos ANSI (colores) de cualquier salida
strip_ansi() {
  # elimina secuencias ESC[...m y similares
  sed -r 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

# Ejecutar teamviewer "limpio"
tv_info() {
  TERM=dumb LC_ALL=C teamviewer info 2>/dev/null | strip_ansi
}

echo "[TV] Arquitectura detectada: ${ARCH}"

# Backup si existe
if [ -f "${OUT}" ]; then
  cp -a "${OUT}" "${OUT}.bak-${TS}"
  echo "[TV] Backup: ${OUT}.bak-${TS}"
fi

echo "[TV] Reiniciando servicio/daemon..."
sudo systemctl restart teamviewerd 2>/dev/null || true
sudo teamviewer daemon restart 2>/dev/null || true

echo "[TV] Esperando a que teamviewerd esté activo..."
for i in {1..30}; do
  if sudo systemctl is-active --quiet teamviewerd 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "[TV] Obteniendo TeamViewer ID (reintentos)..."
TV_ID=""
for i in {1..40}; do
  INFO="$(tv_info || true)"

  # Método 1: parseo por etiqueta
  TV_ID="$(echo "${INFO}" | awk -F: '/TeamViewer ID/ {gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]]+/, "", $2); print $2}' | head -n1 || true)"

  # Método 2: número largo fallback (por si cambia el texto)
  if [[ -z "${TV_ID}" ]]; then
    TV_ID="$(echo "${INFO}" | grep -Eo '[0-9]{6,}' | head -n1 || true)"
  fi

  # Validar que NO tenga cosas raras
  if [[ "${TV_ID}" =~ ^[0-9]{6,}$ ]]; then
    break
  fi

  TV_ID=""
  sleep 2
done

echo "[TV] Obteniendo o generando Password..."
TV_PASS=""
INFO="$(tv_info || true)"
TV_PASS="$(echo "${INFO}" | awk -F: '/Password/ {sub(/^[[:space:]]+/, "", $2); print $2}' | head -n1 || true)"

if [[ -z "${TV_PASS}" || "${TV_PASS}" == "********" ]]; then
  TV_PASS="$(head -c 64 /dev/urandom | base64 | tr -d '=+/[:space:]' | head -c 12)"
  teamviewer passwd "${TV_PASS}" >/dev/null 2>&1 || true
fi

TMP="${OUT}.tmp.$$"
{
  echo "TeamViewer Host instalado"
  echo "Fecha: $(date)"
  echo "Arquitectura: ${ARCH}"
  echo
  echo "TeamViewer ID: ${TV_ID}"
  echo "Password: ${TV_PASS}"
  echo
  echo "Comandos útiles:"
  echo "  teamviewer info"
  echo "  sudo systemctl status teamviewerd --no-pager"
  echo "  sudo journalctl -u teamviewerd -n 120 --no-pager"
} > "${TMP}"

mv "${TMP}" "${OUT}"
chmod 600 "${OUT}"

echo "[TV] Listo. Archivo generado: ${OUT}"
echo ""
cat "${OUT}"

if [[ -z "${TV_ID}" ]]; then
  echo ""
  echo "[TV] AVISO: El TeamViewer ID sigue vacío."
  echo "      Corre:"
  echo "      teamviewer info"
  echo "      sudo journalctl -u teamviewerd -n 120 --no-pager"
fi
