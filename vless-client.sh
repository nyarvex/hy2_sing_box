#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  多协议代理一键部署脚本 v3.0.2 [客户端]
#  支持协议: VLESS+Reality / VLESS+Reality+XHTTP / VLESS+WS / VMess+WS / 
#           VLESS-XTLS-Vision / SOCKS5 / SS2022 / HY2 / Trojan / 
#           AnyTLS / TUIC / SS2022+ShadowTLS (共12种)
#  适配: Alpine/Debian/Ubuntu/CentOS
#  核心特性: 
#    - TUN网卡模式 / 全局代理模式 / SOCKS5代理模式
#    - 节点管理 / 多节点切换
#  
#  作者: Chil30
#  项目地址: https://github.com/Chil30/vless-all-in-one
#═══════════════════════════════════════════════════════════════════════════════

readonly VERSION="3.0.2"
readonly AUTHOR="Chil30"
readonly REPO_URL="https://github.com/Chil30/vless-all-in-one"
readonly CFG="/etc/vless-reality"
readonly SOCKS_PORT="10808"
readonly REDIR_PORT="10809"
readonly TUN_IP="10.0.85.1"
readonly TUN_GW="10.0.85.2"
readonly FWMARK="255"

# 颜色
R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; W='\e[97m'; D='\e[2m'; NC='\e[0m'
set -o pipefail

# 系统检测
if [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
elif [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
elif [[ -f /etc/lsb-release ]] && grep -q "Ubuntu" /etc/lsb-release; then
    DISTRO="ubuntu"
elif [[ -f /etc/os-release ]] && grep -q "Ubuntu" /etc/os-release; then
    DISTRO="ubuntu"
else
    DISTRO="debian"
fi

#═══════════════════════════════════════════════════════════════════════════════
# 协议管理
#═══════════════════════════════════════════════════════════════════════════════
XRAY_PROTOCOLS="vless vless-xhttp vless-ws vmess-ws vless-vision trojan socks ss2022"
INDEPENDENT_PROTOCOLS="hy2 tuic anytls ss2022-shadowtls"

register_protocol() {
    local protocol=$1
    mkdir -p "$CFG"
    echo "$protocol" >> "$CFG/installed_protocols"
    sort -u "$CFG/installed_protocols" -o "$CFG/installed_protocols" 2>/dev/null
}

unregister_protocol() {
    local protocol=$1
    [[ -f "$CFG/installed_protocols" ]] && sed -i "/^$protocol$/d" "$CFG/installed_protocols"
}

get_installed_protocols() {
    [[ -f "$CFG/installed_protocols" ]] && cat "$CFG/installed_protocols" || echo ""
}

is_protocol_installed() {
    local protocol=$1
    [[ -f "$CFG/installed_protocols" ]] && grep -q "^$protocol$" "$CFG/installed_protocols"
}

#═══════════════════════════════════════════════════════════════════════════════
# 基础工具函数
#═══════════════════════════════════════════════════════════════════════════════
_line()  { echo -e "${D}─────────────────────────────────────────────${NC}"; }
_dline() { echo -e "${C}═════════════════════════════════════════════${NC}"; }
_info()  { echo -e "  ${C}▸${NC} $1"; }
_ok()    { echo -e "  ${G}✓${NC} $1"; }
_err()   { echo -e "  ${R}✗${NC} $1"; }
_warn()  { echo -e "  ${Y}!${NC} $1"; }
_item()  { echo -e "  ${G}$1${NC}) $2"; }
_pause() { echo ""; read -rp "  按回车继续..."; }

_header() {
    clear; echo ""
    _dline
    echo -e "      ${W}多协议代理${NC} ${D}一键部署${NC} ${C}v${VERSION}${NC} ${Y}[客户端]${NC}"
    echo -e "      ${D}作者: ${AUTHOR}  快捷命令: vlessc${NC}"
    echo -e "      ${D}${REPO_URL}${NC}"
    _dline
}

get_protocol() {
    if [[ -f "$CFG/protocol" ]]; then
        cat "$CFG/protocol"
    else
        echo "vless"
    fi
}

get_protocol_name() {
    case "$1" in
        vless) echo "VLESS+Reality" ;;
        vless-xhttp) echo "VLESS+Reality+XHTTP" ;;
        vless-vision) echo "VLESS-XTLS-Vision" ;;
        vless-ws) echo "VLESS+WS+TLS" ;;
        vmess-ws) echo "VMess+WS" ;;
        ss2022) echo "Shadowsocks 2022" ;;
        hy2) echo "Hysteria2" ;;
        trojan) echo "Trojan" ;;
        tuic) echo "TUIC v5" ;;
        socks) echo "SOCKS5" ;;
        anytls) echo "AnyTLS" ;;
        ss2022-shadowtls) echo "SS2022+ShadowTLS" ;;
        *) echo "未知" ;;
    esac
}

check_root()      { [[ $EUID -ne 0 ]] && { _err "请使用 root 权限运行"; exit 1; }; }
check_cmd()       { command -v "$1" &>/dev/null; }
check_installed() { [[ -d "$CFG" && ( -f "$CFG/config.json" || -f "$CFG/config.yaml" || -f "$CFG/hy2.yaml" || -f "$CFG/config.conf" || -f "$CFG/info" ) ]]; }
get_role()        { [[ -f "$CFG/role" ]] && cat "$CFG/role" || echo ""; }
get_mode()        { [[ -f "$CFG/mode" ]] && cat "$CFG/mode" || echo "tun"; }
is_paused()       { [[ -f "$CFG/paused" ]]; }

get_mode_name() {
    case "$1" in
        tun) echo "TUN网卡" ;;
        global) echo "全局代理" ;;
        socks) echo "SOCKS5代理" ;;
        *) echo "未知" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# 网络工具
#═══════════════════════════════════════════════════════════════════════════════
get_ipv4() { curl -4 -sf --connect-timeout 5 ip.sb 2>/dev/null || curl -4 -sf --connect-timeout 5 ifconfig.me 2>/dev/null; }
get_ipv6() { curl -6 -sf --connect-timeout 5 ip.sb 2>/dev/null || curl -6 -sf --connect-timeout 5 ifconfig.me 2>/dev/null; }
gen_uuid()  { cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' $RANDOM $RANDOM $RANDOM $(($RANDOM&0x0fff|0x4000)) $(($RANDOM&0x3fff|0x8000)) $RANDOM $RANDOM $RANDOM; }

test_connection() {
    _info "验证代理效果..."
    
    # 先检查本地 SOCKS5 代理是否可用
    if ! ss -tlnp 2>/dev/null | grep -q ":$SOCKS_PORT "; then
        _err "本地 SOCKS5 代理未监听 (端口 $SOCKS_PORT)"
        return 1
    fi
    
    local start=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    local result=$(curl -4 -x socks5h://127.0.0.1:$SOCKS_PORT -sf -m 10 ip.sb 2>/dev/null)
    local end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    local latency=$((end - start))
    if [[ -n "$result" ]]; then
         local location=$(curl -4 -x socks5h://127.0.0.1:$SOCKS_PORT -sf -m 5 "http://ip-api.com/line/$result?fields=country" 2>/dev/null)
         _ok "代理已生效!"
         echo -e "  出口IP: ${G}$result${NC} ${D}($location)${NC}  延迟: ${G}${latency}ms${NC}"
    else
         _err "代理连接超时，请检查服务端状态"
         echo -e "  ${D}调试: 检查客户端日志 journalctl -u vless-* -n 20${NC}"
         return 1
    fi
}

test_latency() {
    local ip="$1" port="$2" proto="${3:-tcp}" start end
    start=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    
    # UDP协议无法用TCP测试
    if [[ "$proto" == "hy2" || "$proto" == "tuic" ]]; then
        # 用ping测试基本延迟
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "UDP"
        fi
    else
        # 优先使用 nc (netcat)
        if command -v nc &>/dev/null; then
            if timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null; then
                end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
                echo "$((end-start))ms"
            else
                echo "超时"
            fi
        elif timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "超时"
        fi
    fi
}


#═══════════════════════════════════════════════════════════════════════════════
# 强力清理
#═══════════════════════════════════════════════════════════════════════════════
force_cleanup() {
    svc stop vless-watchdog 2>/dev/null
    svc stop vless-tun 2>/dev/null
    svc stop vless-global 2>/dev/null
    svc stop vless-reality 2>/dev/null
    svc stop vless-ss2022-shadowtls 2>/dev/null
    killall tun2socks xray hysteria snell-server tuic-server shadow-tls anytls-client 2>/dev/null
    ip link del tun0 2>/dev/null
    while ip rule show | grep -q "lookup 55"; do ip rule del lookup 55 2>/dev/null; done
    ip route flush table 55 2>/dev/null
    rm -f /tmp/vless-tun-info /tmp/vless-tun-routes
    
    iptables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null
    iptables -t nat -F VLESS_PROXY 2>/dev/null
    iptables -t nat -X VLESS_PROXY 2>/dev/null
    ip6tables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null
    ip6tables -t nat -F VLESS_PROXY 2>/dev/null
    ip6tables -t nat -X VLESS_PROXY 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
# 服务管理抽象层
#═══════════════════════════════════════════════════════════════════════════════
svc() {
    local action=$1 name=$2
    if [[ "$DISTRO" == "alpine" ]]; then
        case $action in
            start)   rc-service "$name" start 2>/dev/null ;;
            stop)    rc-service "$name" stop 2>/dev/null ;;
            restart) rc-service "$name" restart 2>/dev/null ;;
            enable)  rc-update add "$name" default 2>/dev/null ;;
            disable) rc-update del "$name" default 2>/dev/null ;;
            status)  rc-service "$name" status 2>/dev/null ;;
        esac
    else
        case $action in
            start)   systemctl start "$name" 2>/dev/null ;;
            stop)    systemctl stop "$name" 2>/dev/null ;;
            restart) systemctl restart "$name" 2>/dev/null ;;
            enable)  systemctl enable "$name" 2>/dev/null ;;
            disable) systemctl disable "$name" 2>/dev/null ;;
            status)  systemctl is-active "$name" 2>/dev/null ;;
        esac
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 依赖安装
#═══════════════════════════════════════════════════════════════════

