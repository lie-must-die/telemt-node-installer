#!/bin/bash
# =================================================================
# Установщик VPN-узла: оптимизация Ubuntu 24.04 + Telemt (Telegram Proxy)
# Firewall: nftables | Geoblock: nftables sets | Fail2ban: nftables backend
# =================================================================

set -u

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите от root (sudo -i)"
    exit 1
fi

# =================================================================
# Цвета и хелперы
# =================================================================
C_RESET=$'\033[0m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'
C_RED=$'\033[1;31m'
C_BOLD=$'\033[1m'

step()    { echo -e "\n${C_CYAN}${C_BOLD}[$1/$TOTAL_STEPS] $2${C_RESET}"; }
info()    { echo -e "   ${C_GREEN}✓${C_RESET} $1"; }
warn()    { echo -e "   ${C_YELLOW}!${C_RESET} $1"; }
err()     { echo -e "   ${C_RED}✗${C_RESET} $1"; }
skip()    { echo -e "   ${C_YELLOW}—${C_RESET} $1 (пропущено)"; }

ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    local ans
    read -r -p "$(echo -e "${C_BOLD}?${C_RESET} $prompt $hint ")" ans < /dev/tty || ans=""
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" || "${ans,,}" == "д" ]]
}

ask_str() {
    local prompt="$1"
    local default="${2:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [$default]"
    local ans
    read -r -p "$(echo -e "${C_BOLD}?${C_RESET} ${prompt}${hint}: ")" ans < /dev/tty || ans=""
    echo "${ans:-$default}"
}

ask_str_required() {
    local prompt="$1"
    local ans=""
    while [[ -z "$ans" ]]; do
        read -r -p "$(echo -e "${C_BOLD}?${C_RESET} ${prompt}: ")" ans < /dev/tty || ans=""
        [[ -z "$ans" ]] && err "Значение обязательно"
    done
    echo "$ans"
}

gen_hex32() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

is_hex32() {
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

get_external_ip() {
    local ip=""
    for svc in "https://ifconfig.me" "https://api.ipify.org" "https://ipinfo.io/ip"; do
        ip=$(curl -4 -sS --max-time 5 "$svc" 2>/dev/null | tr -d ' \n\r\t')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

TOTAL_STEPS=18

# =================================================================
# Шапка и интерактив
# =================================================================
clear
cat <<'EOF'
==================================================================
      УСТАНОВКА VPN-УЗЛА: Ubuntu 24.04 + Telemt + nftables
==================================================================
EOF

echo
echo -e "${C_BOLD}Тест VPS перед установкой:${C_RESET}"
if ask_yn "Запустить проверку сервера (vps_check.sh) перед настройкой?" "y"; then
    echo
    curl -sSL https://raw.githubusercontent.com/lie-must-die/MTPROTO/refs/heads/main/vps_check.sh | bash || true
    echo
    read -r -p "$(echo -e "${C_BOLD}Нажмите Enter чтобы продолжить установку...${C_RESET}")" _ < /dev/tty || true
fi

echo
echo -e "${C_BOLD}Настройка параметров:${C_RESET}"
echo

SSH_PORT=$(ask_str "SSH порт" "22")
TELEMT_PORT=$(ask_str "Telemt порт" "443")
TELEMT_DOMAIN=$(ask_str_required "TLS-домен для Telemt (маскировка)")

# Генерируем secret сразу — он нужен юзеру для регистрации прокси
# в @MTProxyAdminBot и получения ad_tag.
TELEMT_SECRET=$(gen_hex32)

# Пытаемся определить внешний IP для удобства
echo
echo -e "${C_CYAN}Определяю внешний IP сервера...${C_RESET}"
EXTERNAL_IP=$(get_external_ip || true)

echo
echo -e "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Регистрация прокси в @MTProxyAdminBot (для получения ad_tag)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo
echo "  1. Открой в Telegram: ${C_CYAN}@MTProxyAdminBot${C_RESET}"
echo "  2. Отправь команду: ${C_CYAN}/newproxy${C_RESET}"
if [[ -n "$EXTERNAL_IP" ]]; then
    echo -e "  3. Адрес прокси:    ${C_GREEN}${EXTERNAL_IP}:${TELEMT_PORT}${C_RESET}"
else
    echo -e "  3. Адрес прокси:    ${C_YELLOW}<внешний_IP_сервера>:${TELEMT_PORT}${C_RESET}"
fi
echo -e "  4. Secret:          ${C_GREEN}${TELEMT_SECRET}${C_RESET}"
echo "  5. Бот вернёт ad_tag (32-hex) — скопируй его для следующего шага"
echo

echo -e "${C_BOLD}ad_tag для Telemt:${C_RESET}"
echo "  1) Ввести полученный от @MTProxyAdminBot"
echo "  2) Пропустить (без ad_tag)"
AD_TAG_CHOICE=$(ask_str "Выбор" "1")

AD_TAG_VALUE=""
AD_TAG_ENABLED=0

case "$AD_TAG_CHOICE" in
    2)
        AD_TAG_ENABLED=0
        ;;
    *)
        AD_TAG_VALUE=$(ask_str_required "Введите ad_tag (32 hex символа)")
        while ! is_hex32 "$AD_TAG_VALUE"; do
            err "ad_tag должен быть ровно 32 hex символа (0-9, a-f)"
            AD_TAG_VALUE=$(ask_str_required "Введите ad_tag (32 hex символа)")
        done
        AD_TAG_ENABLED=1
        ;;
