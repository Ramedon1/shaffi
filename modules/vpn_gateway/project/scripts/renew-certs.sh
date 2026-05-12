#!/usr/bin/env bash
set -euo pipefail

# Автообновление Let's Encrypt и безопасный reload edge-nginx.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
LE_DIR="${ROOT_DIR}/edge/letsencrypt"
CERTS_DIR="${ROOT_DIR}/edge/certs"
ACME_WEBROOT_DIR="${ROOT_DIR}/edge/acme-challenge"

# Используем venv python если есть (PyYAML может быть только там), иначе системный python3
if [[ -x "${ROOT_DIR}/.venv/bin/python" ]]; then
  PYTHON="${ROOT_DIR}/.venv/bin/python"
else
  PYTHON="python3"
fi

mkdir -p "${LE_DIR}" "${CERTS_DIR}" "${ACME_WEBROOT_DIR}"

readarray -t CFG_VALUES < <(CFG_FILE="${CFG_FILE}" "${PYTHON}" - <<'PY'
import os
import yaml
from pathlib import Path
cfg = yaml.safe_load(Path(os.environ['CFG_FILE']).read_text(encoding='utf-8'))
quick = cfg.get('quick_setup', {})
project = cfg.get('project', {})
edge = cfg.get('edge', {})
print(quick.get('public_domain') or project.get('public_domain') or '')
print(quick.get('acme_email') or '')
print(str(quick.get('acme_enabled', True)).lower())
print(str(edge.get('http_port', 80)))
print(str(edge.get('https_port', 443)))
PY
)

EDGE_DOMAIN="${CFG_VALUES[0]:-}"
ACME_EMAIL="${CFG_VALUES[1]:-}"
ACME_ENABLED="${CFG_VALUES[2]:-true}"
EDGE_HTTP_PORT="${CFG_VALUES[3]:-80}"
EDGE_HTTPS_PORT="${CFG_VALUES[4]:-443}"

if [[ -z "${EDGE_DOMAIN}" ]]; then
  echo "[error] Проверьте quick_setup.public_domain в config/gateway.yml" >&2
  exit 1
fi

if [[ "${ACME_ENABLED}" != "true" || "${EDGE_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[ok] ACME выключен или используется IP, renew не требуется"
  exit 0
fi

if [[ -z "${ACME_EMAIL}" || "${ACME_EMAIL}" == "admin@example.com" ]]; then
  echo "[error] Проверьте quick_setup.acme_email в config/gateway.yml" >&2
  exit 1
fi

cd "${ROOT_DIR}"

# Поддерживаем и docker compose (v2+), и legacy docker-compose
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  echo "[error] Не найден ни 'docker compose', ни 'docker-compose'." >&2; exit 1
fi


if command -v certbot >/dev/null 2>&1; then
  certbot renew --webroot -w "${ACME_WEBROOT_DIR}" --quiet
else
  docker run --rm \
    -v "${ACME_WEBROOT_DIR}:/var/www/acme-challenge" \
    -v "${LE_DIR}:/etc/letsencrypt" \
    certbot/certbot:latest renew --webroot -w /var/www/acme-challenge --quiet
fi

if [[ -f "${LE_DIR}/live/${EDGE_DOMAIN}/fullchain.pem" && -f "${LE_DIR}/live/${EDGE_DOMAIN}/privkey.pem" ]]; then
  cp "${LE_DIR}/live/${EDGE_DOMAIN}/fullchain.pem" "${CERTS_DIR}/fullchain.pem"
  cp "${LE_DIR}/live/${EDGE_DOMAIN}/privkey.pem" "${CERTS_DIR}/privkey.pem"
fi

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml exec -T edge-nginx nginx -t
EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml exec -T edge-nginx nginx -s reload

echo "[ok] Проверка и reload сертификатов выполнены"