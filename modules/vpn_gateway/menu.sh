#!/bin/bash
# ============================================================ #
# ==        VPN GATEWAY MODULE: ДЛЯ RESHALA-ECOSYSTEM        == #
# ============================================================ #
#
# Упрощенное и автоматизированное меню управления лендингом/gateway.
#
# @menu.manifest
# @item( main | g | 🛡️ Маскировщик лендинга Bedolaga ${C_CYAN}(быстрый мастер)${C_RESET} | show_vpn_gateway_menu | 55 | 3 | Единый мастер настройки для маскировки лендинга Bedolaga. )
# @item( vpn_gateway | 1 | 🚀 Мастер: первичная настройка | vgw_install_wizard | 10 | 1 | Запрашивает параметры, обновляет конфиг и поднимает стек. )
# @item( vpn_gateway | 2 | 🔁 Мастер: изменить параметры | vgw_reconfigure_wizard | 20 | 1 | Обновляет quick_setup и перезапускает шлюз с nginx. )
# @item( vpn_gateway | 3 | ♻️ Перезапуск стека (анти-502) | vgw_run | 30 | 1 | Пересоздаёт контейнеры шлюза и перезапускает nginx. )
# @item( vpn_gateway | 4 | 📊 Статус и журналы | vgw_status_diagnostics | 40 | 2 | Показывает статус и последние логи edge-nginx и vpn-gateway. )
# @item( vpn_gateway | 5 | 🧪 Прогнать тесты | vgw_test | 50 | 2 | Запускает встроенные тесты проекта шлюза. )
# @item( vpn_gateway | 6 | 🔐 Сертификаты (выпуск/продление) | vgw_certs_full | 60 | 2 | Выпускает, продлевает сертификаты и настраивает cron. )
# @item( vpn_gateway | 7 | 💳 Скрытие return в платежке | vgw_toggle_hide_payment_return | 70 | 3 | Включает или отключает скрытие return-ссылки в платежах. )
# @item( vpn_gateway | x | 🧪 Удаление (предпросмотр) | vgw_uninstall_dry | 95 | 4 | Предпросмотр удаления без фактических изменений. )
# @item( vpn_gateway | d | 🗑️ Удаление выполнить (опасно) | vgw_uninstall_execute_confirmed | 96 | 4 | Удаление контейнеров шлюза (с подтверждением). )
# @item( vpn_gateway | D | ☠️ Полная очистка (очень опасно) | vgw_uninstall_purge_confirmed | 97 | 4 | Удаление контейнеров и локальных данных шлюза. )
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

_vgw_project_dir() { echo "${VPN_GATEWAY_MODULE_PROJECT_DIR:-/opt/vpn-gateway-project}"; }
_vgw_ctl_path() { local project_dir="$(_vgw_project_dir)"; local rel="${VPN_GATEWAY_MODULE_CTL_RELATIVE:-scripts/gatewayctl.sh}"; echo "${project_dir}/${rel}"; }

_vgw_validate_environment() {
    local project_dir="$(_vgw_project_dir)" ctl="$(_vgw_ctl_path)"
    [[ -d "$project_dir" ]] || { printf_error "Не найдена директория VPN Gateway: ${project_dir}"; return 1; }
    [[ -x "$ctl" ]] || { printf_error "Не найден исполняемый gatewayctl: ${ctl}"; return 1; }

    # Проверяем PyYAML — если нет, пробуем установить автоматически
    if ! python3 -c "import yaml" 2>/dev/null; then
        warn "PyYAML не найден. Пробую установить автоматически..."

        local venv_pip="${project_dir}/.venv/bin/pip"
        local installed=0

        if [[ -x "$venv_pip" ]]; then
            info "Устанавливаю через venv проекта: ${venv_pip}"
            if "$venv_pip" install pyyaml --quiet; then
                ok "PyYAML установлен в venv проекта."
                installed=1
            else
                warn "Не удалось установить через venv."
            fi
        fi

        if [[ "$installed" -eq 0 ]] && command -v pip3 &>/dev/null; then
            info "Устанавливаю через системный pip3..."
            if pip3 install pyyaml --quiet; then
                ok "PyYAML установлен глобально."
                installed=1
            else
                warn "Не удалось установить через pip3."
            fi
        fi

        if [[ "$installed" -eq 0 ]]; then
            printf_error "Не удалось автоматически установить PyYAML."
            printf_warning "Установи вручную: pip3 install pyyaml"
            printf_warning "Или через venv:   ${project_dir}/.venv/bin/pip install pyyaml"
            return 1
        fi

        # Повторная проверка после установки
        if ! python3 -c "import yaml" 2>/dev/null; then
            printf_error "PyYAML установлен, но python3 его не видит. Проверь окружение."
            return 1
        fi
    fi
}

