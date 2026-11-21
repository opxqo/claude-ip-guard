// Claude Net Monitor: a menu bar status item for claude-ip-watch. Read-only: it reads
// ~/.claude/run/ip-watch-health.json and ip-watch.log, probes the monitor PID with kill(pid, 0),
// and never signals or changes anything the guard owns.
//   ClaudeNetBar                       normal launch (menu bar only, no Dock icon)
//   ClaudeNetBar --run-dir <dir>       read health/log from another directory (testing)
//   ClaudeNetBar --selftest            assert the state mapping and log parser, then exit
//   ClaudeNetBar --snapshot <dir>      render every fixture state to PNG and exit
import AppKit
import Darwin

let home = FileManager.default.homeDirectoryForCurrentUser.path
let args = CommandLine.arguments
func argument(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let runDir = argument("--run-dir") ?? "\(home)/.claude/run"
let testMode = argument("--run-dir") != nil
let healthPath = "\(runDir)/ip-watch-health.json"
let logPath = "\(runDir)/ip-watch.log"
let configPath = "\(home)/.claude/ip-guard.conf"
let guidePath = "\(home)/.claude/launcher/NETWORK-GUARD.md"
let agentLabel = "local.claude-netbar"
let agentPath = "\(home)/Library/LaunchAgents/\(agentLabel).plist"
let staleAfter = 10.0 // same freshness rule as claude_network.health()

// MARK: - Model (pure, tested by --selftest)

struct Health: Decodable {
    var pid: Int?
    var ip: String?
    var heartbeat: Double?
    var state: String?
    var reason: String?
    var retry_count: Int?
    var paused_count: Int?
    var retry_deadline: Double?
    var transport: String?
}

enum Level: Equatable { case ok, retry, bad, idle }

struct Status: Equatable {
    var level: Level
    var title: String  // text after the dot in the menu bar
    var label: String  // the 状态 row in the menu
}

func classify(_ h: Health?, now: Double, pidAlive: (Int) -> Bool) -> Status {
    guard let h, let state = h.state else { return Status(level: .idle, title: "未监控", label: "未运行（Claude 未启动）") }
    if state == "stopped" { return Status(level: .idle, title: "未监控", label: "已停止（Claude 已退出）") }
    if state == "blocked" { return Status(level: .bad, title: "已断开", label: "已断开 · Claude 已被关闭") }
    let age = now - (h.heartbeat ?? 0)
    let alive = h.pid.map(pidAlive) ?? false
    if !alive || age > staleAfter || age < -2 {
        return Status(level: .bad, title: "失联", label: alive ? "监控心跳过期（\(Int(age)) 秒）" : "监控进程已不存在")
    }
    switch state {
    case "healthy":
        return Status(level: .ok, title: h.ip ?? "健康", label: "健康 · 出口与基准一致")
    case "retrying":
        let left = h.retry_deadline.map { max(0, Int(($0 - now).rounded(.up))) }
        let title = "重试 \(h.retry_count ?? 0)" + (left.map { " · 剩 \($0)s" } ?? "")
        return Status(level: .retry, title: title, label: "重试中 · 已暂停 \(h.paused_count ?? 0) 个 Claude 进程")
    default:
        return Status(level: .bad, title: "未知", label: "未知状态 \(state)")
    }
}

enum EventKind: Equatable { case start, exit, pause, kill }

struct Event: Equatable {
    var time: Date
    var kind: EventKind
    var text: String
    var end: Date? = nil  // pause: when RESUME arrived
    var processes: Int? = nil
}

let logStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()
let lineRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:,(\d{3}))? \[\d+\] (.*)$"#)
let pauseRE = try! NSRegularExpression(pattern: #"^PAUSE/RETRY (\d+): .*?paused=(\d+)"#)
let killRE = try! NSRegularExpression(pattern: #"^KILL: (.*?)(?:; matching Claude processes=(\d+))?$"#)

func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
}

/// Folds a pause run (PAUSE/RETRY 1…n then RESUME or KILL) into one event.
func parseEvents(_ log: String) -> [Event] {
    var out: [Event] = []
    var open: Int? = nil  // index of the pause event still waiting for RESUME/KILL
    for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let g = groups(lineRE, String(line)), let stamp = g[0], let msg = g[2],
              let second = logStamp.date(from: stamp) else { continue }
        let t = second.addingTimeInterval(Double(g[1] ?? "0").map { $0 / 1000 } ?? 0)
        if let p = groups(pauseRE, msg) {
            let n = Int(p[0] ?? "") ?? 0
            if open == nil || n == 1 {
                out.append(Event(time: t, kind: .pause, text: "", processes: Int(p[1] ?? "")))
                open = out.count - 1
            }
        } else if msg.hasPrefix("RESUME") {
            if let i = open { out[i].end = t }
            open = nil
        } else if let k = groups(killRE, msg) {
            if let i = open { out[i].end = t; out[i].text = "失败" }
            open = nil
            let reason = (k[0] ?? "").components(separatedBy: "；").first ?? ""
            out.append(Event(time: t, kind: .kill, text: reason, processes: Int(k[1] ?? "")))
        } else if msg.hasPrefix("watching baseline") {
            let ip = msg.split(separator: " ").dropFirst(2).first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ";")) } ?? ""
            out.append(Event(time: t, kind: .start, text: ip))
        } else if msg.hasPrefix("no Claude process left") {
            out.append(Event(time: t, kind: .exit, text: ""))
        }
    }
    return out
}

let shortStamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f
}()

func describe(_ e: Event) -> String {
    let t = shortStamp.string(from: e.time)
    switch e.kind {
    case .start: return "\(t)  监控启动 · 基准 \(e.text)"
    case .exit: return "\(t)  Claude 全部退出，监控结束"
    case .kill:
        let n = e.processes.map { "，关闭 \($0) 个进程" } ?? ""
        return "\(t)  ⛔ 关闭 Claude\(n)：\(String(e.text.prefix(36)))"
    case .pause:
        let n = e.processes.map { "暂停 \($0) 个进程" } ?? "暂停"
        guard let end = e.end else { return "\(t)  ⏸ \(n) · 重试中…" }
        let secs = Int(end.timeIntervalSince(e.time).rounded())
        return e.text == "失败" ? "\(t)  ⏸ \(n) → \(secs)s 后仍失败" : "\(t)  ⏸ \(n) → \(secs)s 后恢复"
    }
}

struct Stats: Equatable { var pauses: Int; var kills: Int; var lastIssue: Date? }

func stats(_ events: [Event], since: Date) -> Stats {
    let recent = events.filter { $0.time >= since }
    let issues = events.filter { $0.kind == .pause || $0.kind == .kill }
    return Stats(pauses: recent.filter { $0.kind == .pause }.count,
                 kills: recent.filter { $0.kind == .kill }.count,
                 lastIssue: issues.map(\.time).max())
}

func minScore(_ text: String) -> Int? {
    text.split(separator: "\n").reversed().compactMap { line -> Int? in
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("MIN_SCORE=") else { return nil }
        return Int(s.dropFirst("MIN_SCORE=".count))
    }.first
}

// MARK: - IO

func readHealth() -> Health? {
    guard let d = FileManager.default.contents(atPath: healthPath) else { return nil }
    return try? JSONDecoder().decode(Health.self, from: d)
}

func pidAlive(_ pid: Int) -> Bool { pid > 0 && (kill(pid_t(pid), 0) == 0 || errno == EPERM) }

/// The last ~256 KB of the log is plenty for 24 h of events and keeps each read cheap.
func readLogTail() -> String {
    guard let f = FileHandle(forReadingAtPath: logPath) else { return "" }
    defer { try? f.close() }
    let size = (try? f.seekToEnd()) ?? 0
    let start = size > 262_144 ? size - 262_144 : 0
    try? f.seek(toOffset: start)
    var text = String(decoding: f.readDataToEndOfFile(), as: UTF8.self)
    if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
    return text
}

func color(_ l: Level) -> NSColor {
    switch l {
    case .ok: return .systemGreen
    case .retry: return .systemOrange
    case .bad: return .systemRed
    case .idle: return .secondaryLabelColor
    }
}

