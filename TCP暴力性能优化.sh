#!/bin/bash
# BBR + TCP 网络性能调优 一键脚本
# 要求: Linux 内核 >= 4.9
set -e

# Root 检查
[ "$EUID" -ne 0 ] && { echo "错误: 需要 root 权限运行"; exit 1; }

echo "============================================"
echo "   Linux 内核版本要求 >= 4.9"
echo "   当前内核: $(uname -r)"
echo "============================================"

# 内核版本检查
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if [ "$KERNEL_MAJOR" -lt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]; }; then
    echo "错误: 内核版本 $(uname -r) 低于 4.9，无法启用 BBR"
    exit 1
fi

# ============================================================
# 第 1 步：加载 BBR 内核模块
# ============================================================
echo "[步骤 1/5] 加载 BBR 内核模块"
if ! lsmod | grep -q "^tcp_bbr" 2>/dev/null; then
    if ! modprobe tcp_bbr 2>/dev/null; then
        echo "错误: 无法加载 tcp_bbr，请检查内核是否 >= 4.9 且编译了 BBR 支持"
        exit 1
    fi
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
# 第 2 步：备份原有配置
# ============================================================
echo "[步骤 2/5] 备份原有 sysctl 配置"
BACKUP_DIR="/root/sysctl-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
[ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ 配置已备份到 $BACKUP_DIR"

# ============================================================
# 第 3 步：检查 fq 队列规则
# ============================================================
echo "[步骤 3/5] 检查 fq (Fair Queuing) 队列规则"
if ! tc qdisc show 2>/dev/null | grep -q fq; then
    echo "    当前未使用 fq，将在 sysctl 中设定默认队列规则"
fi

# ============================================================
# 第 4 步：写入完整 BBR + TCP 调优参数
# ============================================================
echo "[步骤 4/5] 写入完整配置到 /etc/sysctl.d/99-bbr-tcp-tuning.conf"

cat > /etc/sysctl.d/99-bbr-tcp-tuning.conf << 'SYSCTL_EOF'
# ============================================================
# BBR 拥塞控制 + 队列规则
# ============================================================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ============================================================
# TCP 缓冲区自动调优
# ============================================================
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1

# ============================================================
# TCP 核心性能特性
# ============================================================
# 窗口缩放 (Window Scaling) - 支持高 BDP 网络
net.ipv4.tcp_window_scaling = 1

# 时间戳 (Timestamps) - RTT 精确测量，BBR 必需
net.ipv4.tcp_timestamps = 1

# 选择性确认 (SACK) - 高效丢包恢复
net.ipv4.tcp_sack = 1

# TCP Fast Open - 减少握手延迟 (3=客户端+服务器)
net.ipv4.tcp_fastopen = 3

# 禁用空闲后慢启动 - 长连接保持峰值速度
net.ipv4.tcp_slow_start_after_idle = 0

# MTU 探测 - 避免 PMTU 黑洞
net.ipv4.tcp_mtu_probing = 1

# 关闭 TCP 指标缓存 - 避免历史拥塞记录影响新连接
net.ipv4.tcp_no_metrics_save = 1

# ============================================================
# TCP 连接管理与重传优化
# ============================================================
# TIME_WAIT 连接重用
net.ipv4.tcp_tw_reuse = 1

# SYN 重传次数 - 缩短连接建立超时
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# 连接断开前最大重传次数 - 更快检测死连接
net.ipv4.tcp_retries2 = 5

# FIN 超时时间 - 快速回收连接
net.ipv4.tcp_fin_timeout = 15

# ============================================================
# 队列与并发优化
# ============================================================
# 设备接收队列长度
net.core.netdev_max_backlog = 250000

# 扩大临时端口范围
net.ipv4.ip_local_port_range = 1024 65535

# SYN 队列长度
net.ipv4.tcp_max_syn_backlog = 8192

# 监听队列长度
net.core.somaxconn = 65535

# TIME_WAIT 桶数量 - 防止高并发端口耗尽
net.ipv4.tcp_max_tw_buckets = 2000000

# ============================================================
# 延迟与内存优化
# ============================================================
# 通知缓冲区低水位 - 减少应用层延迟
net.ipv4.tcp_notsent_lowat = 16384

# TCP 内存压力阈值 (单位: 页)
net.ipv4.tcp_mem = 786432 1048576 26777216

SYSCTL_EOF

# ============================================================
# 第 5 步：应用配置
# ============================================================
echo "[步骤 5/5] 应用 sysctl 配置"
sysctl -p /etc/sysctl.d/99-bbr-tcp-tuning.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
echo "✓ 配置已应用"

# ============================================================
# 验证
# ============================================================
echo ""
echo "============================================"
echo "   验证结果"
echo "============================================"
echo "当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "当前队列规则: $(sysctl -n net.core.default_qdisc)"
echo "BBR 模块状态: $(lsmod | grep -c tcp_bbr) (1=已加载)"
echo "窗口缩放: $(sysctl -n net.ipv4.tcp_window_scaling)"
echo "时间戳: $(sysctl -n net.ipv4.tcp_timestamps)"
echo "SACK: $(sysctl -n net.ipv4.tcp_sack)"
echo "TCP Fast Open: $(sysctl -n net.ipv4.tcp_fastopen)"
echo "TCP 指标缓存: $(sysctl -n net.ipv4.tcp_no_metrics_save) (1=已关闭)"
echo "自动调节缓冲区: $(sysctl -n net.ipv4.tcp_moderate_rcvbuf)"
echo "SYN 重试: $(sysctl -n net.ipv4.tcp_syn_retries)"
echo "SYNACK 重试: $(sysctl -n net.ipv4.tcp_synack_retries)"
echo ""
echo "============================================"
echo "   调优完成！"
echo "   配置文件: /etc/sysctl.d/99-bbr-tcp-tuning.conf"
echo "   备份目录: $BACKUP_DIR"
echo "   如需回滚: rm /etc/sysctl.d/99-bbr-tcp-tuning.conf && sysctl --system"
echo "============================================"

exit 0
