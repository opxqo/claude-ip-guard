# Claude IP Guard

一个常驻的网络维稳控制台：启动前用 [CleanIP](https://cleanip.io) 和 [ip.net.coffee](https://ip.net.coffee/claude/) 双重检查出口 IP 是否为高分住宅 IP（两家都通过才放行）；检测不通过也可以确认一次后强制启动；之后可以选择打开 Claude 桌面端、在终端打开 CLI，或者只挂着监控。运行期间持续监控出口 IPv4，一旦变化就关闭全部 Claude，也可以用 ⌃⌥⌘K 一键关闭。仅支持 macOS（Apple Silicon，macOS 14+）。

> 非官方项目，与 Anthropic 和 CleanIP 均无关联。

> 这是个人自用工具，属于应用层的检测与停止机制，不是防火墙。它不绑定 Claude 的网络连接，不覆盖 IPv6，也不能证明 Anthropic 的目标地址走的是同一条路由。详见 [docs/NETWORK-GUARD.md](docs/NETWORK-GUARD.md)。

## 组成

| 目录 | 内容 |
|---|---|
| `bin/` | `claude-ip-check`（CleanIP 评分与住宅判定）、`claude-ip-watch`（出口监控，暂停重试后才关闭）、`claude-ip-override`（强制放行授权与就绪检查）、`claude_network.py`（共用的网络查询）、`claude-guard`（终端入口）、`claude-desktop-guard` |
| `launcher/` | 控制台 `Claude (IP Guard).app` 的 Swift 源码（`Sources/`）与构建脚本，以及 Python 测试 |
| `mod/cleanip/` | Claude Code mod：会话开始、提交提示和每个模型步骤前都会校验 |
| `config/` | `ip-guard.conf.example`：评分门槛 `MIN_SCORE`、`MIN_TRUST`，波动策略 `ON_UNSTABLE` |
| `docs/` | 设计说明与限制 |

## 安装

需要 Xcode 命令行工具（`swiftc`）和系统自带的 `python3`。

```bash
./install.sh
```

脚本会把文件装到 `~/.claude/`，并构建 `~/Applications/Claude (IP Guard).app`；1.x 的 `Claude Net Monitor.app` 已并入控制台，会被删除。它**不会**修改 `settings.json` 或 shell 配置，脚本结束时会列出需要手动执行的步骤：注册并启用 mod、给终端加 alias。

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

```
ON_UNSTABLE=pause
```

网络波动（查不到出口 IP，但 IP 没有确认变化）时：`pause` 暂停 Claude 并重试约 30 秒（默认），`kill` 立即关闭。出口 IP 一旦确认变化，两种策略都立即关闭。控制台里切换后立刻生效。

## 控制台

打开 `Claude (IP Guard).app`：

1. **检测**：CleanIP 评分与住宅判定、ip.net.coffee 风险核验。
2. **建立监控**：通过就点「建立监控」；没通过可以点「仍然强制启动」，确认一次。强制授权在这次控制台运行期间，对之后启动的桌面端和 CLI 都有效。
3. **选择客户端**：桌面端、CLI（Terminal 或 Warp，在设置里选，可指定启动目录），或者只监控。只监控时，即使没有任何 Claude 在运行，监控器也会一直保持。

仪表盘（主窗口和菜单栏弹出面板共用）：

| 卡片 | 内容 |
|---|---|
| 状态 | 🟢 网络稳定 · 🟠 网络波动（已暂停 n 个进程） · 🔴 已断开 / 失联 · ⚪ 未守护；已守护时长和当前波动策略 |
| 出口 IP | 基准 IP、CleanIP 分数环、住宅 / 原生 / 可信度标签；强制启动时显示「强制」 |
| 出口探测 | 最近 5 分钟每次探测的耗时，失败标红 |
| Claude 客户端 | 桌面端和 CLI 的会话数、启动按钮。如果 `~/.claude/settings.json` 把 CLI 指向本地代理（例如 CC Switch）而端口没在监听，会在这里提示 |
| 近 24 小时 | 暂停、关闭次数和最近的事件 |
| 立即关闭全部 Claude | 点两下确认；全局快捷键 ⌃⌥⌘K 直接关闭，不再确认 |

关掉窗口后控制台会留在菜单栏。退出控制台时，如果还有 Claude 在运行，会先询问，确认后一并关闭并停止监控。

## 测试

```bash
python3 launcher/tests/test_network.py
python3 launcher/tests/test_network_retry.py
```

控制台的自测（状态映射、日志解析、配置读写、CLI 路由判断），以及每个界面状态的浅色、深色截图：

```bash
~/Applications/Claude\ \(IP\ Guard\).app/Contents/MacOS/ClaudeIPGuard --selftest
```

```bash
~/Applications/Claude\ \(IP\ Guard\).app/Contents/MacOS/ClaudeIPGuard --snapshot /tmp/guard-ui
```

mod 的测试用 `claude plugin test mod/cleanip`。

## 注意

- ip.net.coffee 用的是它网页内部的接口 `/api/iprisk/<IP>`，没有公开文档，字段随时可能变；它按 /24 缓存，返回的 `ip` 可能是同网段的另一个地址，所以按 `cidr` 匹配。任一家查询失败（重试 3 次后）都按失败处理。
- 依赖 `https://cleanip.io/cli` 的纯文本输出格式。官方改字段名时，`bin/claude-ip-check` 和 `mod/cleanip/hooks/register.tsx` 里各有一份解析规则，需要同时更新。
- 强制放行只跳过 CleanIP 的评分与住宅判定，仍要求出口探测成功且监控健康，需要确认一次。
- 从控制台打开的 CLI 直接运行 `~/.local/bin/claude`，不再经过 `claude-guard`；mod 会读取控制台会话，不重复检测。
- 源码里的 `__HOME__` 由 `install.sh` 替换为你的用户目录。
