# Sing-box 一键部署脚本
Sing-box 自动化部署工具，支持HY2协议

hy2_ech_argo.sh


· 提供 Hysteria2 + ECH + Argo 隧道 的一键自动化部署，用户执行脚本即可完成 sing-box 核心的安装、配置与启动。

· 支持 两种证书模式：使用自签名的 ECC 证书（默认随机选择 TLS 域名），或粘贴 Cloudflare Origin 证书与私钥手动导入。

· 自动 生成 ECH 密钥对 并写入配置目录，同时提取证书指纹。

· 集成 Cloudflare Argo 隧道 支持，可输入 Argo Token 启用外部隧道，无需额外开放端口。

· 包含 智能系统探测：自动识别 Debian、Ubuntu、CentOS、Alpine 等主流发行版，并做相应环境修复。

· 实现 多档位内存自适应优化：根据 VPS 内存大小（64M~512M+）自动调整 Go 内存限制、UDP 缓冲区和系统参数，适配低配机器。

· 自动 检测并启用 BBR/BBRv2/BBRv3 内核拥塞控制算法，激活 FQ 调度器以提升网络吞吐。

· 支持 ZRAM 内存压缩：在内存紧张时自动创建压缩 Swap，降低 OOM 风险。

· 自动 探测公网 IPv4/IPv6，计算网络延迟与丢包率，动态调整 QUIC 参数与 UDP 缓冲区大小。

· 提供 OSC 52 剪贴板推送：节点链接在 SSH 终端中自动复制到本地剪贴板。

· 使用 随机 TLS 域名池（包括 microsoft.com、apple.com、icloud.com 等主流站点）增强伪装效果（相关提示详见后文）。



argo_1_Initial，argo_3_quantum，argo_2_path，是基于 hy2_ech_argo.sh 的变体，核心功能一致，但在 TLS 域名池中使用了不同的站点列表（如 bing.com、paypal.com 等），同样支持 Hysteria2 + ECH + Argo 隧道的一键部署与智能优化。






anytls

· 在 hy2_ech_argo.sh 基础上 新增 AnyTLS 协议支持，同时部署 Hysteria2 与 AnyTLS 双协议。
· 变量定义中同时包含 HY2_PORT 与 ANYTLS_PORT，便于双端口运行。
· 其余系统探测、内存优化、BBR 加速、证书生成等功能与主脚本保持一致。

reality

· 部署 Hysteria2 + VLESS Reality 双协议组合，无需自有域名即可实现 TLS 伪装。
· Reality 部分自动从域名池中随机选取目标站点（如 bing.com、microsoft.com、apple.com 等）作为伪装目标。
· 证书逻辑区分 Hy2 与 Reality 各自的需求，Hy2 部分仍需证书处理，Reality 则依赖目标站点的 TLS 指纹。
· BBR 探测部分针对 Reality 场景额外适配了 fq_codel 调度器作为后备方案。

（anyreality搭建教程：https://www.bulianglin.com/archives/anyreality.html）




warp1文件可部署 Hysteria2 协议，并集成 Cloudflare WARP 出站分流 功能，可用于解锁流媒体或改变出口 IP。变量 RAW_SALA 与 temp3.8.6_6 相同，TLS 域名池也一致。核心功能与主脚本保持同步，支持全部系统探测、内存优化、BBR 加速等特性。
temp / temp3.8.6_6 / test.sh 为开发过程中的临时测试文件





✅ 一键部署命令
Hy2+Ech / VLESS + HttpUpgrade + Argo：
```bash
curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/nyarvex/Hy2_SB/refs/heads/main/hy2_ech_argo.sh -o /usr/local/bin/hy2_ech_argo.sh && chmod +x /usr/local/bin/hy2_ech_argo.sh && hy2_ech_argo.sh
```
✅tor中继搭建脚本：tor_obf4.sh


快速修复 DNS (最有效)
某些 NAT 机或纯 IPv6 机默认的 DNS 极其难用。直接运行这一行命令来强制修改 DNS，不需要手动打开文件：
```
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
```
或创建/etc/systemd/resolved.conf并写入：
```
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9 8.8.8.8 2001:4860:4860::8888
DNSSEC=yes
DNSOverTLS=yes
Cache=yes
ReadEtcHosts=yes
LLMNR=no
MulticastDNS=no
DNSStubListener=yes
```


检查 IPv6 优先级 
如果你的vps支持双栈（IPv4 + IPv6），有时候系统会优先走 IPv6 去连接 GitHub，但如果 IPv6 路由不通，就会报错。你可以尝试强制使用 IPv4 看看：
```
curl -4 -fsSL https://github.com/nyarvex/sb-dp/raw/refs/heads/main/install-singbox.sh
```

BBR加速(其它项目)：
```
wget -O tcp.sh "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
```
vless部署脚本来源：
https://github.com/chinahch/vless-one

关于域名池：
hy2请使用真实证书，reality选择target的最优解是与实际流量ASN一致的证书站点,官方文档的transport.html页面能看到“始终是偷同 ASN 的证书”这句话，本项目个别文件中使用的域名仅作为演示。
