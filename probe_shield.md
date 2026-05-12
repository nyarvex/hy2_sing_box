# Probe Shield

`probe-shield.sh` 是一个面向 Debian/VPS 的 nftables 入站防火墙引导脚本，用来做保守的入站收敛、异常 TCP 包丢弃、ICMP 策略、临时黑名单、Fail2ban 联动和自动回滚保护。

它不是“精准识别 GFW 探测包”的工具，也不能保证绕过或阻止所有主动探测。它会接管 nftables runtime ruleset，并写入 `/etc/nftables.conf`，首次部署请按高风险远程防火墙变更处理。

## 适用场景

- Debian 11/12/13 或其他使用 nftables 的 Linux VPS。
- 服务器有 SSH 管理端口，并开放少量 TCP/UDP 业务端口。
- 需要保守丢弃明显异常 TCP flags、限制 ping、保留必要 ICMP/ICMPv6。
- 希望部署时有自动回滚，避免远程 SSH 永久锁死。

不建议用于：

- 没有服务商 VNC/控制台兜底的关键生产机器。
- 依赖复杂 Docker、Kubernetes、VPN、转发/NAT 规则的主机，除非你已经确认现有 nftables 规则能被替换。
- 期望“自动识别并封禁 GFW IP”的场景。

## 重要风险

脚本会执行以下高风险操作：

- 生成新的 nftables 配置并在应用时执行 `flush ruleset`。
- 覆盖 `/etc/nftables.conf`。
- 写入 `/etc/sysctl.d/99-anti-probe.conf` 并应用 sysctl。
- 可选写入 `/etc/fail2ban/jail.d/anti-probe.conf`。
- 启用 `nftables.service` 的开机持久化。

脚本会备份并支持回滚，但远程防火墙变更仍然可能导致 SSH 中断。部署时不要关闭当前 SSH 窗口。

## 部署前检查

先在目标 VPS 上执行：

```bash
command -v nft
nft --version
systemctl status nftables --no-pager
nft list ruleset
systemctl is-active fail2ban || true
fail2ban-client status 2>/dev/null || true
ss -lntup
```

建议手动额外保存一份快照：

```bash
nft list ruleset > /root/nft-before-probe-shield.nft
cp -a /etc/nftables.conf /root/nftables.conf.before-probe-shield 2>/dev/null || true
cp -a /etc/fail2ban/jail.d/anti-probe.conf /root/anti-probe.fail2ban.before 2>/dev/null || true
```

检查脚本语法：

```bash
bash -n ./probe-shield.sh
```

## 首次部署

推荐先使用 `safe` 模式。

```bash
sudo bash ./probe-shield.sh
```

引导过程中重点确认：

- SSH 端口是否正确。
- TCP/UDP 业务端口是否完整填写。
- 是否把当前 SSH 来源 IP 加入白名单。
- `Ping/ICMP` 建议先选 `limited`。
- 防护强度首次建议选 `safe`。
- 回滚时间建议保留默认 3 分钟，或者设为 5 分钟。

部署后不要关闭当前窗口。新开一个 SSH 窗口测试：

```bash
ssh -p <SSH_PORT> root@<SERVER_IP>
```

同时测试业务端口。确认都正常后，回到原窗口输入：

```text
YES
```

如果没有输入 `YES`，脚本会在回滚时间到达后自动恢复部署前规则、持久化配置和 Fail2ban 配置。

## 模式说明

### safe

默认模式，适合首次部署和生产环境。

- 不对 SSH/业务端口做全局新连接限速，避免公网扫描挤掉正常连接。
- 仅丢弃明显异常 TCP flags 和 `ct state new` 的异常 RST。
- 保留必要 ICMP 和 ICMPv6。

### strict

更严格，适合测试环境或已确认业务流量模式的机器。

- 对 SSH/业务端口做全局新连接限速。
- 丢弃所有入站 RST，可能影响正常连接重置。

### paranoid

更激进，误伤概率最高。

- 更低的全局连接速率。
- 同样丢弃所有入站 RST。

## 命令参考

查看状态：

```bash
sudo bash ./probe-shield.sh --status
```

立即回滚到部署前快照：

```bash
sudo bash ./probe-shield.sh --rollback-now
```

临时封禁 IP：

```bash
sudo bash ./probe-shield.sh --ban 1.2.3.4 1h
sudo bash ./probe-shield.sh --ban 2001:db8::1 30m
```

