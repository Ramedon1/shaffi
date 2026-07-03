#!/bin/bash

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Загружаем конфиг
if [[ -f "${SCRIPT_DIR}/config/shaffi.conf" ]]; then
    source "${SCRIPT_DIR}/config/shaffi.conf"
fi

# Инициализируем LOGFILE если не задан конфигом
LOGFILE="${LOGFILE:-/var/log/shaffi.log}"

source "${SCRIPT_DIR}/modules/core/common.sh"
source "${SCRIPT_DIR}/modules/local/traffic_limiter.sh"

show_traffic_limiter_menu
