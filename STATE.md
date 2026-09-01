# Loop State

Last run: 2026-08-31

## 当前任务

- 修复真实 VPS 首次安装与客户端兼容性问题，并为变更准备 PR。

## 已完成

- 固定并校验 Argosbx 上游 commit、兼容补丁和 Cloudflared 版本。
- 参数化 Reality SNI、端口、UUID、订阅令牌、CDN 候选 IP、Quick/Named Tunnel。
- 实现备份、`--force` 可恢复替换、环回 VMess 源站、原子订阅刷新和安装后验证。
- `tests/test_installer.sh` 已通过；`bash -n` 已通过。
- 公共仓库 <https://github.com/Harukite/argosbx-deployer> 的本次修复基线为 main 提交 `050ca12`。
- 已在 Debian 11 x86_64 VPS 完成真实安装，确认 Xray、订阅 HTTP 服务和 Quick Tunnel 均为 active，VMess 源站仅监听 `127.0.0.1`。
- 已修复首次安装裸 `return`、上游脚本自覆盖执行文件、Quick Tunnel 域名竞态。
- 已新增 Sing-box 1.11、1.12-1.13、1.14+ 三套配置；分别用官方 1.11.14、1.13.19、1.14.0-beta.17 核心验证。
- 测试已移除未声明的 `rg` 依赖，并新增配置变体与 Quick Tunnel 域名提取回归检查。

## 未决/已知风险

- 尚未在第二台全新 VPS 上再次执行修复后的完整安装；当前真实 VPS 已使用同等修补完成部署，仓库测试覆盖对应回归点。
- Quick Tunnel 无 SLA；HTTP 订阅无传输加密；脚本不代替云防火墙配置。
- Xray amd64 使用已知 SHA256；arm64 目前只验证上游生成器报告的版本，未固定本地 digest。