esac

echo
echo -e "${C_BOLD}Блоки установки (все опциональны, Enter = Да):${C_RESET}"
echo

DO_APT=$(ask_yn "[1]  Обновление пакетов и установка зависимостей?"         "y" && echo 1 || echo 0)
DO_SSH=$(ask_yn "[2]  Тюнинг SSH (порт $SSH_PORT, root, password auth)?"    "y" && echo 1 || echo 0)
DO_MOTD=$(ask_yn "[3]  Минималистичное приветствие MOTD?"                   "y" && echo 1 || echo 0)
DO_JOURNALD=$(ask_yn "[4]  Лимиты journald (400M/50M)?"                     "y" && echo 1 || echo 0)
DO_ULIMIT=$(ask_yn "[5]  Лимиты файловых дескрипторов (1048576)?"           "y" && echo 1 || echo 0)
DO_SYSCTL=$(ask_yn "[6]  Тюнинг ядра (BBR, TCP, отключение IPv6)?"          "y" && echo 1 || echo 0)
DO_DNS=$(ask_yn "[7]  DNS Cloudflare Security (1.1.1.1)?"                   "y" && echo 1 || echo 0)
DO_CLEARDNS=$(ask_yn "[8]  Сброс per-interface DNS (clear-iface-dns)?"      "y" && echo 1 || echo 0)
DO_NFT=$(ask_yn "[9]  Firewall на nftables?"                                "y" && echo 1 || echo 0)
DO_F2B=$(ask_yn "[10] Fail2ban с nftables backend?"                         "y" && echo 1 || echo 0)
DO_GEOBLOCK=$(ask_yn "[11] Геоблокировка стран (nftables sets)?"            "y" && echo 1 || echo 0)
DO_BANIP=$(ask_yn "[12] Алиас banip для ручной блокировки?"                 "y" && echo 1 || echo 0)
DO_ALIASES=$(ask_yn "[13] Алиас update-all и очистка apt?"                  "y" && echo 1 || echo 0)
DO_TELEMT=$(ask_yn "[14] Установка Telemt?"                                 "y" && echo 1 || echo 0)
DO_TELEMT_LIMITS=$(ask_yn "[15] Drop-in LimitNOFILE=1048576 для telemt?"    "y" && echo 1 || echo 0)
DO_TELEMT_CONF=$(ask_yn "[16] Залить кастомный config.toml для telemt?"     "y" && echo 1 || echo 0)
DO_TELEMT_RESTART=$(ask_yn "[17] Перезапустить telemt после настройки?"     "y" && echo 1 || echo 0)
DO_SHAPER=$(ask_yn "[18] Установка telemt-shaper?"                          "y" && echo 1 || echo 0)

# Трекинг статуса для финального вывода
declare -A STATUS
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    STATUS[$i]="skip"
done

echo
echo -e "${C_BOLD}Начинаю установку...${C_RESET}"

# =================================================================
# [1] apt update + зависимости
# =================================================================
if [[ "$DO_APT" == "1" ]]; then
    step 1 "Обновление пакетов и установка зависимостей"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get upgrade -y -q
    apt-get install -y -q \
        fail2ban curl wget sed logrotate landscape-common psmisc \
        nftables conntrack jq
    info "Пакеты установлены"
    STATUS[1]="ok"
fi

