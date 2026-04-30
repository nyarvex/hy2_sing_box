```markdown
# Xray 官方安装命令

维护团队：XTLS 

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

· 更新/删除/帮助：
  · 更新：bash -c "$(curl -L ...)" @ install
  · 仅更新数据：bash -c "$(curl -L ...)" @ install-geodata
  · 删除Xray：bash -c "$(curl -L ...)" @ remove
  · 查看帮助：bash -c "$(curl -L ...)" @ help

为方便使用，原完整脚本地址省略为 ...，实际执行请复制上面的完整命令。

Sing-box 官方安装命令

维护团队：SagerNet

```bash
curl -fsSL https://sing-box.app/install.sh | sh
```

· 高级选项：
  · 安装测试版：在末尾加上参数 sh -s -- --beta
  · 安装指定版本：sh -s -- --version <版本号>

Mihomo 内核

注意：原版开源 Clash（Dreamacro/clash）已于 2023 年底删库停更，当前主流的是以下社区分支，安装时建议优先考虑：

Mihomo 内核（原名 Clash.Meta，最推荐）

核心维护者：MetaCubeX
同时支持代理和代理服务端，是目前功能最强、更新最快的“小猫”内核。

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/MetaCubeX/mihomo/refs/heads/master/scripts/install.sh)" @ install
```

X-UI 面板安装命令

· 3X-UI (推荐)：功能更丰富的活跃分支
  ```bash
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  ```
· 原版 X-UI：部分项目已停更或归档
  ```bash
  bash <(curl -Ls https://gitcode.com/gh_mirrors/xui/x-ui/raw/master/install.sh)
  ```

S-UI 面板安装命令

· Alireza0 版 (最流行)：基于 Sing-box 的主流面板
  ```bash
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
  ```
· S-UI-Pro (进阶版)：集成 Nginx，适合处理高强度连接
  ```bash
   bash <(wget -qO- https://raw.githubusercontent.com/GFW4Fun/S-UI-PRO/master/s-ui-pro.sh) -install yes
  ```

```
