# Argosbx 可重复部署器

这份目录把本次 VPS 节点搭建整理成一个“可复核、可重复、可回滚”的部署包。它不是重新发明协议，而是固定 Argosbx 上游版本，再补上本次验证过的稳定性措施。

## 方案结构

```text
客户端
  ├─ Shadowrocket / Clash：订阅地址 .../clmi.yaml
  ├─ Sing-box：            订阅地址 .../sbox.json
  └─ 其它客户端：          .../jhsub.txt（原始 URI 列表）
                               │ HTTP/80 + 随机路径
                        BusyBox httpd
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
       VLESS Reality Vision/TCP/443   Hysteria2/UDP/443
                 │                           │
                 └────────── Xray ───────────┘
                               │
                 VMess-WS 源站 127.0.0.1:44020
                               │
                       cloudflared Argo
                               │
                Cloudflare 优选 IP:443 / IP:80
```

脚本会执行以下动作：

1. 在 Debian/Ubuntu + systemd 上安装依赖并检查架构。
2. 写入 BBR/fq 持久化配置，并把当前默认网卡的 qdisc 切换为 fq。
3. 下载并校验固定 commit 的 Argosbx 源码；仅移除当前稳定 Sing-box 不认识的 `http_clients` 与 `default_http_client` 字段。
4. 调用上游脚本生成 Xray 的 VLESS Reality、Hysteria2、VMess-WS 基础配置。
5. 把 VMess-WS 源站强制改为 `127.0.0.1`，不暴露额外公网端口。
6. 下载并校验 Cloudflared 2026.7.3，创建带自动重启和自动订阅刷新的 systemd 服务。
7. 默认使用 Quick Tunnel；也可传入 Cloudflare Named Tunnel 的域名和 token。
8. 用 VPS 到 Cloudflare 的 TCP 建连耗时选择一组 443/80 候选 IP。该测量只代表 VPS 出口，不等同于手机到 Cloudflare 的最后一段线路。
9. 在随机令牌路径下提供 Clash YAML、Sing-box JSON、原始 URI 三种订阅，并在 Argo 域名变化后校验通过再原子替换。
10. 安装结束执行 Xray 配置、JSON、订阅内容、服务状态、BBR/fq 和环回监听检查。

## 文件

- `argosbx-deploy.sh`：唯一需要上传到 VPS 的一键安装器。
- `README.md`：架构、参数、验证和故障处理。

## 部署

GitHub 公共仓库的一行安装命令（在 VPS 的 root SSH 会话中执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/Harukite/argosbx-deployer/main/argosbx-deploy.sh -o /tmp/argosbx-deploy.sh && chmod 700 /tmp/argosbx-deploy.sh && bash /tmp/argosbx-deploy.sh
```

命令先保存文件再运行，是为了让安装器能够把自身安装为 `/root/bin/argosbx-deploy`，供 Argo 隧道重启后的自动订阅刷新使用；不要改成直接把内容管道给 `bash`。

建议先把脚本传到 VPS，再执行；这样脚本可以把自身安装为 `/root/bin/argosbx-deploy`，供 systemd 在 Argo 重启时调用：

```bash
scp -P <SSH端口> argosbx-deploy.sh root@<VPS地址>:/root/argosbx-deploy.sh
ssh -p <SSH端口> root@<VPS地址>
chmod 700 /root/argosbx-deploy.sh
bash /root/argosbx-deploy.sh
```

默认安装的是无账号 Quick Tunnel。安装结束会打印三条订阅地址，并将同样的内容写入：

```text
/root/agsbx/subscription.txt
```

Shadowrocket 应选择“添加订阅/Subscribe”，使用 **`clmi.yaml`** 地址；`sbox.json` 是 Sing-box 格式，`jhsub.txt` 是原始 URI 列表，不应把它当作 Shadowrocket 的 Clash 订阅。

### 常用参数

```bash
# 指定节点名前缀、Reality SNI 和固定订阅路径
bash /root/argosbx-deploy.sh \
  --node-name vps-a \
  --reality-sni www.bing.com \
  --subscription-token 0123456789abcdef0123456789abcdef0123456789abcdef

