#!/usr/bin/env bash

BIN_PATH="/usr/local/bin/mtg"
PY_DIR="/opt/mtprotoproxy"
CONFIG_DIR="/etc/mtg"

check_root() {
    [[ "$(id -u)" != "0" ]] && echo "错误: 请以 root 运行！" && exit 1
}

check_init_system() {
    [[ ! -f /usr/bin/systemctl ]] && echo "错误: 仅支持 Systemd。" && exit 1
}

open_port() {
    local PORT=$1
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent && firewall-cmd --reload
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${PORT}/tcp
    fi
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
}

install_mtp() {
    echo "1) Go 版 (9seconds)"
    echo "2) Python 版 (alexbers)"
    read -p "选择 [1-2]: " core_choice
    [[ "$core_choice" == "2" ]] && install_py || install_go
}

install_go() {
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    VERSION=${VERSION:-"v2.1.7"}
    wget -qO- "https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VERSION#v}-linux-${ARCH}.tar.gz" | tar xz -C /tmp
    mv /tmp/mtg-*/mtg "$BIN_PATH" && chmod +x "$BIN_PATH"
    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (默认: azure.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-azure.microsoft.com}
    SECRET=$($BIN_PATH generate-secret --hex "$DOMAIN")
    read -p "端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}
    echo -e "CORE=GO\nPORT=${PORT}\nSECRET=${SECRET}\nDOMAIN=${DOMAIN}" > "${CONFIG_DIR}/config"
    rm -rf "$PY_DIR"
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy (Go)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -b 0.0.0.0:${PORT} ${SECRET} --domain ${DOMAIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable mtg && systemctl restart mtg
    if ! systemctl is-active --quiet mtg; then
        echo "启动失败，请检查日志：journalctl -u mtg -e"
        exit 1
    fi
    open_port "$PORT"
    show_info
}

install_py() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "Python 版仅支持 Debian/Ubuntu。" && exit 1
    fi
    apt-get update && apt-get install -y python3-dev python3-pip git xxd python3-cryptography
    rm -rf "$PY_DIR"
    git clone https://github.com/alexbers/mtprotoproxy.git "$PY_DIR"
    pip3 install pycryptodome uvloop --break-system-packages
    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (默认: azure.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-azure.microsoft.com}
    RAW_S=$(head -c 16 /dev/urandom | xxd -ps -c 16 | tr -d '[:space:]')
    D_HEX=$(echo -n "$DOMAIN" | xxd -p -c 256 | tr -d '[:space:]')
    read -p "端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}
    echo -e "CORE=PY\nPORT=${PORT}\nSECRET=ee${RAW_S}${D_HEX}\nDOMAIN=${DOMAIN}" > "${CONFIG_DIR}/config"
    cat > ${PY_DIR}/config.py <<EOF
PORT = ${PORT}
USERS = {"tg": "ee${RAW_S}${D_HEX}"}
DOMAIN = "${DOMAIN}"
EOF
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy (Python)
After=network.target

[Service]
Type=simple
WorkingDirectory=${PY_DIR}
ExecStart=/usr/bin/python3 mtprotoproxy.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable mtg && systemctl restart mtg
    if ! systemctl is-active --quiet mtg; then
        echo "启动失败，请检查日志：journalctl -u mtg -e"
        exit 1
    fi
    open_port "$PORT"
    show_info
}

show_info() {
    source "${CONFIG_DIR}/config"
    IP4=$(curl -fs4 --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null || curl -fs4 --connect-timeout 3 --max-time 5 ipinfo.io/ip 2>/dev/null || true)
    IP6=""
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        IP6=$(curl -fs6 --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null || curl -fs6 --connect-timeout 3 --max-time 5 icanhazip.com 2>/dev/null || true)
    fi
    echo -e "\n======= MTProxy 链接信息 (${CORE}版) ======="
    echo "代理端口: ${PORT} | 伪装域名: ${DOMAIN}"
    echo "代理密钥: ${SECRET}"
    [[ -n "$IP4" ]] && echo "IPv4 链接: tg://proxy?server=${IP4}&port=${PORT}&secret=${SECRET}"
    [[ -n "$IP6" ]] && echo "IPv6 链接: tg://proxy?server=[${IP6}]&port=${PORT}&secret=${SECRET}"
    echo "========================================"
}

check_root
check_init_system
install_mtp