install_deps() {
    _info "安装依赖..."
    case "$DISTRO" in
        alpine)
            apk update >/dev/null 2>&1
            apk add --no-cache curl jq openssl iproute2 iptables ip6tables ca-certificates tar gzip unzip >/dev/null 2>&1
            ;;
        centos)
            yum install -y curl jq openssl iproute iptables ca-certificates tar gzip unzip >/dev/null 2>&1
            ;;
        *)
            apt-get update >/dev/null 2>&1
            apt-get install -y curl jq openssl iproute2 iptables ca-certificates tar gzip unzip >/dev/null 2>&1
            ;;
    esac
    _ok "依赖安装完成"
}

#═══════════════════════════════════════════════════════════════════════════════
# 二进制下载
#═══════════════════════════════════════════════════════════════════════════════
download_xray() {
    [[ -f /usr/local/bin/xray ]] && return 0
    _info "下载 Xray..."
    
    local arch=$(uname -m) xarch
    case $arch in
        x86_64)  xarch="64" ;;
        aarch64) xarch="arm64-v8a" ;;
        armv7l)  xarch="arm32-v7a" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xarch}.zip"
    local tmp=$(mktemp -d)
    
    if curl -sLo "$tmp/xray.zip" --connect-timeout 30 "$url"; then
        if unzip -oq "$tmp/xray.zip" -d "$tmp/"; then
            install -m 755 "$tmp/xray" /usr/local/bin/xray
            mkdir -p /usr/local/share/xray
            [[ -f "$tmp/geoip.dat" ]] && install -m 644 "$tmp/geoip.dat" /usr/local/share/xray/
            [[ -f "$tmp/geosite.dat" ]] && install -m 644 "$tmp/geosite.dat" /usr/local/share/xray/
            rm -rf "$tmp"
            _ok "Xray 下载完成"
            return 0
        fi
    fi
    rm -rf "$tmp"
    _err "Xray 下载失败"
    return 1
}

download_tun2socks() {
    [[ -x /usr/local/bin/tun2socks ]] && return 0
    _info "下载 tun2socks..."
    
    local arch=$(uname -m) t2s_arch
    case $arch in
        x86_64)  t2s_arch="amd64" ;;
        aarch64) t2s_arch="arm64" ;;
        armv7l)  t2s_arch="armv7" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    local tmp=$(mktemp -d)
    if curl -sLo "$tmp/t2s.zip" --connect-timeout 60 "https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-${t2s_arch}.zip"; then
        unzip -oq "$tmp/t2s.zip" -d "$tmp/" 2>/dev/null
        local bin=$(find "$tmp" -name "tun2socks*" -type f | head -1)
        if [[ -n "$bin" ]]; then
            mv "$bin" /usr/local/bin/tun2socks
            chmod +x /usr/local/bin/tun2socks
            rm -rf "$tmp"
            _ok "tun2socks 下载完成"
            return 0
        fi
    fi
    rm -rf "$tmp"
    _err "tun2socks 下载失败"
    return 1
}

download_hysteria() {
    [[ -f /usr/local/bin/hysteria ]] && return 0
    _info "下载 Hysteria2..."
    
    local arch=$(uname -m) harch
    case $arch in
        x86_64)  harch="amd64" ;;
        aarch64) harch="arm64" ;;
        armv7l)  harch="armv7" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    if curl -sLo /usr/local/bin/hysteria --connect-timeout 60 "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${harch}"; then
        chmod +x /usr/local/bin/hysteria
        _ok "Hysteria2 下载完成"
        return 0
    fi
    _err "Hysteria2 下载失败"
    return 1
}

download_tuic() {
    [[ -f /usr/local/bin/tuic-client ]] && return 0
    _info "下载 TUIC..."
    
    local arch=$(uname -m) tarch
    case $arch in
        x86_64)  tarch="x86_64-unknown-linux-gnu" ;;
        aarch64) tarch="aarch64-unknown-linux-gnu" ;;
        armv7l)  tarch="armv7-unknown-linux-gnueabihf" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    if curl -sLo /usr/local/bin/tuic-client --connect-timeout 60 "https://github.com/EAimTY/tuic/releases/download/tuic-client-1.0.0/tuic-client-1.0.0-${tarch}"; then
        chmod +x /usr/local/bin/tuic-client
        _ok "TUIC 下载完成"
        return 0
    fi
    _err "TUIC 下载失败"
    return 1
}

download_anytls() {
    [[ -f /usr/local/bin/anytls-client ]] && return 0
    _info "下载 AnyTLS..."
    
    local arch=$(uname -m) aarch
    case $arch in
        x86_64)  aarch="amd64" ;;
        aarch64) aarch="arm64" ;;
        armv7l)  aarch="armv7" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    local tmp=$(mktemp -d)
    local version="v0.0.11"
    if curl -sLo "$tmp/anytls.zip" --connect-timeout 60 "https://github.com/anytls/anytls-go/releases/download/${version}/anytls_${version#v}_linux_${aarch}.zip"; then
        unzip -oq "$tmp/anytls.zip" -d "$tmp/" 2>/dev/null
        install -m 755 "$tmp/anytls-client" /usr/local/bin/anytls-client
        rm -rf "$tmp"
        _ok "AnyTLS 下载完成"
        return 0
    fi
    rm -rf "$tmp"
    _err "AnyTLS 下载失败"
    return 1
}

download_shadowtls() {
    [[ -f /usr/local/bin/shadow-tls ]] && return 0
    _info "下载 ShadowTLS..."
    
    local arch=$(uname -m) aarch
    case $arch in
        x86_64)  aarch="x86_64-unknown-linux-musl" ;;
        aarch64) aarch="aarch64-unknown-linux-musl" ;;
        armv7l)  aarch="armv7-unknown-linux-musleabihf" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac
    
    local version="v0.2.25"
    if curl -sLo /usr/local/bin/shadow-tls --connect-timeout 60 "https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${aarch}"; then
        chmod +x /usr/local/bin/shadow-tls
        _ok "ShadowTLS 下载完成"
        return 0
    fi
    _err "ShadowTLS 下载失败"
    return 1
}


#═══════════════════════════════════════════════════════════════════════════════
# 客户端配置生成 (支持所有协议)
#═══════════════════════════════════════════════════════════════════════════════
gen_client_config() {
    local protocol_type="$1"
    shift
    local mode=$(get_mode)
    mkdir -p "$CFG"

    local inbounds='[{"port": '$SOCKS_PORT', "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": true}}]'
    [[ "$mode" == "global" ]] && inbounds='[
        {"port": '$SOCKS_PORT', "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": true}},
        {"port": '$REDIR_PORT', "listen": "::", "protocol": "dokodemo-door", "settings": {"network": "tcp,udp", "followRedirect": true}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}}
    ]'

    local sockopt_json=""
    if [[ "$mode" == "tun" ]]; then
        sockopt_json='"sockopt": {"mark": '$FWMARK', "tcpKeepAliveIdle": 100},'
    fi

    case "$protocol_type" in
        vless)
            local ip="$1" port="$2" uuid="$3" pubkey="$4" sid="$5" sni="$6"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "tcp", "security": "reality",
            "realitySettings": {"show": false, "fingerprint": "chrome", "serverName": "$sni", "publicKey": "$pubkey", "shortId": "$sid", "spiderX": ""}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vless
server_ip=$ip
port=$port
uuid=$uuid
public_key=$pubkey
short_id=$sid
sni=$sni
EOF
            ;;
        vless-xhttp)
            local ip="$1" port="$2" uuid="$3" pubkey="$4" sid="$5" sni="$6" path="${7:-/}"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "xhttp",
            "xhttpSettings": {"path": "$path", "mode": "auto"},
            "security": "reality",
            "realitySettings": {"show": false, "fingerprint": "chrome", "serverName": "$sni", "publicKey": "$pubkey", "shortId": "$sid", "spiderX": ""}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vless-xhttp
