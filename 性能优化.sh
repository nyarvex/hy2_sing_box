#!/bin/bash
# BBR + TCP 网络性能调优 一键脚本
set -e

echo "============================================"
echo "   Linux 内核版本要求 >= 4.9"
echo "   当前内核: $(uname -r)"
echo "============================================"

# ============================================================
# 第 1 步：加载 BBR 内核模块
# ============================================================
echo "[步骤 1/4] 加载 BBR 内核模块"
if ! modprobe tcp_bbr 2>/dev/null; then
    echo "错误: 无法加载 tcp_bbr，请检查内核是否 >= 4.9 且编译了 BBR 支持。"
    exit 1
fi

# 设置开机自动加载
if [ -d /etc/modules-load.d ]; then
    echo "tcp_bbr" > /etc/modules-load.d/99-bbr.conf
else
    if ! grep -q "^tcp_bbr" /etc/modules 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules
    fi
fi
echo "✓ BBR 模块已加载并设为开机自启"

# ============================================================
# 第 2 步：确保 fq 队列规则可用
# ============================================================
echo "[步骤 2/4] 检查 fq (Fair Queuing) 队列规则"
# 大多数发行版默认都有，但提示一下
if ! tc qdisc show | grep -q fq 2>/dev/null; then
    echo "    当前未使用 fq，将在 sysctl 配置中设定默认队列规则。"
fi

# ============================================================
# 第 3 步：写入 BBR 核心参数
# ============================================================
echo "[步骤 3/4] 写入 BBR 配置参数到 /etc/sysctl.d/99-bbr.conf"
cat > /etc/sysctl.d/99-bbr.conf << 'SYSCTL_EOF'
# ===== BBR 核心配置 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== TCP 发送/接收缓冲区自动调优 =====
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# ===== TCP 性能特性开启 =====
# 窗口缩放 (支持高 BDP 网络)
net.ipv4.tcp_window_scaling = 1
# 时间戳 (RTT 精确测量，配合 BBR 必要)
net.ipv4.tcp_timestamps = 1
# 选择性确认 SACK (高效丢包恢复)
net.ipv4.tcp_sack = 1
# TCP Fast Open (客户端与服务器均启用，减少握手延迟)
net.ipv4.tcp_fastopen = 3
# 禁用空闲后慢启动 (长连接持续保持速度)
net.ipv4.tcp_slow_start_after_idle = 0
# MTU 探测 (避免 PMTU 黑洞)
net.ipv4.tcp_mtu_probing = 1

# ===== TCP 连接与重传优化 =====
# 允许重用 TIME_WAIT 连接（客户端侧）
net.ipv4.tcp_tw_reuse = 1
# SYN 重传次数 (缩短连接建立超时)
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
# 连接断开前的最大重传次数 (更快检测死连接)
net.ipv4.tcp_retries2 = 5

# ===== 通知缓冲区低水位 (减少应用层延迟) =====
net.ipv4.tcp_notsent_lowat = 16384

# ===== 队列与并发优化 =====
# 设备接收队列长度
net.core.netdev_max_backlog = 250000
# 扩大临时端口范围
net.ipv4.ip_local_port_range = 1024 65535
# FIN 超时时间 (快速回收连接)
net.ipv4.tcp_fin_timeout = 15
# SYN 队列长度
net.ipv4.tcp_max_syn_backlog = 8192

SYSCTL_EOF

# ============================================================
# 第 4 步：应用全部配置
# ============================================================
echo "[步骤 4/4] 应用所有 sysctl 配置"
sysctl --system 2>/dev/null || sysctl -p /etc/sysctl.d/99-bbr.conf

# ============================================================
# 验证
# ============================================================
echo ""
echo "============================================"
echo "   验证 BBR 是否生效"
echo "============================================"
echo "当前拥塞控制算法:"
sysctl net.ipv4.tcp_congestion_control
echo ""
echo "BBR 模块加载状态:"
lsmod | grep bbr
echo ""
echo "============================================"
echo "   调优完成！"
echo "   配置文件: /etc/sysctl.d/99-bbr.conf"
echo "   如需恢复系统原设置，删除上述文件后执行 'sysctl --system' 即可。"
echo "============================================"

exit 0
