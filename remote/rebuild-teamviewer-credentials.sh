#!/usr/bin/env bash
set -euo pipefail

OUT="$(pwd)/teamviewer-credentials.txt"
TS="$(date +%Y%m%d-%H%M%S)"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

echo "[TV] Arquitectura: ${ARCH}"

# Backup si existe
if [ -f "${OUT}" ]; then
  cp -a "${OUT}" "${OUT}.bak-${TS}"
  echo "[TV] Backup: ${OUT}.bak-${TS}"
fi

echo "[TV] Reiniciando daemon..."
sudo systemctl restart teamviewerd 2>/dev/null || true
sudo teamviewer daemon restart 2>/dev/null || true

echo "[TV] Esperando servicio..."
for i in {1..30}; do
  if sudo systemctl is-active --quiet teamviewerd 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "[TV] Obteniendo TeamViewer ID (reintentos)..."
TV_ID=""
for i in {1..40}; do
  TV_ID="$(teamviewer info 2>/dev/null | awk -F: '/TeamViewer ID/ {gsub(/ /,"",$2); print $2}' | head -n1 || true)"
  if [ -z "${TV_ID}" ]; then
    TV_ID="$(teamviewer info 2>/dev/null | grep -Eo '[0-9]{6,}' | head -n1 || true)"
  fi
  [ -n "${TV_ID}" ] && break
  sleep 2
done

echo "[TV] Generando/asegurando password..."
TV_PASS=""
TV_PASS="$(teamviewer info 2>/dev/null | awk -F: '/Password/ {sub(/^ /,"",$2); print $2}' | head -n1 || true)"

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

echo "[TV] OK -> Archivo generado: ${OUT}"
echo "----------------------------------------"
cat "${OUT}"
echo "----------------------------------------"

if [ -z "${TV_ID}" ]; then
  echo "[TV] AVISO: ID vacío. Revisa:"
  echo "sudo journalctl -u teamviewerd -n 120 --no-pager"
fi