server_ip=$ip
port=$port
uuid=$uuid
public_key=$pubkey
short_id=$sid
sni=$sni
path=$path
EOF
            ;;
        vless-ws)
            local ip="$1" port="$2" uuid="$3" sni="$4" path="${5:-/vless}"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "ws",
            "security": "tls",
            "tlsSettings": {"allowInsecure": true, "serverName": "$sni"},
            "wsSettings": {"path": "$path", "headers": {"Host": "$sni"}}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vless-ws
server_ip=$ip
port=$port
uuid=$uuid
sni=$sni
path=$path
EOF
            ;;
        vless-grpc)
            local ip="$1" port="$2" uuid="$3" sni="$4" service_name="${5:-grpc}"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "grpc",
            "security": "tls",
            "tlsSettings": {"allowInsecure": true, "serverName": "$sni", "alpn": ["h2"]},
            "grpcSettings": {"serviceName": "$service_name"}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vless-grpc
server_ip=$ip
port=$port
uuid=$uuid
sni=$sni
path=$service_name
EOF
            ;;
        vless-vision)
            local ip="$1" port="$2" uuid="$3" sni="$4"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {"allowInsecure": true, "serverName": "$sni", "alpn": ["h2", "http/1.1"]}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vless-vision
server_ip=$ip
port=$port
uuid=$uuid
sni=$sni
EOF
            ;;
        vmess-ws)
            local ip="$1" port="$2" uuid="$3" sni="$4" path="${5:-/vmess}"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "vmess",
        "settings": {"vnext": [{"address": "$ip", "port": $port, "users": [{"id": "$uuid", "alterId": 0, "security": "auto"}]}]},
        "streamSettings": {
            $sockopt_json
            "network": "ws",
            "security": "tls",
            "tlsSettings": {"allowInsecure": true, "serverName": "$sni"},
            "wsSettings": {"path": "$path", "headers": {"Host": "$sni"}}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=vmess-ws
server_ip=$ip
port=$port
uuid=$uuid
sni=$sni
path=$path
EOF
            ;;
        socks)
            local ip="$1" port="$2" username="$3" password="$4"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "socks",
        "settings": {"servers": [{"address": "$ip", "port": $port, "users": [{"user": "$username", "pass": "$password"}]}]}
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=socks
server_ip=$ip
port=$port
username=$username
password=$password
EOF
            ;;
        ss2022)
            local ip="$1" port="$2" method="$3" password="$4"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "shadowsocks",
        "settings": {"servers": [{"address": "$ip", "port": $port, "method": "$method", "password": "$password"}]}
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=ss2022
server_ip=$ip
port=$port
method=$method
password=$password
EOF
            ;;
        trojan)
            local ip="$1" port="$2" password="$3" sni="$4"
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "trojan",
        "settings": {"servers": [{"address": "$ip", "port": $port, "password": "$password"}]},
        "streamSettings": {
            $sockopt_json
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {"allowInsecure": true, "serverName": "$sni"}
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=trojan
server_ip=$ip
port=$port
password=$password
sni=$sni
EOF
            ;;
        hy2)
            local ip="$1" port="$2" password="$3" sni="$4"
            cat > "$CFG/hy2.yaml" << EOF
server: $ip:$port
auth: $password
tls:
  sni: $sni
  insecure: true
socks5:
  listen: 127.0.0.1:$SOCKS_PORT
EOF
            cat > "$CFG/info" << EOF
protocol=hy2
server_ip=$ip
port=$port
password=$password
sni=$sni
EOF
            ;;
        snell)
            local ip="$1" port="$2" psk="$3" version="${4:-4}"
            cat > "$CFG/config.conf" << EOF
[snell-client]
server = $ip
port = $port
psk = $psk
version = $version
EOF
            cat > "$CFG/info" << EOF
protocol=snell
server_ip=$ip
port=$port
psk=$psk
version=$version
EOF
            _warn "Snell 客户端需要 Surge/Clash 等软件支持"
            ;;
        tuic)
            local ip="$1" port="$2" uuid="$3" password="$4" sni="$5" cert_path="${6:-}"
            local clean_ip=$(echo "$ip" | tr -d '[]')
            [[ -z "$cert_path" ]] && cert_path="$CFG/certs/server.crt"
            cat > "$CFG/config.json" << EOF
{
    "relay": {
        "server": "$clean_ip:$port",
        "uuid": "$uuid",
        "password": "$password",
        "congestion_control": "bbr",
        "alpn": ["h3"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": false,
        "certificates": ["$cert_path"]
    },
    "local": {
        "server": "127.0.0.1:$SOCKS_PORT"
    },
    "log_level": "info"
}
EOF
            cat > "$CFG/info" << EOF
protocol=tuic
server_ip=$ip
port=$port
uuid=$uuid
password=$password
sni=$sni
cert_path=$cert_path
EOF
            ;;
        anytls)
            local ip="$1" port="$2" password="$3" sni="$4"
            cat > "$CFG/info" << EOF
protocol=anytls
server_ip=$ip
port=$port
password=$password
sni=$sni
EOF
            ;;
        ss2022-shadowtls)
            local ip="$1" port="$2" method="$3" password="$4" stls_password="$5" sni="$6"
            local ss_backend_port="18388"
            
            # 生成 Xray SS2022 配置 (连接到本地 shadow-tls)
            cat > "$CFG/config.json" << EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": $inbounds,
    "outbounds": [{
        "protocol": "shadowsocks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": $ss_backend_port, "method": "$method", "password": "$password"}]},
        "streamSettings": {
            $sockopt_json
            "network": "tcp"
        }
    }]
}
EOF
            cat > "$CFG/info" << EOF
protocol=ss2022-shadowtls
server_ip=$ip
port=$port
method=$method
password=$password
stls_password=$stls_password
sni=$sni
ss_backend_port=$ss_backend_port
EOF
            ;;
    esac
    
    echo "client" > "$CFG/role"
    echo "$protocol_type" > "$CFG/protocol"
    register_protocol "$protocol_type"
}


#═══════════════════════════════════════════════════════════════════════════════
# 辅助脚本生成 (客户端专用)
#═══════════════════════════════════════════════════════════════════════════════
create_scripts() {
    cat > "$CFG/tun-up.sh" << EOFSCRIPT
#!/bin/bash
set -e
CFG="/etc/vless-reality"
TUN_IP="$TUN_IP"; TUN_GW="$TUN_GW"
FWMARK="$FWMARK"

ip link del tun0 2>/dev/null || true
ip route flush table 55 2>/dev/null || true
while ip rule show | grep -q "lookup 55"; do ip rule del lookup 55 2>/dev/null || true; done

mkdir -p /dev/net
[[ ! -c /dev/net/tun ]] && mknod /dev/net/tun c 10 200 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/ip_forward
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "\$f"; done

DEF_GW=\$(ip -4 route show default | grep default | head -1 | awk '{print \$3}')
DEF_DEV=\$(ip -4 route show default | grep default | head -1 | awk '{print \$5}')
LOCAL_IP=\$(ip -4 addr show dev "\$DEF_DEV" | grep "inet " | awk '{print \$2}' | cut -d/ -f1 | head -1)

if [[ -z "\$DEF_GW" || -z "\$DEF_DEV" || -z "\$LOCAL_IP" ]]; then echo "错误：无法获取物理网络信息"; exit 1; fi
echo "\$DEF_GW|\$DEF_DEV|\$LOCAL_IP" > /tmp/vless-tun-info

ip tuntap add mode tun dev tun0
ip link set dev tun0 up mtu 1280
ip -4 addr add \$TUN_IP/30 dev tun0

ip route add default via "\$DEF_GW" dev "\$DEF_DEV" table 55
ip rule add fwmark \$FWMARK lookup 55 pref 900
ip rule add from "\$LOCAL_IP" lookup 55 pref 1000

SERVER_IP=\$(grep "server_ip=" "\$CFG/info" 2>/dev/null | cut -d= -f2 | tr -d '[]')
if [[ -n "\$SERVER_IP" ]]; then
    if [[ "\$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip -4 route add "\$SERVER_IP" via "\$DEF_GW" dev "\$DEF_DEV" 2>/dev/null || true
        echo "\$SERVER_IP" > /tmp/vless-tun-routes
    fi
fi

ip -4 route add 0.0.0.0/1 via \$TUN_GW dev tun0
ip -4 route add 128.0.0.0/1 via \$TUN_GW dev tun0
echo "TUN 模式启动成功"
EOFSCRIPT

    cat > "$CFG/tun-down.sh" << EOFSCRIPT
#!/bin/bash
CFG="/etc/vless-reality"
TUN_GW="$TUN_GW"
FWMARK="$FWMARK"

ip -4 route del 0.0.0.0/1 via \$TUN_GW dev tun0 2>/dev/null || true
ip -4 route del 128.0.0.0/1 via \$TUN_GW dev tun0 2>/dev/null || true

if [[ -f /tmp/vless-tun-info ]]; then
    IFS='|' read -r DEF_GW DEF_DEV LOCAL_IP < /tmp/vless-tun-info
    ip rule del fwmark \$FWMARK lookup 55 2>/dev/null || true
    if [[ -n "\$LOCAL_IP" ]]; then ip rule del from "\$LOCAL_IP" lookup 55 2>/dev/null || true; fi
    ip route flush table 55 2>/dev/null || true
    if [[ -f /tmp/vless-tun-routes ]]; then
        while read -r ip; do
            [[ -n "\$ip" ]] && { ip -4 route del "\$ip" via "\$DEF_GW" dev "\$DEF_DEV" 2>/dev/null || true; }
        done < /tmp/vless-tun-routes
    fi
    rm -f /tmp/vless-tun-info /tmp/vless-tun-routes
fi
ip link del tun0 2>/dev/null || true
echo "TUN 已停止"
EOFSCRIPT

    cat > "$CFG/watchdog.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG="/etc/vless-reality"
LOG_FILE="/var/log/vless-watchdog.log"
FAIL_COUNT=0
MAX_FAIL=3

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

restart_service() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$svc"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" restart
    else
        return 1
    fi
}

get_service_info() {
    local proto=$(cat "$CFG/protocol" 2>/dev/null)
    case "$proto" in
        vless|vless-xhttp|vless-ws|vmess-ws|vless-vision|trojan|socks|ss2022)
            echo "vless-reality:xray"
            ;;
        hy2)
            echo "vless-hy2:hysteria"
            ;;
        tuic)
            echo "vless-tuic:tuic-client"
            ;;
        anytls)
            echo "vless-anytls:anytls-client"
            ;;
        ss2022-shadowtls)
            # 返回两个服务信息，用分号分隔
            echo "vless-ss2022-shadowtls:shadow-tls;vless-reality:xray"
            ;;
        *)
            echo "vless-reality:xray"
            ;;
    esac
}

