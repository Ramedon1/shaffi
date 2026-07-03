#!/bin/bash
set -e

INSTALL_DIR="/opt/shaffi"
BIN_PATH="/usr/local/bin/shaffi"

RAW="https://raw.githubusercontent.com/Ramedon1/shaffi/main"

# ── Цвета ──
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

info()  { printf "${C}[i]${N} %s\n" "$*"; }
ok()    { printf "${G}[✓]${N} %s\n" "$*"; }
err()   { printf "${R}[✗]${N} %s\n" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash install.sh"

# ── Зависимости ──
if ! command -v curl &>/dev/null; then
    info "Устанавливаю curl..."
    apt-get update -qq && apt-get install -y -qq curl
fi

# ── Список файлов для скачивания ──
FILES=(
    "shaffi.sh"
    "config/shaffi.conf"
    "modules/core/common.sh"
    "modules/core/dependencies.sh"
    "modules/local/traffic_limiter.sh"
    "modules/local/shaper.bpf.c"
    "modules/local/shaffi_ctrl.py"
    "modules/security/whitelist_manager.sh"
)

# ── Скачивание ──
info "Устанавливаю shaffi в ${INSTALL_DIR}..."

for file in "${FILES[@]}"; do
    dir="${INSTALL_DIR}/$(dirname "$file")"
    mkdir -p "$dir"
    url="${RAW}/${file}"
    if ! curl -fsSL "$url" -o "${INSTALL_DIR}/${file}"; then
        err "Не удалось скачать: ${url}"
    fi
    ok "${file}"
done

# ── Права ──
chmod +x "${INSTALL_DIR}/shaffi.sh"
chmod +x "${INSTALL_DIR}/modules/local/shaffi_ctrl.py"

# ── Системная команда ──
cat > "$BIN_PATH" <<EOF
#!/bin/bash
exec /opt/shaffi/shaffi.sh "\$@"
EOF
chmod +x "$BIN_PATH"

echo
printf "${G}╔══════════════════════════════════════════╗${N}\n"
printf "${G}║${N}  ${W}Shaffi установлен успешно!${N}              ${G}║${N}\n"
printf "${G}╠══════════════════════════════════════════╣${N}\n"
printf "${G}║${N}  Запуск:  ${Y}shaffi${N}                         ${G}║${N}\n"
printf "${G}║${N}  Или:     ${Y}sudo shaffi${N}                     ${G}║${N}\n"
printf "${G}╚══════════════════════════════════════════╝${N}\n"
echo
