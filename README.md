# Sing-box 一键部署脚本
Sing-box 自动化部署工具，支持HY2协议


✅ 一键部署命令
Hy2+Ech / VLESS + HttpUpgrade + Argo：
```bash
curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/nyarvex/Hy2_SB/refs/heads/main/hy2_ech_argo.sh -o /usr/local/bin/hy2_ech_argo.sh && chmod +x /usr/local/bin/hy2_ech_argo.sh && hy2_ech_argo.sh
```
✅tor中继搭建脚本：tor_obf4.sh



快速修复 DNS (最有效)
某些 NAT 机或纯 IPv6 机默认的 DNS 极其难用。直接运行这一行命令来强制修改 DNS，不需要手动打开文件：echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

或创建/etc/systemd/resolved.conf并写入：
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



检查 IPv6 优先级 
如果你的vps支持双栈（IPv4 + IPv6），有时候系统会优先走 IPv6 去连接 GitHub，但如果 IPv6 路由不通，就会报错。你可以尝试强制使用 IPv4 看看：
curl -4 -fsSL https://github.com/nyarvex/sb-dp/raw/refs/heads/main/install-singbox.sh


BBR加速(其它项目)：
wget -O tcp.sh "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
vless部署脚本来源：
https://github.com/chinahch/vless-one

关于域名池：
hy2请使用真实证书，reality选择target的最优解是与实际流量ASN一致的证书站点,官方文档的transport.html页面能看到“始终是偷同 ASN 的证书”这句话，本项目个别文件中使用的域名仅作为演示。