# 手工指定本次验证过的 CDN IP，不做 VPS 侧探测
bash /root/argosbx-deploy.sh \
  --skip-cdn-probe \
  --cf-primary-ip 172.64.145.93 \
  --cf-backup-ip 108.162.192.5

# 使用 Cloudflare Named Tunnel（需要先在 Cloudflare 控制台配置 ingress）
bash /root/argosbx-deploy.sh \
  --argo-domain tunnel.example.com \
  --argo-token '<Cloudflare Tunnel token>'

# 只检查参数，不连接 VPS、不写系统
bash /root/argosbx-deploy.sh --dry-run
```

同名环境变量也可使用，例如 `REALITY_SNI`、`UUID`、`CF_CANDIDATES`、`ARGO_DOMAIN`、`ARGO_TOKEN`。Named Tunnel 必须同时设置域名和 token，且 ingress 的回源地址应为 `http://127.0.0.1:44020`。

## 验证

在提交或上传前可先做离线检查：

```bash
./tests/test_installer.sh
```

安装器会自动执行本机检查；交付后建议从手机和另一条网络再做一次数据面检查：

```bash
systemctl is-active xr.service argosbx-sub.service argosbx-argo.service
systemctl show argosbx-argo.service -p MainPID -p NRestarts
ss -lntup
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc qdisc show
curl -fsS http://127.0.0.1/<令牌>/clmi.yaml | sed -n '1,20p'
python3 -m json.tool /root/agsbx/sbox.json >/dev/null
```

手机端优先导入 `clmi.yaml`。若 Argo 隧道重启，域名会变化；服务的 `ExecStartPost` 会等待新域名、重新生成三份订阅、校验协议数量和新域名残留，再替换旧文件。

## 重装与备份

默认情况下如果发现 `/root/agsbx`、订阅 webroot 或相关 systemd unit 已存在，脚本会停止并要求人工确认。只有明确传入 `--force` 才会继续；继续前会把目标和 root crontab 保存到：

```text
/root/argosbx-backups/preinstall-<UTC时间>/
```

`--force` 使用移动而不是直接删除，便于人工恢复。不要在未检查备份的情况下执行清理命令。

## 固定版本与来源

- Argosbx 上游仓库：<https://github.com/yonggekkk/argosbx>
- 固定 commit：`59e5d34519253fe2f17f4789dba22e2ad09e9b57`
- 上游脚本 SHA256：`95ec2799ba39a2eab15be3effaf5cfa5b2fdda64bf6a086e2aecf30369e483d7`
- 本地兼容补丁后的脚本 SHA256：`b4e211e22df646523b9b4ecc18fa96e23a496462f6caf3e85b41817420d8d19d`
- Cloudflared：`2026.7.3`
  - Linux amd64 SHA256：`9d71c677db00134c1bd4144b7783486b654ad281b1ea62b4972098d19f770f17`
  - Linux arm64 SHA256：`65259e652a7bea08bf5df603233ab22b8bf3116af8df9f9206209af6a1b955c0`

## 已知限制

- Quick Tunnel 无 SLA，重启会更换 `trycloudflare.com` 域名；Named Tunnel 才适合长期固定入口。
- 订阅当前是 HTTP 明文。随机路径只能降低猜测概率，不能替代 HTTPS；不要在公开日志或群聊中传播订阅地址。
- CDN 探测是在 VPS 上进行，无法保证中国大陆手机到 Cloudflare 的实际时延；应从手机实际网络复测候选 IP 后通过 `--cf-primary-ip/--cf-backup-ip` 覆盖。
- BBR/fq 只能改善排队和拥塞控制，不能保证跨境线路带宽、IP 信誉或永不被封。
- 需要在 VPS 云防火墙放行 TCP/80、TCP/443、UDP/443，以及 SSH 管理端口；脚本不自动改远程防火墙，避免锁死 SSH。
- 当前方案沿用 Argosbx 生成的 VMess-WS；Xray 对 VMess/WS 可能提示弃用警告。Reality 和 Hysteria2 是直连备用节点，应保留在客户端中。
- 部署后应立即轮换聊天中曾出现过的 root 密码，并改用 SSH key；脚本不会替用户修改 SSH 认证策略。

## 许可证

上游 Argosbx 以 GPLv3 发布。本目录的包装脚本按 GPLv3 兼容方式提供，使用时请同时保留上游来源和许可证。
