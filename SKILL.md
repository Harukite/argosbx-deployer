# SKILL.md

## 技术栈

- Bash 5-compatible shell script，目标系统为 Debian/Ubuntu + systemd。
- 上游协议生成器：Argosbx commit `59e5d34519253fe2f17f4789dba22e2ad09e9b57`。
- 服务端内核：Argosbx 生成的 Xray；Argo 入口使用 Cloudflared 2026.7.3。

## 约定

- 上游脚本和 Cloudflared 均固定版本并校验 SHA256；上游脚本只允许预期的 Sing-box 兼容补丁。
- VMess-WS 源站必须监听 `127.0.0.1`，公网只暴露 TCP/80、TCP/443、UDP/443。
- Argo 域名变化时，先在临时目录生成并校验 `clmi.yaml`、`sbox.json`、`jhsub.txt`，再替换线上文件。
- Shadowrocket 使用 `clmi.yaml`；`sbox.json` 留给 Sing-box，`jhsub.txt` 为原始 URI 列表。
- `--force` 前必须保留带 UTC 时间戳的备份；脚本不自动修改云防火墙或 SSH 认证策略。

## 硬规

- 默认不覆盖已有 `/root/agsbx`、webroot 或 systemd unit；必须明确传 `--force`。
- 不把 VPS 地址、SSH 密码、UUID、订阅令牌写入仓库或测试输出。
- Quick Tunnel 的无 SLA 和 HTTP 明文订阅风险必须在交付说明中保留。
- 验证三闸未过时，自动修复并重跑，至多三轮；三轮未果、回环或需求方向不明则停止并报告。

## 验证套件

```bash
bash -n argosbx-deploy.sh
./tests/test_installer.sh
```

远程安装器内部还会运行 Xray `run -test`、Sing-box JSON 解析、BusyBox HTTP 订阅回读、服务状态、BBR/fq 和环回监听检查。

## 教训

- 2026-08-05：Shadowrocket 报“服务器 URL 遇到问题”时，首要检查客户端与订阅格式；Shadowrocket 应导入 Clash YAML，不应把 Sing-box JSON 或未经编码的原始 URI 列表当作 Clash 订阅。
- 2026-08-05：Quick Tunnel 重启会换域名；订阅刷新必须与 cloudflared 服务生命周期绑定，并以生成产物校验为停止条件，不能只看上游 `list` 的退出码。
- 2026-08-05：CDN 优选只能按测量位置描述；VPS 到 Cloudflare 的最快 IP 不保证手机实际网络最快，脚本应允许客户端测量后的手工覆盖。