func barTitle(_ s: Status) -> NSAttributedString {
    let t = NSMutableAttributedString(string: "● ", attributes: [
        .foregroundColor: color(s.level), .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
    t.append(NSAttributedString(string: s.title, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
    return t
}

func ago(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(0, s)) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

// MARK: - Menu bar app

final class Bar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var rows: [String: NSMenuItem] = [:]
    var events: [Event] = []
    var logStamp: Date? = nil
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Claude 网络监控"
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while the menu is open
        timer = t
        watchDir()
    }

    /// Redraw at once when the monitor replaces the health file (os.replace changes the directory).
    func watchDir() {
        let fd = open(runDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func refresh() {
        let now = Date().timeIntervalSince1970
        let h = readHealth()
        let s = classify(h, now: now, pidAlive: pidAlive)
        item.button?.attributedTitle = barTitle(s)
        guard !rows.isEmpty else { return }
        set("state", "状态　　\(s.label)", color: color(s.level))
        set("ip", "基准 IP　\(h?.ip ?? "—")")
        set("beat", "心跳　　\(h?.heartbeat.map { ago(now - $0) } ?? "—")")
        set("retry", "重试/暂停　\(h?.retry_count ?? 0) 次 / \(h?.paused_count ?? 0) 个进程")
        set("pid", "监控 PID　\(h?.pid.map(String.init) ?? "—") · 代理指纹 \(h?.transport.map { String($0.prefix(8)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "—")")
        let reason = h?.reason ?? ""
        rows["reason"]?.isHidden = reason.isEmpty
        set("reason", "原因　　\(String(reason.prefix(60)))")
    }

    func set(_ key: String, _ title: String, color: NSColor? = nil) {
        guard let r = rows[key] else { return }
        r.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color ?? NSColor.labelColor])
    }

    func loadEvents() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date
        if mtime != logStamp || events.isEmpty { events = parseEvents(readLogTail()); logStamp = mtime }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        rows = [:]
        for key in ["state", "ip", "beat", "retry", "pid", "reason"] {
            let r = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            r.isEnabled = false
            rows[key] = r
            menu.addItem(r)
        }
        refresh()
        // Disabled rows draw dimmed; attributed titles keep them readable.
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)).flatMap(minScore)
        header("CleanIP 门槛　评分需 > \(config.map(String.init) ?? "95")")

        loadEvents()
        menu.addItem(.separator())
        let st = stats(events, since: Date().addingTimeInterval(-86400))
        let last = st.lastIssue.map { "，上次异常 \(ago(Date().timeIntervalSince($0)))" } ?? ""
        header("近 24 小时　暂停 \(st.pauses) 次 · 关闭 \(st.kills) 次\(last)",
               color: st.kills > 0 ? .systemRed : st.pauses > 0 ? .systemOrange : .systemGreen)
        menu.addItem(.separator())
        let recent = events.suffix(8).reversed()
        if recent.isEmpty { header("暂无事件") }
        for e in recent { header(describe(e), size: 12) }

        menu.addItem(.separator())
        action("在“控制台”中打开日志", #selector(openLog), "l")
        action("打开说明 NETWORK-GUARD.md", #selector(openGuide), "")
        action("复制基准 IP", #selector(copyIP), "c")
        let auto = action("开机自动启动", #selector(toggleAutostart), "")
        auto.state = FileManager.default.fileExists(atPath: agentPath) ? .on : .off
        auto.isEnabled = !testMode
        menu.addItem(.separator())
        action("退出状态栏", #selector(quit), "q")
    }

    func header(_ text: String, color: NSColor = .labelColor, size: CGFloat = 13) {
        let r = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        r.isEnabled = false
        r.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color])
        menu.addItem(r)
    }

    @discardableResult
    func action(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let r = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        r.target = self
        menu.addItem(r)
        return r
    }

    @objc func openLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: logPath)], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func openGuide() { NSWorkspace.shared.open(URL(fileURLWithPath: guidePath)) }
    @objc func copyIP() {
        guard let ip = readHealth()?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
    @objc func toggleAutostart() { setAutostart(!FileManager.default.fileExists(atPath: agentPath)) }
    @objc func quit() { NSApp.terminate(nil) }
}

/// A LaunchAgent that opens this app at login. Written once by default; the menu toggles it.
func setAutostart(_ on: Bool) {
    let fm = FileManager.default
    if !on { try? fm.removeItem(atPath: agentPath); return }
    let app = Bundle.main.bundlePath
    guard app.hasSuffix(".app") else { return }
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": ["/usr/bin/open", "-g", app],
        "RunAtLoad": true,
    ]
    try? fm.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
        fm.createFile(atPath: agentPath, contents: d)
    }
}

// MARK: - Self test and snapshots

