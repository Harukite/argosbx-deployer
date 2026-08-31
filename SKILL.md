# SKILL.md

## 技术栈

- Bash 5-compatible shell script，目标系统为 Debian/Ubuntu + systemd。
- 上游协议生成器：Argosbx commit `59e5d34519253fe2f17f4789dba22e2ad09e9b57`。
- 服务端内核：Argosbx 生成的 Xray；Argo 入口使用 Cloudflared 2026.7.3。

## 约定

- 上游脚本和 Cloudflared 均固定版本并校验 SHA256；上游脚本只允许预期的 Sing-box 兼容补丁。
- VMess-WS 源站必须监听 `127.0.0.1`，公网只暴露 TCP/80、TCP/443、UDP/443。
- Argo 域名变化时，先在临时目录生成并校验 `clmi.yaml`、三套 Sing-box JSON、`jhsub.txt`，再替换线上文件。
- Shadowrocket 使用 `clmi.yaml`；Sing-box 1.11、1.12-1.13、1.14+ 分别使用 `sbox-legacy.json`、`sbox.json`、`sbox-1.14.json`；`jhsub.txt` 为原始 URI 列表。
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

远程安装器内部还会运行 Xray `run -test`、全部 Sing-box JSON 解析、BusyBox HTTP 订阅回读、服务状态、BBR/fq 和环回监听检查。

## 教训

- 2026-08-05：Shadowrocket 报“服务器 URL 遇到问题”时，首要检查客户端与订阅格式；Shadowrocket 应导入 Clash YAML，不应把 Sing-box JSON 或未经编码的原始 URI 列表当作 Clash 订阅。
- 2026-08-05：Quick Tunnel 重启会换域名；订阅刷新必须与 cloudflared 服务生命周期绑定，并以生成产物校验为停止条件，不能只看上游 `list` 的退出码。
- 2026-08-05：CDN 优选只能按测量位置描述；VPS 到 Cloudflare 的最快 IP 不保证手机实际网络最快，脚本应允许客户端测量后的手工覆盖。
- 2026-08-05：GitHub 一行安装命令必须先下载到本地文件再执行；安装器依赖 `$BASH_SOURCE` 把自身安装为 systemd 刷新 helper，不能直接 `curl | bash`。
- 2026-08-31：非 `--force` 的首次安装路径必须显式 `return 0`；裸 `return` 会继承最后一次“目标不存在”测试的状态 1，导致干净主机在备份后退出。
- 2026-08-31：固定上游脚本不能直接从 `/root/bin/agsbx` 执行；上游安装过程会自更新该路径，使 Bash 边读边覆盖并在脚本后半段出现伪语法错误。必须从独立临时副本运行并在结束后恢复固定补丁版本。
- 2026-08-31：Quick Tunnel 的 `ExecStartPost` 可能早于域名日志；刷新 helper 必须等待有效 `trycloudflare.com` 域名，等待上限应短于 systemd `TimeoutStartSec`。
- 2026-08-31：Sing-box 配置字段跨版本不兼容。1.11 使用旧 DNS server 格式，1.14+ 必须显式配置 HTTP client，不能用单一 JSON 覆盖所有版本。
