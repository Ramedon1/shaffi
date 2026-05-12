#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Автоустановка VPN Gateway в один запуск.
# Цель: максимально простой старт без ручной рутины.
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG_FILE="${ROOT_DIR}/config/gateway.yml"
CFG_EXAMPLE_FILE="${ROOT_DIR}/config/gateway.example.yml"
VENV_PYTHON="${ROOT_DIR}/.venv/bin/python"

log() { echo "[install] $*"; }
warn() { echo "[warn] $*"; }
err() { echo "[error] $*" >&2; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Не найдена команда: ${cmd}"
    return 1
  fi
}

validate_config() {
  CFG_FILE="${CFG_FILE}" python3 - <<'PY'
import os
from pathlib import Path
import yaml

cfg_path = Path(os.environ["CFG_FILE"])
if not cfg_path.exists():
    raise SystemExit("config/gateway.yml отсутствует")

cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
quick = cfg.get("quick_setup", {})
required = ["public_domain", "origin_domain", "origin_scheme", "default_offer"]
missing = [k for k in required if not str(quick.get(k, "")).strip()]
if missing:
    raise SystemExit("Не заполнены обязательные поля quick_setup: " + ", ".join(missing))

print("OK")
PY
}

show_next_steps_and_exit() {
  cat <<'EOF'

[install] Создан config/gateway.yml из шаблона.
[install] Заполните блок "БЛОК ДЛЯ РЕДАКТИРОВАНИЯ" и запустите снова:

  nano config/gateway.yml
  ./scripts/install.sh

EOF
  exit 0
}

log "Проверяю зависимости..."
require_cmd python3
require_cmd docker

# Поддерживаем и docker compose (плагин, v2+), и legacy docker-compose
if docker compose version &>/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC_CMD="docker-compose"
else
  err "Не найден ни 'docker compose', ни 'docker-compose'. Установите Docker Compose."
  exit 1
fi
log "Используется: ${DC_CMD}"

# Проверяем PyYAML — если нет, устанавливаем автоматически
if ! python3 -c "import yaml" 2>/dev/null; then
  log "PyYAML не найден. Устанавливаю автоматически..."
  PYYAML_INSTALLED=0

  if [[ -x "${ROOT_DIR}/.venv/bin/pip" ]]; then
    log "Устанавливаю через venv: ${ROOT_DIR}/.venv/bin/pip"
    "${ROOT_DIR}/.venv/bin/pip" install pyyaml --quiet && PYYAML_INSTALLED=1 || warn "Установка через venv не удалась."
  fi

  if [[ "${PYYAML_INSTALLED}" -eq 0 ]] && command -v pip3 &>/dev/null; then
    log "Устанавливаю через системный pip3..."
    pip3 install pyyaml --quiet && PYYAML_INSTALLED=1 || warn "Установка через pip3 не удалась."
  fi

  if [[ "${PYYAML_INSTALLED}" -eq 0 ]]; then
    err "Не удалось автоматически установить PyYAML."
    err "Установи вручную: pip3 install pyyaml"
    exit 1
  fi

  if ! python3 -c "import yaml" 2>/dev/null; then
    err "PyYAML установлен, но python3 его не видит. Проверь PATH и окружение."
    exit 1
  fi
  log "PyYAML успешно установлен."
fi

if [[ ! -x "${VENV_PYTHON}" ]]; then
  err "Не найден venv python: ${VENV_PYTHON}"
  err "Создайте окружение проекта перед установкой."
  exit 1
fi

if [[ ! -f "${CFG_FILE}" ]]; then
  if [[ -f "${CFG_EXAMPLE_FILE}" ]]; then
    log "config/gateway.yml не найден, копирую из шаблона..."
    cp "${CFG_EXAMPLE_FILE}" "${CFG_FILE}"
    show_next_steps_and_exit
  else
    err "Не найдены ни config/gateway.yml, ни config/gateway.example.yml"
    exit 1
  fi
fi

log "Проверяю корректность config/gateway.yml..."
validate_config >/dev/null

cd "${ROOT_DIR}"

log "Запускаю тесты проекта..."
"${VENV_PYTHON}" -m pytest -q

log "Запускаю production-стек..."
./scripts/run-prod.sh

log "Проверяю контейнеры..."
if ! docker ps --format '{{.Names}}' | grep -q '^vpn-gateway$'; then
  err "Контейнер vpn-gateway не запущен"
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q '^vpn-edge-nginx$'; then
  err "Контейнер vpn-edge-nginx не запущен"
  exit 1
fi

log "Проверяю health endpoint внутри gateway-контейнера..."
for i in {1..20}; do
  if docker exec vpn-gateway python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)
print('ok')
PY
  then
    log "Health-check успешен"
    break
  fi
  if [[ "$i" -eq 20 ]]; then
    err "Health-check не прошел за отведенное время"
    exit 1
  fi
  sleep 1
done

log "Проверяю редирект /start внутри gateway-контейнера..."
START_CODE_INNER="$(docker exec -i vpn-gateway python - <<'PY'
import urllib.request

req = urllib.request.Request('http://127.0.0.1:8080/start?target=test-offer', method='GET')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

opener = urllib.request.build_opener(NoRedirect)
try:
    resp = opener.open(req, timeout=3)
    print(resp.getcode())
except Exception as e:
    if hasattr(e, 'code'):
        print(e.code)
    else:
        print('000')
PY
)"
if [[ "${START_CODE_INNER}" != "302" ]]; then
  err "Ожидался HTTP 302 на /start внутри gateway, получено: ${START_CODE_INNER}"
  exit 1
fi
log "Проверка /start внутри gateway успешна (HTTP 302)"

log "Проверяю /start через edge (информационная проверка)..."
START_CODE_EDGE="$(curl -k -s -o /dev/null -w '%{http_code}' 'https://127.0.0.1/start?target=test-offer' || true)"
if [[ "${START_CODE_EDGE}" != "302" ]]; then
  warn "Через edge получен код ${START_CODE_EDGE}. Проверьте host nginx/server_name и внешний прокси, если ожидаете 302 снаружи."
else
  log "Проверка /start через edge успешна (HTTP 302)"
fi

log "Установка и базовая проверка завершены успешно ✅"