while true; do
    svc_info=$(get_service_info)
    
    # 支持多服务监控 (用分号分隔)
    IFS=';' read -ra services <<< "$svc_info"
    for service in "${services[@]}"; do
        IFS=':' read -r svc_name proc_name <<< "$service"
        if ! pgrep -x "$proc_name" > /dev/null; then
            log "CRITICAL: $proc_name process dead. Restarting $svc_name..."
            restart_service "$svc_name"
            sleep 5
        fi
    done
    
    # 连接测试
    if curl -x socks5://127.0.0.1:10808 -s --connect-timeout 5 https://www.cloudflare.com > /dev/null; then
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "WARNING: Connection failed ($FAIL_COUNT/$MAX_FAIL)"
    fi
    
    if [[ $FAIL_COUNT -ge $MAX_FAIL ]]; then
        log "ERROR: Max failures reached. Restarting services..."
        if [[ -f "$CFG/mode" && "$(cat "$CFG/mode")" == "tun" ]]; then
            restart_service vless-tun
        fi
        # 重启所有相关服务
        for service in "${services[@]}"; do
            IFS=':' read -r svc_name proc_name <<< "$service"
            restart_service "$svc_name"
        done
        FAIL_COUNT=0
        sleep 20
    fi
    
    sleep 60
done
EOFSCRIPT

    cat > "$CFG/global-up.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG="/etc/vless-reality"; REDIR_PORT=10809

if [[ -f "$CFG/info" ]]; then
    PROXY_HOST=$(grep "^server_ip=" "$CFG/info" | cut -d'=' -f2 | tr -d '[]')
else
    PROXY_HOST=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // empty' "$CFG/config.json" 2>/dev/null)
fi

[[ -z "$PROXY_HOST" ]] && { echo "无法获取服务器地址"; exit 1; }

PROXY_IP4=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | sort -u || echo "$PROXY_HOST")
PROXY_IP6=$(getent ahostsv6 "$PROXY_HOST" 2>/dev/null | awk '{print $1}' | sort -u)
iptables -t nat -F VLESS_PROXY 2>/dev/null; iptables -t nat -X VLESS_PROXY 2>/dev/null; iptables -t nat -N VLESS_PROXY
for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do iptables -t nat -A VLESS_PROXY -d $cidr -j RETURN; done
for ip in $PROXY_IP4; do iptables -t nat -A VLESS_PROXY -d "$ip" -j RETURN; done
iptables -t nat -A VLESS_PROXY -p tcp -j REDIRECT --to-ports $REDIR_PORT
iptables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null; iptables -t nat -A OUTPUT -p tcp -j VLESS_PROXY
ip6tables -t nat -F VLESS_PROXY 2>/dev/null; ip6tables -t nat -X VLESS_PROXY 2>/dev/null; ip6tables -t nat -N VLESS_PROXY
for cidr in ::1/128 fe80::/10 fc00::/7; do ip6tables -t nat -A VLESS_PROXY -d $cidr -j RETURN; done
for ip in $PROXY_IP6; do ip6tables -t nat -A VLESS_PROXY -d "$ip" -j RETURN; done
ip6tables -t nat -A VLESS_PROXY -p tcp -j REDIRECT --to-ports $REDIR_PORT
ip6tables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null; ip6tables -t nat -A OUTPUT -p tcp -j VLESS_PROXY
EOFSCRIPT

    cat > "$CFG/global-down.sh" << 'EOFSCRIPT'
