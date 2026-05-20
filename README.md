# Love

Love 是一个原生 **Xray + sing-box** 一体化安装、订阅、客户端导出、运维管理脚本。

维护命令：

```bash
Love
```

兼容小写：

```bash
love
```

## 主要能力

- 原生 Xray 稳定模式：VLESS + REALITY + Vision、HY2 / Hysteria2
- 原生 sing-box 全协议模式：Reality、HY2、TUIC、SS、Trojan、VMess WS、VLESS WS TLS、H2 Reality、gRPC Reality、AnyTLS、Naive、ShadowTLS
- IPv6 VPS / Oracle Cloud 场景优化
- 优选 IP / 域名
- V2RayN / Shadowrocket / NekoBox / Mihomo / sing-box / SFI / SFA / SFM 导出
- 二维码：终端、PNG、SVG
- Web 管理页、Dashboard、Basic Auth、随机订阅 token
- Telegram / Bark / Email 推送
- 节点检测、端口推荐、证书检查、定时备份
- 多用户 UUID 管理
- 快照 / 回滚
- 安全审计、验证、脱敏支持包、发布包、更新通道

## 推荐系统

最推荐：

```text
Ubuntu 22.04 / Ubuntu 24.04 / Debian 12
amd64 / arm64
root 权限
systemd
干净 VPS
```

Oracle Cloud AMD / ARM 都支持。  
IPv6-only VPS 可以使用，但客户端没有 IPv6 时不能直接连接，需要 Argo / 中转 / 其他隧道方案。

## 一键安装

### wget

```bash
bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)
```

### curl

```bash
curl -fsSL https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh | bash
```

把 `YOURNAME` 改成你的 GitHub 用户名。

## 本地安装

```bash
sudo -i
wget -O Love.sh https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh
chmod +x Love.sh
./Love.sh
```

首次运行后，直接使用：

```bash
Love
```

## 常用命令

```bash
Love                 # 主菜单
Love precheck        # 环境预检
Love mode            # 安装模式选择
Love links           # 简洁链接总览
Love sub             # 生成订阅
Love qr              # 生成二维码
Love mihomo          # Mihomo / Clash YAML
Love v2rayn          # V2RayN 导出
Love shadowrocket    # Shadowrocket 导出
Love nekobox         # NekoBox 导出
Love singbox-json    # sing-box JSON
Love web             # Web 管理页
Love dashboard       # V8 Dashboard
Love users           # 多用户管理
Love snapshot        # 快照 / 回滚
Love rollback        # 回滚快照
Love doctor          # 全面诊断
Love repair          # 修复 apt / dpkg
Love cert            # 证书状态检查
Love port            # 端口冲突检测
Love oracle          # Oracle Cloud 安全组模板
Love audit           # 安全审计
Love validate        # 全量验证
Love release         # 生成发布包
Love self-update     # 在线更新
```

## Oracle Cloud 端口放行

Oracle 控制台安全列表 / NSG 和 VPS 内部防火墙都要放行。

基础端口：

```text
22/tcp
80/tcp
443/tcp
443/udp
```

sing-box 全协议常用：

```text
8881-8895/tcp
8881-8895/udp
```

Web / 订阅：

```text
8088/tcp
8099/tcp
8100/tcp
```

Port Hopping 示例：

```text
50000-51000/udp
```

## GitHub Actions

本仓库自带 GitHub Actions，会自动执行：

```bash
bash -n Love.sh
```

用于检查脚本语法。

## 安全提醒

- 节点链接里包含 UUID、密码、公钥、token，不要公开。
- Web 管理页建议开启 Basic Auth。
- 建议使用随机订阅路径 token。
- 发布前请用 `Love audit` 和 `Love validate` 检查。
- IPv6-only VPS 上，服务器安装 WARP 不会提供公网 IPv4 入站。

## 免责声明

本项目仅用于合法的网络连接、服务器运维和个人学习研究。请遵守所在地法律法规以及服务商条款。
