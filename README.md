# Claude IP Guard

在启动 Claude Desktop / Claude Code 之前，用 [CleanIP](https://cleanip.io) 和 [ip.net.coffee](https://ip.net.coffee/claude/) 双重检查出口 IP 是否为高分住宅 IP（两家都通过才放行）；运行期间持续监控出口 IPv4，一旦变化就关闭 Claude。仅支持 macOS（Apple Silicon，macOS 14+）。

> 非官方项目，与 Anthropic 和 CleanIP 均无关联。

> 这是个人自用工具，属于应用层的检测与停止机制，不是防火墙。它不绑定 Claude 的网络连接，不覆盖 IPv6，也不能证明 Anthropic 的目标地址走的是同一条路由。详见 [docs/NETWORK-GUARD.md](docs/NETWORK-GUARD.md)。

## 组成

| 目录 | 内容 |
|---|---|
| `bin/` | `claude-ip-check`（CleanIP 评分与住宅判定）、`claude-ip-watch`（出口监控，暂停重试后才关闭）、`claude-ip-override`（强制放行授权与就绪检查）、`claude_network.py`（共用的网络查询）、`claude-guard`（终端入口）、`claude-desktop-guard` |
| `launcher/` | `Claude (IP Guard).app` 的 Swift 源码与构建脚本、菜单栏状态 `Claude Net Monitor.app`（`ClaudeNetBar.swift`），以及 Python 测试 |
| `mod/cleanip/` | Claude Code mod：会话开始、提交提示和每个模型步骤前都会校验 |
| `config/` | `ip-guard.conf.example`，评分门槛 `MIN_SCORE` |
| `docs/` | 设计说明与限制 |

## 安装

需要 Xcode 命令行工具（`swiftc`）和系统自带的 `python3`。

```bash
./install.sh
```

脚本会把文件装到 `~/.claude/`，并构建 `~/Applications/Claude (IP Guard).app` 和 `~/Applications/Claude Net Monitor.app`。它**不会**修改 `settings.json` 或 shell 配置，脚本结束时会列出需要手动执行的步骤：注册并启用 mod、给终端加 alias。

## 配置

`~/.claude/ip-guard.conf`：

```
MIN_SCORE=95
```

CleanIP 评分必须**高于**该值才放行，范围 0–99，无效值回退为 95。

```
MIN_TRUST=80
```

ip.net.coffee 返回的 `trust_score`（0–100）必须**不低于**该值，且没有机房、VPN、代理、Tor、滥用标记，才算通过；无效值回退为 80。

## 菜单栏状态

`Claude Net Monitor.app` 在屏幕顶部菜单栏常驻一个圆点，每秒读取 `~/.claude/run/ip-watch-health.json`，并在文件变化时立即刷新：

| 圆点 | 含义 |
|---|---|
| 🟢 `● 48.46.13.217` | 监控健康，出口与基准一致（心跳 ≤ 10 秒） |
| 🟠 `● 重试 n · 剩 xs` | 出口查询失败，Claude 已暂停，正在重试 |
| 🔴 `● 已断开` / `● 失联` | 出口已变化、Claude 已被关闭，或监控进程消失、心跳过期 |
| ⚪ `● 未监控` | Claude 没在运行，监控已退出 |

点开可以看到基准 IP、心跳、重试与暂停的进程数、失败原因、近 24 小时的暂停和关闭次数，以及最近 8 条事件。菜单里还能打开日志和说明、复制 IP、切换开机自启（写入 `~/Library/LaunchAgents/local.claude-netbar.plist`，首次启动时默认开启）。它只读文件，不向任何进程发信号。启动器每次打开 Claude 前会顺带把它拉起来。

## 测试

```bash
python3 launcher/tests/test_network.py
python3 launcher/tests/test_network_retry.py
```

菜单栏状态的自测（状态映射与日志解析）和各状态的截图：

```bash
~/Applications/Claude\ Net\ Monitor.app/Contents/MacOS/ClaudeNetBar --selftest
```

```bash
~/Applications/Claude\ Net\ Monitor.app/Contents/MacOS/ClaudeNetBar --snapshot /tmp/netbar
```

mod 的测试用 `claude plugin test mod/cleanip`。

## 注意

- ip.net.coffee 用的是它网页内部的接口 `/api/iprisk/<IP>`，没有公开文档，字段随时可能变；它按 /24 缓存，返回的 `ip` 可能是同网段的另一个地址，所以按 `cidr` 匹配。任一家查询失败（重试 3 次后）都按失败处理。
- 依赖 `https://cleanip.io/cli` 的纯文本输出格式。官方改字段名时，`bin/claude-ip-check` 和 `mod/cleanip/hooks/register.tsx` 里各有一份解析规则，需要同时更新。
- 强制放行只跳过 CleanIP 的评分与住宅判定，仍要求出口探测成功且监控健康，并且需要在原生对话框里确认两次。
- 源码里的 `__HOME__` 由 `install.sh` 替换为你的用户目录。