#!/bin/bash
iptables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null
iptables -t nat -F VLESS_PROXY 2>/dev/null; iptables -t nat -X VLESS_PROXY 2>/dev/null
ip6tables -t nat -D OUTPUT -p tcp -j VLESS_PROXY 2>/dev/null
ip6tables -t nat -F VLESS_PROXY 2>/dev/null; ip6tables -t nat -X VLESS_PROXY 2>/dev/null
EOFSCRIPT

    chmod +x "$CFG"/*.sh
}


#═══════════════════════════════════════════════════════════════════════════════
# 服务创建 (客户端)
#═══════════════════════════════════════════════════════════════════════════════
create_service() {
    local mode=$(get_mode)
    local protocol=$(get_protocol)
    
    # Xray 服务 (不包括 ss2022-shadowtls，它需要特殊处理)
    if [[ "$protocol" =~ ^(vless|vless-xhttp|vless-ws|vless-grpc|vmess-ws|vless-vision|trojan|socks|ss2022)$ ]]; then
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-reality << 'EOF'
#!/sbin/openrc-run
name="vless-reality"
command="/usr/local/bin/xray"
command_args="run -c /etc/vless-reality/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
EOF
            chmod +x /etc/init.d/vless-reality
        else
            cat > /etc/systemd/system/vless-reality.service << EOF
[Unit]
Description=Xray Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/vless-reality/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # Hysteria2 服务
    if [[ "$protocol" == "hy2" ]]; then
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-hy2 << 'EOF'
#!/sbin/openrc-run
name="vless-hy2"
command="/usr/local/bin/hysteria"
command_args="client -c /etc/vless-reality/hy2.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
EOF
            chmod +x /etc/init.d/vless-hy2
        else
            cat > /etc/systemd/system/vless-hy2.service << EOF
[Unit]
Description=Hysteria2 Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/vless-reality/hy2.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # TUIC 服务
    if [[ "$protocol" == "tuic" ]]; then
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-tuic << 'EOF'
#!/sbin/openrc-run
name="vless-tuic"
command="/usr/local/bin/tuic-client"
command_args="-c /etc/vless-reality/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
EOF
            chmod +x /etc/init.d/vless-tuic
        else
            cat > /etc/systemd/system/vless-tuic.service << EOF
[Unit]
Description=TUIC Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-client -c /etc/vless-reality/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # AnyTLS 服务
    if [[ "$protocol" == "anytls" ]]; then
        local server_ip=$(grep "^server_ip=" "$CFG/info" | cut -d= -f2)
        local port=$(grep "^port=" "$CFG/info" | cut -d= -f2)
        local password=$(grep "^password=" "$CFG/info" | cut -d= -f2)
        local sni=$(grep "^sni=" "$CFG/info" | cut -d= -f2)
        
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-anytls << EOF
#!/sbin/openrc-run
name="vless-anytls"
command="/usr/local/bin/anytls-client"
command_args="-l 127.0.0.1:$SOCKS_PORT -s $server_ip:$port -p $password --sni $sni"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
            chmod +x /etc/init.d/vless-anytls
        else
            cat > /etc/systemd/system/vless-anytls.service << EOF
[Unit]
Description=AnyTLS Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/anytls-client -l 127.0.0.1:$SOCKS_PORT -s $server_ip:$port -p $password --sni $sni
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # SS2022+ShadowTLS 服务 (需要两个服务: shadow-tls 和 xray)
    if [[ "$protocol" == "ss2022-shadowtls" ]]; then
        local server_ip=$(grep "^server_ip=" "$CFG/info" | cut -d= -f2)
        local port=$(grep "^port=" "$CFG/info" | cut -d= -f2)
        local sni=$(grep "^sni=" "$CFG/info" | cut -d= -f2)
        local stls_password=$(grep "^stls_password=" "$CFG/info" | cut -d= -f2)
        local ss_backend_port=$(grep "^ss_backend_port=" "$CFG/info" | cut -d= -f2)
        
        if [[ "$DISTRO" == "alpine" ]]; then
            # ShadowTLS 客户端服务
            cat > /etc/init.d/vless-ss2022-shadowtls << EOF
#!/sbin/openrc-run
name="vless-ss2022-shadowtls"
command="/usr/local/bin/shadow-tls"
command_args="--v3 client --listen 127.0.0.1:$ss_backend_port --server $server_ip:$port --sni $sni --password $stls_password"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
EOF
            chmod +x /etc/init.d/vless-ss2022-shadowtls
            
            # Xray SS 客户端服务 (依赖 ShadowTLS)
            cat > /etc/init.d/vless-reality << 'EOF'
#!/sbin/openrc-run
name="vless-reality"
command="/usr/local/bin/xray"
command_args="run -c /etc/vless-reality/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need vless-ss2022-shadowtls; }
EOF
            chmod +x /etc/init.d/vless-reality
        else
            # ShadowTLS 客户端服务
            cat > /etc/systemd/system/vless-ss2022-shadowtls.service << EOF
[Unit]
Description=ShadowTLS Client for SS2022
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 client --listen 127.0.0.1:$ss_backend_port --server $server_ip:$port --sni $sni --password $stls_password
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            # Xray SS 客户端服务 (依赖 ShadowTLS)
            cat > /etc/systemd/system/vless-reality.service << EOF
[Unit]
Description=Xray SS Client for ShadowTLS
After=network.target vless-ss2022-shadowtls.service
Requires=vless-ss2022-shadowtls.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/vless-reality/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # TUN 模式服务
    if [[ "$mode" == "tun" ]]; then
        # 获取默认网卡名称
        local def_dev=$(ip -4 route show default | grep default | head -1 | awk '{print $5}')
        [[ -z "$def_dev" ]] && def_dev="eth0"
        
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-tun << EOF
#!/sbin/openrc-run
name="vless-tun"
command="/usr/local/bin/tun2socks"
command_args="-device tun0 -proxy socks5://127.0.0.1:$SOCKS_PORT -loglevel silent"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
start_pre() { /etc/vless-reality/tun-up.sh; }
stop_post() { /etc/vless-reality/tun-down.sh; }
EOF
            chmod +x /etc/init.d/vless-tun
        else
            cat > /etc/systemd/system/vless-tun.service << EOF
[Unit]
Description=TUN2SOCKS
After=network.target vless-reality.service

[Service]
Type=simple
ExecStartPre=/etc/vless-reality/tun-up.sh
ExecStart=/usr/local/bin/tun2socks -device tun0 -proxy socks5://127.0.0.1:$SOCKS_PORT -loglevel silent
ExecStopPost=/etc/vless-reality/tun-down.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # 全局代理模式服务
    if [[ "$mode" == "global" ]]; then
        if [[ "$DISTRO" == "alpine" ]]; then
            cat > /etc/init.d/vless-global << 'EOF'
#!/sbin/openrc-run
name="vless-global"
start() { /etc/vless-reality/global-up.sh; }
stop() { /etc/vless-reality/global-down.sh; }
EOF
            chmod +x /etc/init.d/vless-global
        else
            cat > /etc/systemd/system/vless-global.service << 'EOF'
[Unit]
Description=Global Proxy
After=network.target vless-reality.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/vless-reality/global-up.sh
ExecStop=/etc/vless-reality/global-down.sh

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
    fi
    
    # Watchdog 服务
    if [[ "$DISTRO" == "alpine" ]]; then
        cat > /etc/init.d/vless-watchdog << 'EOF'
#!/sbin/openrc-run
name="vless-watchdog"
command="/bin/bash"
command_args="/etc/vless-reality/watchdog.sh"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
EOF
        chmod +x /etc/init.d/vless-watchdog
    else
        cat > /etc/systemd/system/vless-watchdog.service << 'EOF'
[Unit]
Description=VLESS Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/vless-reality/watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}


#═══════════════════════════════════════════════════════════════════════════════
# 服务启动/停止
#═══════════════════════════════════════════════════════════════════════════════
start_services() {
    local protocol=$(get_protocol)
    local mode=$(get_mode)
    
    # 启动主服务
    case "$protocol" in
        vless|vless-xhttp|vless-ws|vmess-ws|vless-vision|trojan|socks|ss2022)
            svc start vless-reality
            svc enable vless-reality
            ;;
        hy2)
            svc start vless-hy2
            svc enable vless-hy2
            ;;
        tuic)
            svc start vless-tuic
            svc enable vless-tuic
            ;;
        anytls)
            svc start vless-anytls
            svc enable vless-anytls
            ;;
        ss2022-shadowtls)
            # 先启动 ShadowTLS，再启动 Xray
            svc start vless-ss2022-shadowtls
            svc enable vless-ss2022-shadowtls
            sleep 1
            svc start vless-reality
            svc enable vless-reality
            ;;
    esac
    
    sleep 2
    
    # 启动代理模式服务
    case "$mode" in
        tun)
            svc start vless-tun
            svc enable vless-tun
            ;;
        global)
            svc start vless-global
            svc enable vless-global
            ;;
    esac
    
    # 启动 watchdog
    svc start vless-watchdog
    svc enable vless-watchdog
    
    return 0
}

stop_services() {
    svc stop vless-watchdog 2>/dev/null
    svc stop vless-tun 2>/dev/null
    svc stop vless-global 2>/dev/null
    svc stop vless-reality 2>/dev/null
    svc stop vless-hy2 2>/dev/null
    svc stop vless-tuic 2>/dev/null
    svc stop vless-anytls 2>/dev/null
    svc stop vless-ss2022-shadowtls 2>/dev/null
    
    force_cleanup
}

restart_services() {
    stop_services
    sleep 2
    start_services
}

#═══════════════════════════════════════════════════════════════════════════════
# 状态显示
#═══════════════════════════════════════════════════════════════════════════════
show_status() {
    local role=$(get_role)
    local protocol=$(get_protocol)
    local mode=$(get_mode)
    
    if [[ "$role" != "client" ]]; then
        echo -e "  ${D}未安装客户端${NC}"
        return
    fi
    
    echo -e "  ${W}当前状态${NC}"
    echo -e "  协议: ${G}$(get_protocol_name $protocol)${NC}"
    echo -e "  模式: ${C}$(get_mode_name $mode)${NC}"
    
    # 检查是否暂停
    if is_paused; then
        echo -e "  状态: ${Y}已暂停${NC}"
    else
        # 检查服务状态
        local svc_status="stopped"
        case "$protocol" in
            vless|vless-xhttp|vless-ws|vmess-ws|vless-vision|trojan|socks|ss2022)
                [[ "$(svc status vless-reality)" == "active" ]] && svc_status="running"
                ;;
            hy2)
                [[ "$(svc status vless-hy2)" == "active" ]] && svc_status="running"
                ;;
            tuic)
                [[ "$(svc status vless-tuic)" == "active" ]] && svc_status="running"
                ;;
            anytls)
                [[ "$(svc status vless-anytls)" == "active" ]] && svc_status="running"
                ;;
            ss2022-shadowtls)
                # 需要两个服务都运行才算正常
                [[ "$(svc status vless-ss2022-shadowtls)" == "active" && "$(svc status vless-reality)" == "active" ]] && svc_status="running"
                ;;
        esac
        
        if [[ "$svc_status" == "running" ]]; then
            echo -e "  状态: ${G}运行中${NC}"
        else
            echo -e "  状态: ${R}已停止${NC}"
        fi
    fi
    
    # 显示服务器信息
    if [[ -f "$CFG/info" ]]; then
        local server_ip=$(grep "^server_ip=" "$CFG/info" | cut -d= -f2)
        local port=$(grep "^port=" "$CFG/info" | cut -d= -f2)
        echo -e "  服务器: ${C}$server_ip:$port${NC}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 节点管理
#═══════════════════════════════════════════════════════════════════════════════
save_node() {
    local name="$1"
    mkdir -p "$CFG/nodes"
    
    if [[ -f "$CFG/info" ]]; then
        cp "$CFG/info" "$CFG/nodes/${name}.info"
        [[ -f "$CFG/config.json" ]] && cp "$CFG/config.json" "$CFG/nodes/${name}.json"
        [[ -f "$CFG/hy2.yaml" ]] && cp "$CFG/hy2.yaml" "$CFG/nodes/${name}.yaml"
        [[ -f "$CFG/config.conf" ]] && cp "$CFG/config.conf" "$CFG/nodes/${name}.conf"
        _ok "节点 [$name] 保存成功"
    else
        _err "没有可保存的配置"
    fi
}

list_nodes() {
    [[ ! -d "$CFG/nodes" ]] && { _warn "没有保存的节点"; return 1; }
    local current=$(cat "$CFG/current_node" 2>/dev/null) i=1
    local has_nodes=false
    for node in "$CFG/nodes"/*; do
        [[ ! -f "$node" ]] && continue
        has_nodes=true
        source "$node"
        local name=$(basename "$node")
        local proto_type="${protocol:-vless}"
        local mark="" latency=$(test_latency "$server_ip" "$port" "$proto_type")
        [[ "$name" == "$current" ]] && mark=" ${G}[当前]${NC}"
        
        local color="${G}"
        [[ "$latency" == "超时" ]] && color="${R}"
        [[ "$latency" == "UDP" ]] && color="${C}"
        [[ "$latency" =~ ^([0-9]+)ms$ && ${BASH_REMATCH[1]} -gt 300 ]] && color="${Y}"
        
        # 显示协议类型
        local proto_short="$proto_type"
        case "$proto_short" in
            vless) proto_short="VLESS" ;;
            vless-xhttp) proto_short="VLESS-XHTTP" ;;
            vless-ws) proto_short="VLESS-WS" ;;
            vless-grpc) proto_short="VLESS-gRPC" ;;
            vless-vision) proto_short="VLESS-Vision" ;;
            vmess-ws) proto_short="VMess-WS" ;;
            ss2022) proto_short="SS2022" ;;
            ss2022-shadowtls) proto_short="SS2022-STLS" ;;
            hy2) proto_short="HY2" ;;
            trojan) proto_short="Trojan" ;;
            snell) proto_short="Snell" ;;
            tuic) proto_short="TUIC" ;;
        esac
        
        printf "  ${G}%2d${NC}) %-20s ${D}[%s]${NC} ${D}(%s:%s)${NC} ${color}%s${NC}%b\n" "$i" "$name" "$proto_short" "$server_ip" "$port" "$latency" "$mark"
        ((i++))
    done
    [[ "$has_nodes" == "false" ]] && { _warn "没有保存的节点"; return 1; }
    return 0
}

switch_node() {
    local node_file="$1"
    [[ ! -f "$node_file" ]] && return 1
    source "$node_file"
    
    _info "切换到节点: $(basename "$node_file")"
    stop_services
    
    # 根据协议调用不同的配置生成
    case "$protocol" in
        vless)
            gen_client_config "vless" "$server_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni"
            ;;
        vless-xhttp)
            gen_client_config "vless-xhttp" "$server_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni" "$path"
            ;;
        vless-vision)
            gen_client_config "vless-vision" "$server_ip" "$port" "$uuid" "$sni"
            ;;
        vless-ws)
            gen_client_config "vless-ws" "$server_ip" "$port" "$uuid" "$sni" "$path"
            ;;
        vless-grpc)
            gen_client_config "vless-grpc" "$server_ip" "$port" "$uuid" "$sni" "$service_name"
            ;;
        vmess-ws)
            gen_client_config "vmess-ws" "$server_ip" "$port" "$uuid" "$sni" "$path"
            ;;
        ss2022)
            gen_client_config "ss2022" "$server_ip" "$port" "$method" "$password"
            ;;
        ss2022-shadowtls)
            gen_client_config "ss2022-shadowtls" "$server_ip" "$port" "$method" "$password" "$stls_password" "$sni"
            ;;
        trojan)
            gen_client_config "trojan" "$server_ip" "$port" "$password" "$sni"
            ;;
        hy2)
            gen_client_config "hy2" "$server_ip" "$port" "$password" "$sni"
            ;;
        snell)
            gen_client_config "snell" "$server_ip" "$port" "$psk" "$version"
            ;;
        tuic)
            gen_client_config "tuic" "$server_ip" "$port" "$uuid" "$password" "$sni" "$cert_path"
            ;;
        *)
            # 兼容旧格式节点 (默认vless)
            gen_client_config "vless" "$server_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni"
            ;;
    esac
    
    echo "$(basename "$node_file")" > "$CFG/current_node"
    start_services && _ok "节点切换完成"
}

select_node() {
    local prompt="$1"
    SELECTED_NODE=""
    if ! list_nodes; then
        _warn "没有保存的节点"
        return 1
    fi
    _line
    echo ""
    local max=$(ls "$CFG/nodes" 2>/dev/null | wc -l)
    read -rp "  $prompt [1-$max]: " choice
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { _err "无效选择"; return 1; }
    local file=$(ls "$CFG/nodes" 2>/dev/null | sed -n "${choice}p")
    [[ -z "$file" ]] && { _err "节点不存在"; return 1; }
    SELECTED_NODE="$CFG/nodes/$file"
    return 0
}

delete_node() {
    select_node "选择要删除的节点" || return
    local name=$(basename "$SELECTED_NODE")
    rm -f "$SELECTED_NODE"
    _ok "节点 [$name] 已删除"
}

manage_nodes() {
    while true; do
        _header
        echo -e "  ${W}节点管理${NC}"
        echo ""
        _line
        _item "1" "查看所有节点"
        _item "2" "保存当前节点"
        _item "3" "切换节点"
        _item "4" "删除节点"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case $choice in
            1) list_nodes ;;
            2) 
                read -rp "  请输入节点名称: " name
                [[ -n "$name" ]] && save_node "$name"
                ;;
            3) 
                select_node "选择要切换的节点" && {
                    switch_node "$SELECTED_NODE"
                    sleep 1
                    test_connection
                }
                ;;
            4) delete_node ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
        _pause
    done
}


#═══════════════════════════════════════════════════════════════════════════════
# JOIN码解析
#═══════════════════════════════════════════════════════════════════════════════
parse_join_code() {
    local code="$1"
    
    # 移除可能的前缀
    code=$(echo "$code" | sed 's/^[A-Z_]*=//')
    
    # 解码 base64
    local decoded=$(echo "$code" | base64 -d 2>/dev/null)
    [[ -z "$decoded" ]] && return 1
    
    # 解析协议类型
    local proto=$(echo "$decoded" | cut -d'|' -f1)
    
    case "$proto" in
        REALITY|VLESS)
            # REALITY|ip|port|uuid|pubkey|sid|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local pubkey=$(echo "$decoded" | cut -d'|' -f5)
            local sid=$(echo "$decoded" | cut -d'|' -f6)
            local sni=$(echo "$decoded" | cut -d'|' -f7)
            gen_client_config "vless" "$ip" "$port" "$uuid" "$pubkey" "$sid" "$sni"
            ;;
        REALITY-XHTTP|VLESS-XHTTP)
            # REALITY-XHTTP|ip|port|uuid|pubkey|sid|sni|path
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local pubkey=$(echo "$decoded" | cut -d'|' -f5)
            local sid=$(echo "$decoded" | cut -d'|' -f6)
            local sni=$(echo "$decoded" | cut -d'|' -f7)
            local path=$(echo "$decoded" | cut -d'|' -f8)
            gen_client_config "vless-xhttp" "$ip" "$port" "$uuid" "$pubkey" "$sid" "$sni" "$path"
            ;;
        VLESS-WS)
            # VLESS-WS|ip|port|uuid|sni|path
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            local path=$(echo "$decoded" | cut -d'|' -f6)
            gen_client_config "vless-ws" "$ip" "$port" "$uuid" "$sni" "$path"
            ;;
        VLESS-GRPC)
            # VLESS-GRPC|ip|port|uuid|sni|serviceName
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            local service=$(echo "$decoded" | cut -d'|' -f6)
            gen_client_config "vless-grpc" "$ip" "$port" "$uuid" "$sni" "$service"
            ;;
        VLESS-VISION)
            # VLESS-VISION|ip|port|uuid|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "vless-vision" "$ip" "$port" "$uuid" "$sni"
            ;;
        VMESS-WS)
            # VMESS-WS|ip|port|uuid|sni|path
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            local path=$(echo "$decoded" | cut -d'|' -f6)
            gen_client_config "vmess-ws" "$ip" "$port" "$uuid" "$sni" "$path"
            ;;
        TROJAN)
            # TROJAN|ip|port|password|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local password=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "trojan" "$ip" "$port" "$password" "$sni"
            ;;
        HY2)
            # HY2|ip|port|password|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local password=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "hy2" "$ip" "$port" "$password" "$sni"
            ;;
        TUIC)
            # TUIC|ip|port|uuid|password|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local uuid=$(echo "$decoded" | cut -d'|' -f4)
            local password=$(echo "$decoded" | cut -d'|' -f5)
            local sni=$(echo "$decoded" | cut -d'|' -f6)
            gen_client_config "tuic" "$ip" "$port" "$uuid" "$password" "$sni"
            ;;
        SOCKS5)
            # SOCKS5|ip|port|username|password
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local username=$(echo "$decoded" | cut -d'|' -f4)
            local password=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "socks" "$ip" "$port" "$username" "$password"
            ;;
        SS2022)
            # SS2022|ip|port|method|password
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local method=$(echo "$decoded" | cut -d'|' -f4)
            local password=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "ss2022" "$ip" "$port" "$method" "$password"
            ;;
        ANYTLS)
            # ANYTLS|ip|port|password|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local password=$(echo "$decoded" | cut -d'|' -f4)
            local sni=$(echo "$decoded" | cut -d'|' -f5)
            gen_client_config "anytls" "$ip" "$port" "$password" "$sni"
            ;;
        SS2022-SHADOWTLS)
            # SS2022-SHADOWTLS|ip|port|method|password|stls_password|sni
            local ip=$(echo "$decoded" | cut -d'|' -f2)
            local port=$(echo "$decoded" | cut -d'|' -f3)
            local method=$(echo "$decoded" | cut -d'|' -f4)
            local password=$(echo "$decoded" | cut -d'|' -f5)
            local stls_password=$(echo "$decoded" | cut -d'|' -f6)
            local sni=$(echo "$decoded" | cut -d'|' -f7)
            gen_client_config "ss2022-shadowtls" "$ip" "$port" "$method" "$password" "$stls_password" "$sni"
            ;;
        *)
            _err "未知协议类型: $proto"
            return 1
            ;;
    esac
    
    return 0
}


#═══════════════════════════════════════════════════════════════════════════════
# 客户端安装
#═══════════════════════════════════════════════════════════════════════════════
do_install_client() {
    if check_installed; then
        _warn "已安装，是否覆盖?"
        read -rp "  [y/N]: " confirm
        [[ ! "$confirm" =~ ^[yY]$ ]] && return
        stop_services
    fi
    
    _header
    echo -e "  ${W}客户端安装${NC}"
    echo ""
    _line
    echo -e "  ${C}请输入服务端提供的 JOIN码${NC}"
    echo -e "  ${D}(从服务端安装完成后获取)${NC}"
    _line
    echo ""
    
    read -rp "  JOIN码: " join_code
    
    if [[ -z "$join_code" ]]; then
        _err "JOIN码不能为空"
        return 1
    fi
    
    # 选择代理模式
    echo ""
    _line
    echo -e "  ${W}选择代理模式${NC}"
    _item "1" "TUN网卡模式 (推荐，全局透明代理)"
    _item "2" "全局代理模式 (iptables重定向)"
    _item "3" "SOCKS5代理模式 (仅本地代理)"
    _line
    
    read -rp "  请选择 [1]: " mode_choice
    
    local mode="tun"
    case "$mode_choice" in
        2) mode="global" ;;
        3) mode="socks" ;;
        *) mode="tun" ;;
    esac
    
    mkdir -p "$CFG"
    echo "$mode" > "$CFG/mode"
    
    _info "解析 JOIN码..."
    if ! parse_join_code "$join_code"; then
        _err "JOIN码解析失败"
        return 1
    fi
    _ok "配置生成成功"
    
    local protocol=$(get_protocol)
    
    # 安装依赖
    install_deps
    
    # 下载二进制
    case "$protocol" in
        vless|vless-xhttp|vless-ws|vmess-ws|vless-vision|trojan|socks|ss2022)
            download_xray || return 1
            ;;
        hy2)
            download_hysteria || return 1
            ;;
        tuic)
            download_tuic || return 1
            ;;
        anytls)
            download_anytls || return 1
            ;;
        ss2022-shadowtls)
            download_xray || return 1
            download_shadowtls || return 1
            ;;
    esac
    
    # TUN模式需要 tun2socks
    if [[ "$mode" == "tun" ]]; then
        download_tun2socks || return 1
    fi
    
    _info "创建服务..."
    create_scripts
    create_service
    
    _info "启动服务..."
    if start_services; then
        create_shortcut
        
        _dline
        _ok "客户端安装完成!"
        _ok "协议: $(get_protocol_name $protocol)"
        _ok "模式: $(get_mode_name $mode)"
        _ok "快捷命令: vlessc"
        _dline
        
        # 测试连接
        sleep 3
        test_connection
    else
        _err "服务启动失败"
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 卸载
#═══════════════════════════════════════════════════════════════════════════════
do_uninstall() {
    _header
    echo -e "  ${R}警告: 即将卸载客户端${NC}"
    echo ""
    read -rp "  确认卸载? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return
    
    _info "停止服务..."
    stop_services
    
    _info "禁用服务..."
    svc disable vless-reality 2>/dev/null
    svc disable vless-hy2 2>/dev/null
    svc disable vless-tuic 2>/dev/null
    svc disable vless-anytls 2>/dev/null
    svc disable vless-ss2022-shadowtls 2>/dev/null
    svc disable vless-tun 2>/dev/null
    svc disable vless-global 2>/dev/null
    svc disable vless-watchdog 2>/dev/null
    
    _info "删除服务文件..."
    rm -f /etc/systemd/system/vless-*.service
    rm -f /etc/init.d/vless-*
    [[ "$DISTRO" != "alpine" ]] && systemctl daemon-reload
    
    _info "删除配置..."
    rm -rf "$CFG"
    
    _info "删除快捷命令..."
    rm -f /usr/local/bin/vlessc
    
    _ok "卸载完成"
}

#═══════════════════════════════════════════════════════════════════════════════
# 快捷命令
#═══════════════════════════════════════════════════════════════════════════════

# 自动更新系统脚本 (启动时检测)
_auto_update_system_script() {
    local system_script="/usr/local/bin/vless-client.sh"
    local current_script="$0"
    
    # 获取当前脚本的绝对路径
    local real_path=""
    if [[ "$current_script" == /* ]]; then
        real_path="$current_script"
    elif [[ "$current_script" != "bash" && "$current_script" != "-bash" && -f "$current_script" ]]; then
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
    fi
    
    # 如果当前脚本不是系统脚本，检查是否需要更新
    if [[ -n "$real_path" && -f "$real_path" && "$real_path" != "$system_script" ]]; then
        local need_update=false
        
        if [[ ! -f "$system_script" ]]; then
            need_update=true
        else
            # 用 md5 校验文件内容是否不同
            local cur_md5 sys_md5
            cur_md5=$(md5sum "$real_path" 2>/dev/null | cut -d' ' -f1)
            sys_md5=$(md5sum "$system_script" 2>/dev/null | cut -d' ' -f1)
            [[ "$cur_md5" != "$sys_md5" ]] && need_update=true
        fi
        
        if [[ "$need_update" == "true" ]]; then
            cp -f "$real_path" "$system_script" 2>/dev/null
            chmod +x "$system_script" 2>/dev/null
            ln -sf "$system_script" /usr/local/bin/vlessc 2>/dev/null
            ln -sf "$system_script" /usr/bin/vlessc 2>/dev/null
            hash -r 2>/dev/null
            _ok "系统脚本已同步更新 (v$VERSION)"
        fi
    fi
}

create_shortcut() {
    local system_script="/usr/local/bin/vless-client.sh"
    local current_script="$0"

    # 获取当前脚本的绝对路径
    local real_path=""
    if [[ "$current_script" == /* ]]; then
        real_path="$current_script"
    elif [[ "$current_script" == "bash" || "$current_script" == "-bash" ]]; then
        real_path=""
    else
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
    fi

    # 如果系统目录没有脚本，需要创建
    if [[ ! -f "$system_script" ]]; then
        if [[ -n "$real_path" && -f "$real_path" ]]; then
            cp -f "$real_path" "$system_script"
        else
            # 内存运行模式，从网络下载
            local raw_url="https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-client.sh"
            curl -sL --connect-timeout 30 -o "$system_script" "$raw_url" 2>/dev/null
        fi
    fi

    chmod +x "$system_script" 2>/dev/null
    ln -sf "$system_script" /usr/local/bin/vlessc 2>/dev/null
    ln -sf "$system_script" /usr/bin/vlessc 2>/dev/null
    hash -r 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
# 更新
#═══════════════════════════════════════════════════════════════════════════════
do_update() {
    _header
    echo -e "  ${W}脚本更新${NC}"
    _line
    
    echo -e "  当前版本: ${G}v${VERSION}${NC}"
    _info "检查最新版本..."
    
    local remote_url="https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-client.sh"
    local tmp_file=$(mktemp)
    
    if ! curl -sL --connect-timeout 10 -o "$tmp_file" "$remote_url" || [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        _err "下载失败，请检查网络连接"
        return 1
    fi
    
    local remote_ver=$(grep -m1 "^readonly VERSION=" "$tmp_file" | cut -d'"' -f2)
    if [[ -z "$remote_ver" ]]; then
        rm -f "$tmp_file"
        _err "无法获取远程版本信息"
        return 1
    fi
    
    echo -e "  最新版本: ${C}v${remote_ver}${NC}"
    
    # 语义化版本比较函数
    _version_gt() {
        local v1="$1" v2="$2"
        [[ "$v1" == "$v2" ]] && return 1
        local IFS=.
        local i v1_arr=($v1) v2_arr=($v2)
        for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
            local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
            ((n1 > n2)) && return 0
            ((n1 < n2)) && return 1
        done
        return 1
    }
    
    # 比较版本 - 只有远程版本更新时才提示更新
    if ! _version_gt "$remote_ver" "$VERSION"; then
        rm -f "$tmp_file"
        _ok "已是最新版本"
        return 0
    fi
    
    _line
    read -rp "  发现新版本，是否更新? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        rm -f "$tmp_file"
        return 0
    fi
    
    _info "更新中..."
    
    local script_path=$(readlink -f "$0")
    cp "$script_path" "${script_path}.bak" 2>/dev/null
    
    if mv "$tmp_file" "$script_path" && chmod +x "$script_path"; then
        _ok "更新成功! v${VERSION} -> v${remote_ver}"
        echo ""
        echo -e "  ${C}请重新运行脚本以使用新版本${NC}"
        echo -e "  ${D}备份文件: ${script_path}.bak${NC}"
        _line
        exit 0
    else
        [[ -f "${script_path}.bak" ]] && mv "${script_path}.bak" "$script_path"
        rm -f "$tmp_file"
        _err "更新失败"
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 切换代理模式
#═══════════════════════════════════════════════════════════════════════════════
switch_mode() {
    _header
    echo -e "  ${W}切换代理模式${NC}"
    echo ""
    
    local current_mode=$(get_mode)
    echo -e "  当前模式: ${C}$(get_mode_name $current_mode)${NC}"
    echo ""
    _line
    _item "1" "TUN网卡模式"
    _item "2" "全局代理模式"
    _item "3" "SOCKS5代理模式"
    _item "0" "取消"
    _line
    
    read -rp "  请选择: " choice
    
    local new_mode=""
    case $choice in
        1) new_mode="tun" ;;
        2) new_mode="global" ;;
        3) new_mode="socks" ;;
        0) return ;;
        *) _err "无效选择"; return ;;
    esac
    
    if [[ "$new_mode" == "$current_mode" ]]; then
        _warn "已经是该模式"
        return
    fi
    
    _info "切换到 $(get_mode_name $new_mode) 模式..."
    
    stop_services
    echo "$new_mode" > "$CFG/mode"
    
    # 重新生成配置
    if [[ -f "$CFG/info" ]]; then
        local protocol=$(get_protocol)
        source "$CFG/info"
        
        # 根据协议重新生成客户端配置
        case "$protocol" in
            vless)
                gen_client_config "vless" "$server_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni"
                ;;
            vless-xhttp)
                gen_client_config "vless-xhttp" "$server_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni" "$path"
                ;;
            vless-ws)
                gen_client_config "vless-ws" "$server_ip" "$port" "$uuid" "$sni" "$path"
                ;;
            vless-grpc)
                gen_client_config "vless-grpc" "$server_ip" "$port" "$uuid" "$sni" "$path"
                ;;
            vless-vision)
                gen_client_config "vless-vision" "$server_ip" "$port" "$uuid" "$sni"
                ;;
            vmess-ws)
                gen_client_config "vmess-ws" "$server_ip" "$port" "$uuid" "$sni" "$path"
                ;;
            trojan)
                gen_client_config "trojan" "$server_ip" "$port" "$password" "$sni"
                ;;
            socks)
                gen_client_config "socks" "$server_ip" "$port" "$username" "$password"
                ;;
            ss2022)
                gen_client_config "ss2022" "$server_ip" "$port" "$method" "$password"
                ;;
            ss2022-shadowtls)
                gen_client_config "ss2022-shadowtls" "$server_ip" "$port" "$method" "$password" "$stls_password" "$sni"
                ;;
        esac
    fi
    
    # TUN模式需要tun2socks
    if [[ "$new_mode" == "tun" ]]; then
        download_tun2socks
    fi
    
    create_scripts
    create_service
    start_services
    
    _ok "已切换到 $(get_mode_name $new_mode) 模式"
    
    # SOCKS5 模式显示使用提示
    if [[ "$new_mode" == "socks" ]]; then
        echo ""
        _info "SOCKS5 代理使用方法:"
        echo -e "  ${C}代理地址: ${G}127.0.0.1:${SOCKS_PORT}${NC}"
        echo ""
        echo -e "  ${W}# 设置全局代理 (当前终端)${NC}"
        echo -e "  ${G}export http_proxy=socks5://127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "  ${G}export https_proxy=socks5://127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "  ${G}export all_proxy=socks5://127.0.0.1:${SOCKS_PORT}${NC}"
        echo ""
        echo -e "  ${W}# curl 使用代理${NC}"
        echo -e "  ${G}curl -x socks5://127.0.0.1:${SOCKS_PORT} https://ip.sb${NC}"
        echo ""
        echo -e "  ${W}# 取消代理${NC}"
        echo -e "  ${G}unset http_proxy https_proxy all_proxy${NC}"
        echo ""
    else
        sleep 2
        test_connection
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 显示配置信息
#═══════════════════════════════════════════════════════════════════════════════
show_config() {
    if [[ ! -f "$CFG/info" ]]; then
        _err "未找到配置"
        return
    fi
    
    _header
    echo -e "  ${W}当前配置${NC}"
    _line
    
    source "$CFG/info"
    
    echo -e "  协议: ${G}$(get_protocol_name $protocol)${NC}"
    echo -e "  服务器: ${C}$server_ip${NC}"
    echo -e "  端口: ${C}$port${NC}"
    
    case "$protocol" in
        vless|vless-xhttp|vless-vision)
            echo -e "  UUID: ${C}$uuid${NC}"
            [[ -n "$public_key" ]] && echo -e "  公钥: ${D}$public_key${NC}"
            [[ -n "$short_id" ]] && echo -e "  ShortID: ${D}$short_id${NC}"
            [[ -n "$sni" ]] && echo -e "  SNI: ${C}$sni${NC}"
            [[ -n "$path" ]] && echo -e "  路径: ${C}$path${NC}"
            ;;
        vless-ws|vless-grpc|vmess-ws)
            echo -e "  UUID: ${C}$uuid${NC}"
            echo -e "  SNI: ${C}$sni${NC}"
            echo -e "  路径: ${C}$path${NC}"
            ;;
        trojan|hy2|anytls)
            echo -e "  密码: ${D}$password${NC}"
            [[ -n "$sni" ]] && echo -e "  SNI: ${C}$sni${NC}"
            ;;
        socks)
            echo -e "  用户名: ${C}$username${NC}"
            echo -e "  密码: ${D}$password${NC}"
            ;;
        ss2022)
            echo -e "  加密: ${C}$method${NC}"
            echo -e "  密码: ${D}$password${NC}"
            ;;
        tuic)
            echo -e "  UUID: ${C}$uuid${NC}"
            echo -e "  密码: ${D}$password${NC}"
            [[ -n "$sni" ]] && echo -e "  SNI: ${C}$sni${NC}"
            ;;
        ss2022-shadowtls)
            echo -e "  加密: ${C}$method${NC}"
            echo -e "  密码: ${D}$password${NC}"
            echo -e "  SNI: ${C}$sni${NC}"
            echo -e "  STLS密码: ${D}$stls_password${NC}"
            ;;
    esac
    
    _line
    echo -e "  代理模式: ${C}$(get_mode_name $(get_mode))${NC}"
    echo -e "  本地SOCKS5: ${G}127.0.0.1:$SOCKS_PORT${NC}"
    _line
}


#═══════════════════════════════════════════════════════════════════════════════
# 主菜单
#═══════════════════════════════════════════════════════════════════════════════
main_menu() {
    check_root
    
    # 自动更新系统脚本 (确保 vlessc 命令始终是最新版本)
    _auto_update_system_script
    
    while true; do
        _header
        echo -e "  ${W}客户端管理${NC}"
        echo -e "  ${D}系统: $DISTRO${NC}"
        echo ""
        show_status
        echo ""
        _line
        
        if check_installed && [[ "$(get_role)" == "client" ]]; then
            _item "1" "查看配置"
            _item "2" "切换代理模式"
            _item "3" "测试连接"
            _item "4" "节点管理"
            is_paused && _item "5" "恢复服务" || _item "5" "暂停服务"
            _item "6" "重启服务"
            _item "7" "卸载"
        else
            _item "1" "安装客户端 (使用JOIN码)"
        fi
        _item "u" "检查更新"
        _item "0" "退出"
        _line
        
        read -rp "  请选择: " choice || exit 0
        
        if check_installed && [[ "$(get_role)" == "client" ]]; then
            case $choice in
                1) show_config ;;
                2) switch_mode ;;
                3) test_connection ;;
                4) manage_nodes ;;
                5) is_paused && { _info "恢复服务..."; rm -f "$CFG/paused"; start_services && _ok "已恢复"; } || { _info "暂停服务..."; stop_services; touch "$CFG/paused"; _ok "已暂停"; } ;;
                6) _info "重启服务..."; stop_services; sleep 1; start_services && _ok "重启完成" ;;
                7) do_uninstall ;;
                u|U) do_update ;;
                0) exit 0 ;;
                *) _err "无效选择" ;;
            esac
        else
            case $choice in
                1) do_install_client ;;
                u|U) do_update ;;
                0) exit 0 ;;
                *) _err "无效选择" ;;
            esac
        fi
        _pause
    done
}

# 启动主菜单
main_menu