# =================================================================
# [2] SSH
# =================================================================
if [[ "$DO_SSH" == "1" ]]; thenif [[ "$DO_SSH" == "1" ]]; then
    step 2 "Тюнинг SSH (порт $SSH_PORT)"

    # Запоминаем текущий порт sshd ДО любых изменений —
    # нужно, чтобы не убить собственную ssh-сессию через fuser -k.
    OLD_SSH_PORT=$(ss -tlnpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')

    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true

    mkdir -p /run/sshd
    chmod 0755 /run/sshd

    rm -f /etc/ssh/sshd_config.d/*.conf

    cat > /etc/ssh/sshd_config <<EOF
Port ${SSH_PORT}
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    # fuser -k только если порт реально меняется.
    # Иначе убьём свой же sshd (fuser шлёт SIGKILL всему, что держит порт).
    if [[ -n "$OLD_SSH_PORT" && "$OLD_SSH_PORT" != "$SSH_PORT" ]]; then
        fuser -k "${SSH_PORT}/tcp" > /dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable ssh > /dev/null 2>&1
    systemctl restart ssh
    info "SSH слушает на порту ${SSH_PORT}"
    STATUS[2]="ok"
fi

# =================================================================
# [3] MOTD
# =================================================================
if [[ "$DO_MOTD" == "1" ]]; then
    step 3 "Настройка минималистичного MOTD"
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    cat > /etc/update-motd.d/50-sysinfo <<'EOF'
#!/bin/sh
LOAD=$(cut -d' ' -f1 /proc/loadavg)
DISK_PCT=$(df -h / | awk 'NR==2{print $5}')
DISK=$(df -h / | awk 'NR==2{print $3" of "$2}')
MEM=$(free | awk '/Mem/{printf "%d%%", $3/$2*100}')
SWAP=$(free | awk '/Swap/{if($2>0) printf "%d%%", $3/$2*100; else print "0%"}')
PROCS=$(ps aux | wc -l)
USERS=$(who | wc -l)
IP=$(ip -4 addr show scope global | awk '/inet/{print $2}' | cut -d/ -f1 | head -1)

echo "  load: $LOAD"
echo "  disk: $DISK_PCT ($DISK)"
echo "  mem: $MEM  swap: $SWAP"
echo "  procs: $PROCS  users: $USERS"
echo "  ip: $IP"
EOF
    chmod +x /etc/update-motd.d/50-sysinfo
    info "MOTD установлен"
    STATUS[3]="ok"
fi

# =================================================================
# [4] Journald
# =================================================================
if [[ "$DO_JOURNALD" == "1" ]]; then
    step 4 "Лимиты journald"
    cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
SystemMaxUse=400M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
EOF
    systemctl restart systemd-journald
    info "journald: 400M лимит, 50M на файл"
    STATUS[4]="ok"
fi

# =================================================================
# [5] Лимиты файлов
# =================================================================
if [[ "$DO_ULIMIT" == "1" ]]; then
    step 5 "Лимиты файловых дескрипторов"
    cat > /etc/security/limits.d/99-vpn-limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    sed -i 's/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/system.conf
    sed -i 's/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/user.conf
    systemctl daemon-reexec
    info "nofile = 1048576 (soft/hard, systemd system+user)"
    STATUS[5]="ok"
fi

# =================================================================
# [6] sysctl (BBR + TCP + отключение IPv6)
# =================================================================
if [[ "$DO_SYSCTL" == "1" ]]; then
    step 6 "Глубокий тюнинг ядра (BBR + отключение IPv6)"
    cat > /etc/sysctl.d/99-custom-network-tuning.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Backlog / очереди
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 65535

# Буферы
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Таймауты / keepalive
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Оптимизации TCP
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.netfilter.nf_conntrack_max = 262144

# Ресурсы
fs.file-max = 2097152
vm.swappiness = 10

# Forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0

# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system > /dev/null
    info "BBR активен, IPv6 отключён"
    STATUS[6]="ok"
fi

# =================================================================
# [7] DNS Cloudflare Security
# =================================================================
if [[ "$DO_DNS" == "1" ]]; then
    step 7 "DNS Cloudflare Security (1.1.1.1)"
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/cloudflare.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8
DNSSEC=no
EOF
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    info "DNS: 1.1.1.1 / 1.0.0.1 (Security)"
    STATUS[7]="ok"
fi

# =================================================================
# [8] Clear-DNS Fix
# =================================================================
if [[ "$DO_CLEARDNS" == "1" ]]; then
    step 8 "Сброс per-interface DNS"
    cat > /etc/systemd/system/clear-iface-dns.service <<'EOF'
[Unit]
Description=Clear per-interface DNS (force global Cloudflare)
After=systemd-resolved.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for iface in $(ip -o link show | awk -F": " "{print \$2}" | cut -d@ -f1 | grep -v "^lo$"); do resolvectl dns "$iface" "" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now clear-iface-dns.service > /dev/null 2>&1
    info "clear-iface-dns.service активен"
    STATUS[8]="ok"
fi

# =================================================================
# [9] Firewall на nftables
# =================================================================
if [[ "$DO_NFT" == "1" ]]; then
    step 9 "Firewall на nftables"

    # Отключаем UFW если вдруг он установлен
    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable > /dev/null 2>&1 || true
    fi

    mkdir -p /etc/nftables.d

    # Основной конфиг
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

# Подключаем внешние наборы (blacklist, geoblock) если они есть
include "/etc/nftables.d/sets.nft"

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Ранний дроп: ручной бан
        ip saddr @blacklist_v4 drop
        # Ранний дроп: геоблок (если набор есть)
        ip saddr @geoblock_v4 drop

        # Локалхост
        iif "lo" accept

        # Установленные соединения
        ct state established,related accept
        ct state invalid drop

        # ICMP
        icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded, parameter-problem } accept

        # SSH
        tcp dport ${SSH_PORT} accept

        # Telemt
        tcp dport ${TELEMT_PORT} accept
        udp dport ${TELEMT_PORT} accept

        # Кастомные подключения (для fail2ban)
        include "/etc/nftables.d/fail2ban.nft"
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

    # Начальные пустые sets (blacklist + geoblock + fail2ban stub)
    cat > /etc/nftables.d/sets.nft <<'EOF'
table inet filter {
    # Персистентный blacklist (ручной banip)
    set blacklist_v4 {
        type ipv4_addr
        flags interval
    }

    # Геоблок (обновляется cron)
    set geoblock_v4 {
        type ipv4_addr
        flags interval
    }
}
EOF

    # fail2ban-правила подключаются отдельным файлом (стаб)
    cat > /etc/nftables.d/fail2ban.nft <<'EOF'
# fail2ban правила добавляются сюда автоматически
EOF

    # Загрузка blacklist при старте
    cat > /etc/nftables.d/blacklist-load.nft <<'EOF'
# Этот файл подгружается systemd-юнитом для восстановления blacklist
EOF

    # Persistence сервис для blacklist
    cat > /usr/local/sbin/nft-blacklist-save <<'EOF'
#!/bin/bash
# Сохраняем текущий blacklist в файл
{
    echo "table inet filter {"
    echo "    set blacklist_v4 {"
    echo "        type ipv4_addr"
    echo "        flags interval"
    elements=$(nft -j list set inet filter blacklist_v4 2>/dev/null | \
        jq -r '.nftables[].set.elem[]? | if type == "string" then . else .prefix.addr + "/" + (.prefix.len|tostring) end' 2>/dev/null)
    if [[ -n "$elements" ]]; then
        echo "        elements = {"
        echo "$elements" | awk '{printf "            %s,\n", $0}' | sed '$ s/,$//'
        echo "        }"
    fi
    echo "    }"
    echo "}"
} > /etc/nftables.d/blacklist-persist.nft
EOF
    chmod +x /usr/local/sbin/nft-blacklist-save

    cat > /usr/local/sbin/nft-blacklist-restore <<'EOF'
#!/bin/bash
# Восстанавливаем blacklist из файла
if [[ -f /etc/nftables.d/blacklist-persist.nft ]]; then
    nft -f /etc/nftables.d/blacklist-persist.nft 2>/dev/null || true
fi
EOF
    chmod +x /usr/local/sbin/nft-blacklist-restore

    cat > /etc/systemd/system/nft-blacklist-restore.service <<'EOF'
[Unit]
Description=Restore nftables blacklist set
After=nftables.service
Requires=nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nft-blacklist-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now nftables.service > /dev/null 2>&1
    systemctl enable nft-blacklist-restore.service > /dev/null 2>&1
    nft -f /etc/nftables.conf
    info "nftables активен: SSH ${SSH_PORT}, Telemt ${TELEMT_PORT} (tcp+udp)"
    STATUS[9]="ok"
fi

# =================================================================
# [10] Fail2ban с nftables backend
# =================================================================
if [[ "$DO_F2B" == "1" ]]; then
    step 10 "Fail2ban (nftables backend)"
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime  = 86400
findtime = 3600
maxretry = 10

[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd
EOF
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    info "Fail2ban активен, защита порта ${SSH_PORT}"
    STATUS[10]="ok"
fi

# =================================================================
# [11] Геоблок на nftables sets
# =================================================================
if [[ "$DO_GEOBLOCK" == "1" ]]; then
    step 11 "Геоблокировка (nftables sets)"

    mkdir -p /etc/nftables.d

    # Скрипт обновления геоблока
    cat > /usr/local/sbin/nft-geoblock-update <<'EOF'
#!/bin/bash
# Обновление геоблока: скачиваем CIDR списки стран и загружаем в nftables set
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COUNTRIES="pk iq ir af sa ae bd in cn id my th vn kh mm lk np bt mn kp sy ye ly dz ma tn eg jo lb kw bh om qa uz tj tm"
PERSIST_FILE="/etc/nftables.d/geoblock-persist.nft"
TMP_FILE=$(mktemp)
LOG="/var/log/nft-geoblock.log"

echo "$(date -Is) [INFO] Старт обновления геоблока" >> "$LOG"

CIDRS=""
FAIL_COUNT=0
for cc in $COUNTRIES; do
    data=$(curl -sSf --max-time 30 "https://www.ipdeny.com/ipblocks/data/aggregated/${cc}-aggregated.zone" 2>>"$LOG")
    if [[ -z "$data" ]]; then
        echo "$(date -Is) [WARN] Не удалось загрузить $cc" >> "$LOG"
        FAIL_COUNT=$((FAIL_COUNT+1))
        continue
    fi
    CIDRS+="$data"$'\n'
done

if [[ $FAIL_COUNT -ge 5 ]]; then
    echo "$(date -Is) [ERROR] Слишком много ошибок ($FAIL_COUNT). Обновление отменено." >> "$LOG"
    rm -f "$TMP_FILE"
    exit 1
fi

# Убираем пустые строки и комментарии
CIDRS=$(echo "$CIDRS" | grep -E '^[0-9]' | sort -u)
COUNT=$(echo "$CIDRS" | wc -l)

if [[ $COUNT -lt 1000 ]]; then
    echo "$(date -Is) [ERROR] Слишком мало диапазонов ($COUNT). Обновление отменено." >> "$LOG"
    rm -f "$TMP_FILE"
    exit 1
fi

# Формируем персистентный файл
{
    echo "table inet filter {"
    echo "    set geoblock_v4 {"
    echo "        type ipv4_addr"
    echo "        flags interval"
    echo "        elements = {"
    echo "$CIDRS" | awk '{printf "            %s,\n", $0}' | sed '$ s/,$//'
    echo "        }"
    echo "    }"
    echo "}"
} > "$TMP_FILE"

# Проверяем синтаксис
if ! nft -c -f "$TMP_FILE" 2>>"$LOG"; then
    echo "$(date -Is) [ERROR] Синтаксическая ошибка в сгенерированном файле" >> "$LOG"
    rm -f "$TMP_FILE"
    exit 1
fi

# Атомарно меняем и применяем
mv "$TMP_FILE" "$PERSIST_FILE"

# Флашим старый set и применяем новый
nft flush set inet filter geoblock_v4 2>/dev/null || true
nft -f "$PERSIST_FILE" 2>>"$LOG"

echo "$(date -Is) [OK] Загружено $COUNT диапазонов" >> "$LOG"
EOF
    chmod +x /usr/local/sbin/nft-geoblock-update

    # systemd юнит для восстановления при загрузке
    cat > /etc/systemd/system/nft-geoblock-restore.service <<'EOF'
[Unit]
Description=Restore nftables geoblock set from persistent file
After=nftables.service
Requires=nftables.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [[ -f /etc/nftables.d/geoblock-persist.nft ]]; then nft -f /etc/nftables.d/geoblock-persist.nft; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nft-geoblock-restore.service > /dev/null 2>&1

    # Cron: обновление раз в неделю
    cat > /etc/cron.weekly/nft-geoblock-update <<'EOF'
#!/bin/bash
/usr/local/sbin/nft-geoblock-update
EOF
    chmod +x /etc/cron.weekly/nft-geoblock-update

    # Первый запуск
    info "Загружаю списки стран (1-2 минуты)..."
    if /usr/local/sbin/nft-geoblock-update; then
        GEO_COUNT=$(nft -j list set inet filter geoblock_v4 2>/dev/null | jq '[.nftables[].set.elem[]?] | length' 2>/dev/null || echo "?")
        info "Геоблок активен: ${GEO_COUNT} диапазонов"
        STATUS[11]="ok"
    else
        warn "Не удалось загрузить списки (см. /var/log/nft-geoblock.log). Cron повторит через неделю."
        STATUS[11]="partial"
    fi
fi

# =================================================================
# [12] banip алиас (nftables)
# =================================================================
if [[ "$DO_BANIP" == "1" ]]; then
    step 12 "Алиас banip (nftables, persistent)"

    # Персистентный скрипт banip
    cat > /usr/local/sbin/banip <<'EOF'
#!/bin/bash
# Бан IP через nftables с сохранением после перезагрузки
if [[ $# -lt 1 ]]; then
    echo "Usage: banip <IP> [<IP>...]"
    exit 1
fi

for ip in "$@"; do
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        echo "[!] Пропущен невалидный: $ip"
        continue
    fi
    if nft add element inet filter blacklist_v4 "{ $ip }" 2>/dev/null; then
        # Сбрасываем активные сессии
        ip_only="${ip%%/*}"
        conntrack -D -s "$ip_only" 2>/dev/null || true
        echo "[+] Banned: $ip"
    else
        echo "[=] Already banned (or error): $ip"
    fi
done

# Сохраняем blacklist для персистентности
/usr/local/sbin/nft-blacklist-save 2>/dev/null || true
EOF
    chmod +x /usr/local/sbin/banip

    # unbanip как бонус
    cat > /usr/local/sbin/unbanip <<'EOF'
#!/bin/bash
if [[ $# -lt 1 ]]; then
    echo "Usage: unbanip <IP> [<IP>...]"
    exit 1
fi
for ip in "$@"; do
    if nft delete element inet filter blacklist_v4 "{ $ip }" 2>/dev/null; then
        echo "[-] Unbanned: $ip"
    else
        echo "[=] Not in blacklist: $ip"
    fi
done
/usr/local/sbin/nft-blacklist-save 2>/dev/null || true
EOF
    chmod +x /usr/local/sbin/unbanip

    info "Команды banip / unbanip доступны в PATH"
    STATUS[12]="ok"
fi

# =================================================================
# [13] Алиас update-all + cleanup
# =================================================================
if [[ "$DO_ALIASES" == "1" ]]; then
    step 13 "Алиас update-all и очистка apt"
    if ! grep -q "update-all" /root/.bashrc 2>/dev/null; then
        echo "alias update-all='apt update && apt upgrade -y && apt autoremove -y && apt clean'" >> /root/.bashrc
    fi
    apt-get autoremove -y -q > /dev/null
    apt-get clean > /dev/null
    info "Алиас добавлен, apt очищен"
    STATUS[13]="ok"
fi

# =================================================================
# [14] Установка Telemt
# =================================================================
if [[ "$DO_TELEMT" == "1" ]]; then
    step 14 "Установка Telemt"
    # Тихая установка с базовыми параметрами. Финальный конфиг зальём ниже.
    if curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | \
        sh -s -- -l ru -d "$TELEMT_DOMAIN" -p "$TELEMT_PORT"; then
        info "Telemt установлен"
        STATUS[14]="ok"
    else
        err "Установка Telemt завершилась с ошибкой"
        STATUS[14]="fail"
    fi
fi

# =================================================================
# [15] Drop-in LimitNOFILE для telemt
# =================================================================
if [[ "$DO_TELEMT_LIMITS" == "1" && -f /etc/systemd/system/telemt.service ]]; then
    step 15 "Drop-in LimitNOFILE=1048576 для telemt"
    mkdir -p /etc/systemd/system/telemt.service.d
    cat > /etc/systemd/system/telemt.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
    systemctl daemon-reload
    info "LimitNOFILE=1048576 применён через drop-in"
    STATUS[15]="ok"
elif [[ "$DO_TELEMT_LIMITS" == "1" ]]; then
    warn "telemt.service не найден, drop-in не создан"
    STATUS[15]="skip"
fi

# =================================================================
# [16] Кастомный config.toml для telemt
# =================================================================
if [[ "$DO_TELEMT_CONF" == "1" && -d /etc/telemt ]]; then
    step 16 "Заливаю кастомный конфиг telemt"

    # Secret уже сгенерирован в интерактиве — тот же, что показали юзеру для бота
    TELEMT_USER="user1"

    AD_TAG_LINE=""
    if [[ "$AD_TAG_ENABLED" == "1" && -n "$AD_TAG_VALUE" ]]; then
        AD_TAG_LINE="ad_tag = \"${AD_TAG_VALUE}\""
    fi

    cat > /etc/telemt/telemt.toml <<EOF
[general]
log_level = "silent"
me_keepalive_enabled = true
me_keepalive_interval_secs = 25
me_keepalive_jitter_secs = 5
me_hardswap_warmup_delay_min_ms = 500
me_hardswap_warmup_delay_max_ms = 2000
me_hardswap_warmup_extra_passes = 2
me_reconnect_max_concurrent_per_dc = 16
me_adaptive_floor_max_active_writers_per_core = 128
me_adaptive_floor_max_warm_writers_per_core = 128
me_adaptive_floor_max_active_writers_global = 512
me_adaptive_floor_max_warm_writers_global = 512
me_adaptive_floor_max_extra_writers_multi_per_core = 3
me_route_channel_capacity = 4096
me_writer_cmd_channel_capacity = 16384
me_c2me_channel_capacity = 4096
me_route_blocking_send_timeout_ms = 500
me_route_hybrid_max_wait_ms = 5000
${AD_TAG_LINE}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[network]
ipv4 = true
ipv6 = false
prefer = 4
stun_servers = [
  "stun.l.google.com:19302",
  "stun1.l.google.com:19302",
  "stun.cloudflare.com:3478"
]

[server]
port = ${TELEMT_PORT}
listen_addr_ipv4 = "0.0.0.0"
metrics_port = 9090
max_connections = 0
listen_backlog = 65535

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[server.conntrack_control]
enabled = true
mode = "notrack"

[censorship]
tls_domain = "${TELEMT_DOMAIN}"
unknown_sni_action = "reject_handshake"

[access.users]
${TELEMT_USER} = "${TELEMT_SECRET}"
EOF

    # Права как в инсталлере telemt
    chown root:telemt /etc/telemt/telemt.toml 2>/dev/null || true
    chmod 640 /etc/telemt/telemt.toml

    info "Конфиг /etc/telemt/telemt.toml залит (домен: ${TELEMT_DOMAIN}, user: ${TELEMT_USER})"
    STATUS[16]="ok"
elif [[ "$DO_TELEMT_CONF" == "1" ]]; then
    warn "Директория /etc/telemt не найдена — конфиг не залит"
    STATUS[16]="skip"
fi

# =================================================================
# [17] Рестарт telemt
# =================================================================
if [[ "$DO_TELEMT_RESTART" == "1" ]]; then
    step 17 "Перезапуск telemt"
    if systemctl list-unit-files | grep -q '^telemt\.service'; then
        systemctl daemon-reload
        if systemctl restart telemt; then
            sleep 2
            if systemctl is-active --quiet telemt; then
                info "telemt запущен и работает"
                STATUS[17]="ok"
            else
                err "telemt не активен после рестарта (journalctl -u telemt -e)"
                STATUS[17]="fail"
            fi
        else
            err "Не удалось перезапустить telemt"
            STATUS[17]="fail"
        fi
    else
        warn "telemt.service не найден"
        STATUS[17]="skip"
    fi
fi

# =================================================================
# [18] telemt-shaper
# =================================================================
if [[ "$DO_SHAPER" == "1" ]]; then
    step 18 "Установка telemt-shaper"
    if curl -fsSL https://raw.githubusercontent.com/lie-must-die/telemt-shaper/main/install.sh | bash; then
        info "telemt-shaper установлен"
        STATUS[18]="ok"
    else
        err "Не удалось установить telemt-shaper"
        STATUS[18]="fail"
    fi
fi

# =================================================================
# ФИНАЛЬНЫЙ ВЫВОД
# =================================================================
echo
echo -e "${C_GREEN}${C_BOLD}=================================================================="
echo -e "                    ✅ УСТАНОВКА ЗАВЕРШЕНА"
echo -e "==================================================================${C_RESET}"

fmt_status() {
    case "$1" in
        ok)      echo -e "${C_GREEN}✓${C_RESET}" ;;
        partial) echo -e "${C_YELLOW}~${C_RESET}" ;;
        fail)    echo -e "${C_RED}✗${C_RESET}" ;;
        skip)    echo -e "${C_YELLOW}—${C_RESET}" ;;
        *)       echo "?" ;;
    esac
}

echo
echo -e "${C_BOLD}🔧 ЧТО СДЕЛАНО:${C_RESET}"
echo -e "  $(fmt_status "${STATUS[1]}") [1]  Пакеты и обновления"
echo -e "  $(fmt_status "${STATUS[2]}") [2]  SSH (порт ${SSH_PORT})"
echo -e "  $(fmt_status "${STATUS[3]}") [3]  MOTD"
echo -e "  $(fmt_status "${STATUS[4]}") [4]  Journald лимиты"
echo -e "  $(fmt_status "${STATUS[5]}") [5]  ulimits (1048576)"
echo -e "  $(fmt_status "${STATUS[6]}") [6]  sysctl (BBR, IPv6 off)"
echo -e "  $(fmt_status "${STATUS[7]}") [7]  DNS Cloudflare Security"
echo -e "  $(fmt_status "${STATUS[8]}") [8]  clear-iface-dns"
echo -e "  $(fmt_status "${STATUS[9]}") [9]  Firewall (nftables)"
echo -e "  $(fmt_status "${STATUS[10]}") [10] Fail2ban"
echo -e "  $(fmt_status "${STATUS[11]}") [11] Геоблок"
echo -e "  $(fmt_status "${STATUS[12]}") [12] Алиас banip/unbanip"
echo -e "  $(fmt_status "${STATUS[13]}") [13] update-all + apt clean"
echo -e "  $(fmt_status "${STATUS[14]}") [14] Telemt"
echo -e "  $(fmt_status "${STATUS[15]}") [15] Telemt LimitNOFILE"
echo -e "  $(fmt_status "${STATUS[16]}") [16] Telemt config.toml"
echo -e "  $(fmt_status "${STATUS[17]}") [17] Telemt restart"
echo -e "  $(fmt_status "${STATUS[18]}") [18] Telemt-shaper"

# Ссылка на прокси через API
echo
echo -e "${C_BOLD}🔗 ССЫЛКА НА ПРОКСИ:${C_RESET}"
LINK=""
if systemctl is-active --quiet telemt 2>/dev/null; then
    sleep 1
    LINK=$(curl -s --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null | \
        jq -r '.data[]? | .links.tls[]? // empty' 2>/dev/null | head -n1)
fi

if [[ -n "$LINK" ]]; then
    echo "  $LINK"
else
    echo -e "  ${C_YELLOW}Ссылка пока недоступна.${C_RESET} Получить после старта telemt:"
    echo "  curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[]?'"
fi

# Полезные команды
cat <<EOF

${C_BOLD}📋 ПОЛЕЗНЫЕ КОМАНДЫ:${C_RESET}

  ${C_CYAN}# Telemt${C_RESET}
  systemctl status telemt
  journalctl -u telemt -f

  ${C_CYAN}# Telemt API (метрики)${C_RESET}
  curl -s http://127.0.0.1:9091/v1/stats/summary    | jq .   # сводка
  curl -s http://127.0.0.1:9091/v1/system/info      | jq .   # версия, uptime
  curl -s http://127.0.0.1:9091/v1/stats/upstreams  | jq .   # здоровье DC
  curl -s http://127.0.0.1:9091/v1/users            | jq -r '.data[] | "[\(.username)]", (.links.tls[]? | "tls: \(.)"), ""'

  ${C_CYAN}# Telemt-shaper${C_RESET}
  journalctl -u telemt-shaper -f         # логи в реальном времени
  tail -f /var/log/telemt-shaper.log     # события шейпа
  systemctl restart telemt-shaper        # graceful рестарт

  ${C_CYAN}# Firewall (nftables)${C_RESET}
  nft list ruleset                                   # все правила
  nft list set inet filter blacklist_v4              # ручной бан-лист
  nft list set inet filter geoblock_v4 | head        # геоблок
  banip 1.2.3.4                                      # забанить IP
  unbanip 1.2.3.4                                    # разбанить IP
  /usr/local/sbin/nft-geoblock-update                # обновить геоблок вручную

  ${C_CYAN}# Fail2ban${C_RESET}
  fail2ban-client status
  fail2ban-client status sshd

  ${C_CYAN}# Система${C_RESET}
  update-all                         # apt update + upgrade + autoremove + clean

EOF

echo -e "${C_BOLD}${C_YELLOW}⚠  Не забудь задать пароль root:${C_RESET} passwd root"
if [[ "${STATUS[2]}" == "ok" && "$SSH_PORT" != "22" ]]; then
    echo -e "${C_BOLD}${C_YELLOW}⚠  SSH теперь на порту ${SSH_PORT}.${C_RESET} Не закрывай текущую сессию пока не проверишь вход!"
fi
echo
echo -e "${C_GREEN}${C_BOLD}==================================================================${C_RESET}"