_vgw_run_action() {
    local action="$1"; shift || true
    _vgw_validate_environment || return 1
    local project_dir="$(_vgw_project_dir)" ctl="$(_vgw_ctl_path)"
    ( cd "$project_dir"; "$ctl" "$action" "$@" )
}

_vgw_cfg_file() { echo "$(_vgw_project_dir)/config/gateway.yml"; }

_vgw_is_ipv4() {
    local v="$1"
    [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' octets=($v)
    for octet in "${octets[@]}"; do
        ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

_vgw_is_domain_like() {
    local v="$1"
    [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

_vgw_is_offer_like() {
    local v="$1"
    [[ "$v" =~ ^[a-zA-Z0-9._-]{2,64}$ ]]
}

_vgw_read_quick_field() {
    local field="$1" cfg_file="$(_vgw_cfg_file)"
    [[ -f "$cfg_file" ]] || { echo ""; return 0; }
    CFG_FILE="$cfg_file" FIELD_NAME="$field" python3 - <<'PY2'
import os
from pathlib import Path
import yaml
cfg = yaml.safe_load(Path(os.environ['CFG_FILE']).read_text(encoding='utf-8')) or {}
print(str((cfg.get('quick_setup') or {}).get(os.environ['FIELD_NAME'], '')).strip())
PY2
}

_vgw_update_quick_setup() {
    local public_domain="$1" origin_domain="$2" default_offer="$3" acme_enabled="$4" acme_email="$5" cfg_file="$(_vgw_cfg_file)"
    [[ -f "$cfg_file" ]] || { printf_error "Не найден config/gateway.yml: ${cfg_file}"; return 1; }
    CFG_FILE="$cfg_file" PUBLIC_DOMAIN="$public_domain" ORIGIN_DOMAIN="$origin_domain" DEFAULT_OFFER="$default_offer" ACME_ENABLED="$acme_enabled" ACME_EMAIL="$acme_email" python3 - <<'PY2'
import os
from pathlib import Path
import yaml
p=Path(os.environ['CFG_FILE'])
data=yaml.safe_load(p.read_text(encoding='utf-8')) or {}
if not isinstance(data, dict): data={}
q=data.get('quick_setup') if isinstance(data.get('quick_setup'), dict) else {}
q['public_domain']=os.environ['PUBLIC_DOMAIN'].strip()
q['origin_domain']=os.environ['ORIGIN_DOMAIN'].strip()
q['default_offer']=os.environ['DEFAULT_OFFER'].strip()
q['origin_scheme']=q.get('origin_scheme') or 'https'
q['acme_enabled'] = os.environ['ACME_ENABLED'].strip().lower() == 'true'
q['acme_email'] = os.environ['ACME_EMAIL'].strip()
data['quick_setup']=q
landing=data.get('landing')
if isinstance(landing, dict) and isinstance(landing.get('pages'), list) and landing['pages']:
    p0=landing['pages'][0]
    if isinstance(p0, dict) and p0.get('path')=='/':
        p0['mirror_target']=os.environ['DEFAULT_OFFER'].strip()
p.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding='utf-8')
print('ok')
PY2
}

_vgw_prompt_and_apply_common() {
    local mode="$1"
    local current_public="$(_vgw_read_quick_field public_domain)"
    local current_origin="$(_vgw_read_quick_field origin_domain)"
    local current_offer="$(_vgw_read_quick_field default_offer)"
    local current_acme_enabled="$(_vgw_read_quick_field acme_enabled)"
    local current_acme_email="$(_vgw_read_quick_field acme_email)"

    echo -e "  ${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}  ${C_YELLOW}Что нужно заполнить${C_RESET}                                    ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}╠══════════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}  1) Домен лендинга: что видит клиент в браузере.          ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}     Где взять: ваш рекламный/публичный домен в DNS.       ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}  2) Домен кабинета: ваш настоящий домен панели/бэкенда.   ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}     Где взять: домен, который уже открыт у вас в браузере.${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}  3) Оффер: код лендинга/тарифа для главной страницы.      ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}     Где взять: из ваших офферов в админке/конфиге.         ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}  4) Let's Encrypt: включайте, если домен настоящий.       ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}║${C_RESET}     Если IP/временный домен — лучше выключить.             ${C_CYAN}║${C_RESET}"
    echo -e "  ${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""

    local public_domain origin_domain default_offer
    local default_public="${current_public:-vpn.example.com}"
    local default_origin="${current_origin:-cabinet.example.com}"
    local default_offer_value="${current_offer:-wl-lte}"

    while true; do
        public_domain=$(safe_read "Домен лендинга" "${default_public}") || return 1
        [[ -n "$public_domain" ]] || { printf_error "Поле не может быть пустым."; continue; }
        if _vgw_is_domain_like "$public_domain" || _vgw_is_ipv4 "$public_domain"; then
            break
        fi
        printf_error "Домен лендинга заполнен неверно. Пример: vpn.example.com или 203.0.113.10"
    done

    while true; do
        origin_domain=$(safe_read "Домен кабинета" "${default_origin}") || return 1
        [[ -n "$origin_domain" ]] || { printf_error "Поле не может быть пустым."; continue; }
        if _vgw_is_domain_like "$origin_domain"; then
            break
        fi
        printf_error "Домен кабинета заполнен неверно. Пример: cabinet.example.com"
    done

    while true; do
        default_offer=$(safe_read "Оффер по умолчанию" "${default_offer_value}") || return 1
        [[ -n "$default_offer" ]] || { printf_error "Поле не может быть пустым."; continue; }
        if _vgw_is_offer_like "$default_offer"; then
            break
        fi
        printf_error "Оффер заполнен неверно. Используйте 2-64 символа: буквы, цифры, точка, дефис, подчёркивание."
    done

    local acme_default="y"
    if [[ "$public_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        acme_default="n"
    elif [[ "$current_acme_enabled" == "false" ]]; then
        acme_default="n"
    fi

    local acme_enabled="false"
    local acme_email="$current_acme_email"
    if ask_yes_no "Включить авто-выпуск Let's Encrypt для публичного домена? (y/n)" "$acme_default"; then
        acme_enabled="true"
        local default_acme_email="${current_acme_email:-admin@example.com}"
        while true; do
            acme_email=$(safe_read "Email для Let's Encrypt" "${default_acme_email}") || return 1
            [[ -n "$acme_email" && "$acme_email" != "admin@example.com" ]] || { printf_error "Укажите реальный email (не admin@example.com)."; continue; }
            if [[ "$acme_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                break
            fi
            printf_error "Email заполнен неверно. Пример: admin@yourdomain.com"
        done
    fi

    _vgw_update_quick_setup "$public_domain" "$origin_domain" "$default_offer" "$acme_enabled" "$acme_email" || return 1
    printf_ok "Конфиг обновлен"

    if [[ "$mode" == "install" ]]; then
        _vgw_run_action install
    else
        _vgw_run_action run
    fi
}

show_vpn_gateway_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "🛡️ Маскировщик лендинга Bedolaga" 64 "${C_CYAN}"
        printf_description "Простой мастер настройки + автоматизация."
        printf_description "Скрытие return платежки: ${C_YELLOW}$(_vgw_read_hide_payment_return)${C_RESET}"
        echo ""
        render_menu_items "vpn_gateway"
        echo ""
        printf_menu_option "b" "🔙 Назад в главное меню" "${C_CYAN}"
        print_separator "─" 64
        local choice; choice=$(safe_read "Твой выбор" "") || break
        [[ "$choice" =~ ^[bB]$ ]] && break
        local action; action=$(get_menu_action "vpn_gateway" "$choice")
        if [[ -n "$action" ]]; then eval "$action"; wait_for_enter; else printf_error "Нет такого пункта."; sleep 1; fi
    done
    disable_graceful_ctrlc
}

vgw_install_wizard(){ _vgw_prompt_and_apply_common install; }
vgw_reconfigure_wizard(){ _vgw_prompt_and_apply_common reconfigure; }
vgw_run(){ _vgw_run_action run; }
vgw_test(){ _vgw_run_action test; }
vgw_status(){ _vgw_run_action status; }
vgw_uninstall_dry(){ _vgw_run_action uninstall-dry; }

vgw_status_diagnostics() {
    _vgw_run_action status || true
    local project_dir="$(_vgw_project_dir)"
    # Поддерживаем и старый docker-compose, и новый docker compose (плагин)
    local dc_cmd
    if docker compose version &>/dev/null 2>&1; then
        dc_cmd="docker compose"
    elif command -v docker-compose &>/dev/null; then
        dc_cmd="docker-compose"
    else
        printf_error "Не найден ни 'docker compose', ни 'docker-compose'."
        return 1
    fi
    ( cd "$project_dir"; $dc_cmd -f docker-compose.yml -f docker-compose.edge.yml logs --tail=120 edge-nginx || true; echo ""; $dc_cmd -f docker-compose.yml -f docker-compose.edge.yml logs --tail=120 vpn-gateway || true )
}

vgw_certs_full(){ _vgw_run_action certs-ensure || return 1; _vgw_run_action certs-renew || return 1; _vgw_run_action certs-cron; }

vgw_uninstall_execute_confirmed(){ printf_critical_warning "ОПАСНО"; if ask_yes_no "Подтверждаешь удаление контейнеров gateway? (y/n)" "n"; then _vgw_run_action uninstall --non-interactive --yes; fi; }
vgw_uninstall_purge_confirmed(){ printf_critical_warning "ОЧЕНЬ ОПАСНО"; if ask_yes_no "Подтверждаешь PURGE gateway-данных? (y/n)" "n"; then _vgw_run_action uninstall-purge --non-interactive --yes-purge; fi; }

_vgw_read_hide_payment_return() {
    local cfg_file="$(_vgw_cfg_file)"; [[ -f "$cfg_file" ]] || { echo unknown; return 0; }
    CFG_FILE="$cfg_file" python3 - <<'PY2'
import os
from pathlib import Path
import yaml
sec=(yaml.safe_load(Path(os.environ['CFG_FILE']).read_text(encoding='utf-8')) or {}).get('security') or {}
v=sec.get('hide_payment_return', None)
print('true' if v is True else 'false' if v is False else 'unknown')
PY2
}

_vgw_set_hide_payment_return() {
    local target="$1" cfg_file="$(_vgw_cfg_file)"
    CFG_FILE="$cfg_file" TARGET_VALUE="$target" python3 - <<'PY2'
import os
from pathlib import Path
import yaml
p=Path(os.environ['CFG_FILE']); data=yaml.safe_load(p.read_text(encoding='utf-8')) or {}
if not isinstance(data, dict): data={}
sec=data.get('security') if isinstance(data.get('security'), dict) else {}
sec['hide_payment_return'] = os.environ['TARGET_VALUE'].strip().lower() == 'true'
data['security']=sec
p.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding='utf-8')
PY2
}

vgw_toggle_hide_payment_return() {
    local state="$(_vgw_read_hide_payment_return)"
    if [[ "$state" == "true" ]]; then
        if ask_yes_no "Сейчас true. Выключить? (y/n)" "n"; then _vgw_set_hide_payment_return false && printf_ok "hide_payment_return=false"; fi
    else
        if ask_yes_no "Сейчас false/unknown. Включить? (y/n)" "y"; then _vgw_set_hide_payment_return true && printf_ok "hide_payment_return=true"; fi
    fi
}