let fixtureNow = 1_800_000_000.0
let fixtures: [(String, Health?, Bool, Status)] = [
    ("healthy", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 2, state: "healthy", transport: "ecdf294f00"), true,
     Status(level: .ok, title: "48.46.13.217", label: "健康 · 出口与基准一致")),
    ("retrying", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 1, state: "retrying",
                        reason: "所有出口查询服务均未返回有效公网 IPv4", retry_count: 3, paused_count: 25,
                        retry_deadline: fixtureNow + 22.4), true,
     Status(level: .retry, title: "重试 3 · 剩 23s", label: "重试中 · 已暂停 25 个 Claude 进程")),
    ("blocked", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 1, state: "blocked",
                       reason: "确认出口变化或冲突：IP 已从 48.46.13.217 变为 31.105.200.41"), false,
     Status(level: .bad, title: "已断开", label: "已断开 · Claude 已被关闭")),
    ("stale", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 30, state: "healthy"), true,
     Status(level: .bad, title: "失联", label: "监控心跳过期（30 秒）")),
    ("dead", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 1, state: "healthy"), false,
     Status(level: .bad, title: "失联", label: "监控进程已不存在")),
    ("stopped", Health(pid: 1, ip: "48.46.13.217", heartbeat: fixtureNow - 300, state: "stopped"), false,
     Status(level: .idle, title: "未监控", label: "已停止（Claude 已退出）")),
    ("missing", nil, false, Status(level: .idle, title: "未监控", label: "未运行（Claude 未启动）")),
]

let fixtureLog = """
2026-11-20 10:25:59,609 [19273] watching baseline 48.46.13.217; transient failures pause/retry up to 30s
2026-11-20 12:54:34,946 [19273] PAUSE/RETRY 1: elapsed=0.2s, paused=33; 所有出口查询服务均未返回有效公网 IPv4
2026-11-20 12:54:36,900 [19273] PAUSE/RETRY 2: elapsed=2.1s, paused=33; 所有出口查询服务均未返回有效公网 IPv4
2026-11-20 12:54:38,436 [19273] RESUME: original IP confirmed; resuming 33 processes
2026-11-20 13:00:00,000 [19273] PAUSE/RETRY 1: elapsed=0.1s, paused=4; x
2026-11-20 13:00:31,000 [19273] KILL: 出口查询持续失败超过重试窗口：所有出口查询服务均未返回有效公网 IPv4；api.ipify.org: 超时; matching Claude processes=4
2026-11-20 13:58:06,388 [19273] no Claude process left, exiting
2026-10-16 12:31:35 [5826] KILL: IP 已从 48.46.12.114 变为 31.105.200.41
garbage line
"""

func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } else { print("ok   \(what)") } }
    for (name, h, alive, want) in fixtures {
        let got = classify(h, now: fixtureNow, pidAlive: { _ in alive })
        check(got == want, "classify \(name) → \(got.title) / \(got.label)")
    }
    let ev = parseEvents(fixtureLog)
    check(ev.map(\.kind) == [.start, .pause, .pause, .kill, .exit, .kill], "parse kinds \(ev.map(\.kind))")
    check(ev.count > 1 && ev[1].processes == 33 && ev[1].end != nil, "pause run folds into one event with RESUME")
    check(ev.count > 3 && ev[2].text == "失败" && ev[3].processes == 4, "pause ended by KILL is marked failed")
    check(ev.count > 5 && ev[5].text.hasPrefix("IP 已从"), "old-format KILL without millis parses")
    check(describe(ev[1]).hasSuffix("暂停 33 个进程 → 3s 后恢复"), "describe pause: \(describe(ev[1]))")
    let since = logStamp.date(from: "2026-11-20 00:00:00")!
    check(stats(ev, since: since) == Stats(pauses: 2, kills: 1, lastIssue: ev[3].time), "24h stats")
    check(minScore("# x\nMIN_SCORE=90\nMIN_SCORE=95\n") == 95, "MIN_SCORE uses the last line")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

@MainActor func snapshot(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, h, alive, _) in fixtures {
        let s = classify(h, now: fixtureNow, pidAlive: { _ in alive })
        for dark in [false, true] {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.wantsLayer = true
            view.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
            let bar = NSTextField(labelWithAttributedString: barTitle(s))
            bar.frame = NSRect(x: 10, y: 22, width: 340, height: 18)
            let detail = NSTextField(labelWithString: s.label)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 10, y: 4, width: 340, height: 16)
            view.addSubview(bar); view.addSubview(detail)
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    print("snapshots: \(dir)")
}

// MARK: - Entry

if args.contains("--selftest") { exit(selftest()) }
let app = NSApplication.shared
if let dir = argument("--snapshot") {
    MainActor.assumeIsolated { snapshot(dir) }
    exit(0)
}
// One menu bar item per user: a second normal launch just exits.
if !testMode, let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { exit(0) }
app.setActivationPolicy(.accessory)
if !testMode, !UserDefaults.standard.bool(forKey: "autostartInitialized") {
    setAutostart(true)
    UserDefaults.standard.set(true, forKey: "autostartInitialized")
}
let bar = Bar()
app.run()
