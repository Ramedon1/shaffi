#!/usr/bin/env bash
set -euo pipefail

# Запуск production-стека из одного конфига config/gateway.yml
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
EDGE_ENV_FILE="${ROOT_DIR}/edge/.env.edge"

if [[ ! -f "${CFG_FILE}" ]]; then
  echo "[error] Не найден конфиг: ${CFG_FILE}" >&2
  exit 1
fi

# Поддерживаем и docker compose (плагин, v2+), и legacy docker-compose
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC_CMD="docker-compose"
else
  echo "[error] Не найден ни 'docker compose', ни 'docker-compose'." >&2
  exit 1
fi

readarray -t CFG_VALUES < <(CFG_FILE="${CFG_FILE}" python3 - <<'PY'
import os
import yaml
from pathlib import Path
cfg_path = Path(os.environ["CFG_FILE"])
cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
quick = cfg.get("quick_setup", {})
project = cfg.get("project", {})
edge = cfg.get("edge", {})
print(quick.get("public_domain") or project.get("public_domain") or "")
print(str(edge.get("http_port", 80)))
print(str(edge.get("https_port", 443)))
PY
)

EDGE_DOMAIN="${CFG_VALUES[0]:-}"
EDGE_HTTP_PORT="${CFG_VALUES[1]:-80}"
EDGE_HTTPS_PORT="${CFG_VALUES[2]:-443}"

if [[ -z "${EDGE_DOMAIN}" ]]; then
  echo "[error] Не задан public_domain в quick_setup или project в config/gateway.yml" >&2
  exit 1
fi

cat > "${EDGE_ENV_FILE}" <<EOF
EDGE_DOMAIN=${EDGE_DOMAIN}
EDGE_HTTP_PORT=${EDGE_HTTP_PORT}
EDGE_HTTPS_PORT=${EDGE_HTTPS_PORT}
EOF

cd "${ROOT_DIR}"
if [[ ! -f "${ROOT_DIR}/edge/certs/fullchain.pem" || ! -f "${ROOT_DIR}/edge/certs/privkey.pem" ]]; then
  echo "[info] Сертификаты не найдены, запускаю автоматический выпуск"
  ./scripts/ensure-certs.sh
fi

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml down --remove-orphans || true

# Явно удаляем контейнеры по имени — на случай если они были созданы с другим compose-проектом
# (docker-compose down не трогает «чужие» контейнеры с тем же именем)
for cname in vpn-gateway vpn-edge-nginx; do
  if docker ps -a --format '{{.Names}}' | grep -qx "${cname}"; then
    echo "[info] Удаляю старый контейнер: ${cname}"
    docker rm -f "${cname}" >/dev/null 2>&1 || true
  fi
done

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml up -d --build --force-recreate --remove-orphans

EDGE_HTTP_PORT="${EDGE_HTTP_PORT}" EDGE_HTTPS_PORT="${EDGE_HTTPS_PORT}" $DC_CMD -f docker-compose.yml -f docker-compose.edge.yml restart edge-nginx

echo "[ok] Стек полностью перезапущен. Публичный домен: ${EDGE_DOMAIN}, HTTP: ${EDGE_HTTP_PORT}, HTTPS: ${EDGE_HTTPS_PORT}"