解封 IP：

```bash
sudo bash ./probe-shield.sh --unban 1.2.3.4
```

加入管理白名单：

```bash
sudo bash ./probe-shield.sh --whitelist-add 1.2.3.4
sudo bash ./probe-shield.sh --whitelist-add 1.2.3.0/24
```

移除管理白名单：

```bash
sudo bash ./probe-shield.sh --whitelist-del 1.2.3.4
```

卸载本脚本规则和辅助文件：

```bash
sudo bash ./probe-shield.sh --uninstall
```

注意：`--uninstall` 只移除本脚本的 `anti_probe` 表、辅助文件和持久化配置。若要恢复部署前完整 runtime ruleset，请先执行 `--rollback-now`。

## 文件位置

脚本使用以下路径：

```text
/etc/nftables.conf
/etc/sysctl.d/99-anti-probe.conf
/etc/fail2ban/jail.d/anti-probe.conf
/root/anti-probe-firewall/
/root/anti-probe-firewall/backups/
/run/anti-probe-firewall-confirmed
```

关键备份包括：

```text
/root/anti-probe-firewall/backups/rollback-ruleset.nft
/root/anti-probe-firewall/backups/nftables.conf.rollback.bak
/root/anti-probe-firewall/backups/fail2ban-anti-probe.conf.rollback.bak
/root/anti-probe-firewall/backups/nftables.service.state
```

## Fail2ban 注意事项

如果系统安装了 Fail2ban，脚本会写入独立的 `anti-probe.conf`，并启用 `sshd` jail 对 SSH 端口和应急端口做保护。

`recidive` jail 只有在找到 Fail2ban 日志时才会启用。脚本会检查：

```text
/var/log/fail2ban.log
/var/log/fail2ban/fail2ban.log
```

如果 Fail2ban 配置测试失败，脚本会恢复旧配置或删除新配置，并跳过重启 Fail2ban。

## 应急端口

脚本会在防火墙层放行 TCP `65522`，但这不等于 SSH 一定能从该端口登录。只有 `sshd` 实际监听 `65522` 时，应急端口才可用于 SSH。

如需启用，请在确认 SSH 配置无误后再修改 sshd：

```bash
echo 'Port 22' >> /etc/ssh/sshd_config
echo 'Port 65522' >> /etc/ssh/sshd_config
sshd -t
systemctl reload ssh
ss -lntp | grep sshd
```

远程机器上不要随便重启 SSH。优先使用 `reload`，并保持当前 SSH 窗口不关闭。

## 故障排查

查看当前规则：

```bash
nft list ruleset
```

查看脚本状态：

```bash
sudo bash ./probe-shield.sh --status
```

立即回滚：

```bash
sudo bash ./probe-shield.sh --rollback-now
```

检查 nftables 持久化服务：

```bash
systemctl status nftables --no-pager
systemctl is-enabled nftables
```

检查 Fail2ban：

```bash
fail2ban-client -t
fail2ban-client status
fail2ban-client status sshd
systemctl status fail2ban --no-pager
```

检查监听端口：

```bash
ss -lntup
```

如果 SSH 被锁，但服务商控制台还能进入，优先执行：

```bash
sudo bash /path/to/probe-shield.sh --rollback-now
```

如果找不到脚本文件，可以直接恢复 nft 快照：

```bash
nft -f /root/anti-probe-firewall/backups/rollback-ruleset.nft
cp /root/anti-probe-firewall/backups/nftables.conf.rollback.bak /etc/nftables.conf 2>/dev/null || true
rm -f /etc/sysctl.d/99-anti-probe.conf
sysctl --system
```

## 建议测试流程

1. 在非关键 VPS 上测试。
2. 确认有 VNC/控制台。
3. 执行部署前检查和 `bash -n`。
4. 首次选择 `safe`。
5. 新开 SSH 窗口验证登录。
6. 验证业务端口、IPv6、ping 策略。
7. 确认成功后再输入 `YES` 保留规则。

## 设计边界

这个脚本的目标是降低暴露面和误配置风险，不是识别攻击者身份。

服务器端通常无法可靠区分“真实客户端包”和“被伪造的探测/注入包”。尤其是 RST、SYN/ACK、TLS ClientHello 这类流量，错误地动态封禁来源 IP 可能会误伤真实用户或管理入口。因此脚本默认采用保守策略，避免把“抗探测”做成“自己锁自己”。
