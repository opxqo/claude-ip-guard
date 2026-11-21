// Claude IP Guard: a resident console for the network guard.
//   ClaudeIPGuard                          console (Dock window + menu bar panel + ⌃⌥⌘K)
//   ClaudeIPGuard --selftest               assert the pure parsing/mapping helpers, then exit
//   ClaudeIPGuard --snapshot <dir>         render every screen state to PNG, then exit
//   ClaudeIPGuard --confirm-session <pid>  one confirmation for a Claude session started outside the console
import AppKit
import Combine
import SwiftUI

// MARK: - Window chrome

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = GuardModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var bag: Set<AnyCancellable> = []
    var quitting = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        buildStatusItem()
        Hotkey.register { [weak self] in
            guard let self else { return }
            NSSound(named: "Funk")?.play()
            self.model.killNow()
        }
        model.startPolling()
        model.startCheck()
        showWindow()
    }

    // MARK: Window

    func buildWindow() {
        let root = ConsoleRoot(m: model, onSettings: { [weak self] in self?.showSettings() })
            .background(Glass().ignoresSafeArea())
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Claude IP Guard"
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
    }

    func showWindow() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the window keeps the guard running in the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showSettings() {
        showWindow()
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: AnyView(EmptyView())))
        let host = NSHostingController(rootView: SettingsView(m: model, close: { [weak self, weak sheet] in
            if let sheet { self?.window.endSheet(sheet) }
        }))
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    // MARK: Menu bar

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        let panel = Dashboard(m: model, compact: true,
                              onSettings: { [weak self] in self?.showSettings() },
                              onWindow: { [weak self] in self?.showWindow() })
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        model.$status.combineLatest(model.$phase, model.$mode)
            .receive(on: RunLoop.main)
            .sink { [weak self] s, phase, mode in self?.updateTitle(s, guarding: phase == .active, forced: mode == .forced) }
            .store(in: &bag)
    }

    func updateTitle(_ s: Status, guarding: Bool, forced: Bool) {
        let level = guarding || s.level == .bad ? s.level : .idle
        let color: NSColor = {
            switch level { case .ok: return .systemGreen; case .retry: return .systemOrange; case .bad: return .systemRed; case .idle: return .secondaryLabelColor }
        }()
        let t = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
        let text = guarding ? s.title + (forced ? " ⚠︎" : "") : (s.level == .bad ? s.title : "未守护")
        t.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        statusItem.button?.attributedTitle = t
    }

    @objc func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "显示控制台", action: #selector(openWindow), keyEquivalent: "0").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "退出 Claude IP Guard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = bar
    }
    @objc func openSettings() { showSettings() }
    @objc func openWindow() { showWindow() }

    // MARK: Quit

    /// Quitting ends the guard: with Claude still running, ask, then close everything and stop the monitor.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.mode != nil || model.phase == .ended else { return .terminateNow }
        let n = Clients.counts()?.processes ?? model.clients.processes
        if n > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "退出会关闭全部 Claude"
            alert.informativeText = "还有 \(n) 个 Claude 进程在运行。退出控制台会关闭它们并停止 IP 监控，避免在无人守护时继续使用。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "关闭全部并退出")
            alert.buttons[1].hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            _ = Clients.killAll()
        }
        model.endSession()
        return .terminateNow
    }
}

// MARK: - Self test

func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } else { print("ok   \(what)") } }
    let now = 1_800_000_000.0
    let cases: [(String, Health?, Bool, Level, String)] = [
        ("healthy", Health(pid: 1, ip: "48.46.13.217", heartbeat: now - 2, state: "healthy"), true, .ok, "48.46.13.217"),
        ("retrying", Health(pid: 1, heartbeat: now - 1, state: "retrying", retry_count: 3, paused_count: 25, retry_deadline: now + 22.4), true, .retry, "重试 3 · 剩 23s"),
        ("blocked", Health(pid: 1, heartbeat: now - 1, state: "blocked"), false, .bad, "已断开"),
        ("stale", Health(pid: 1, heartbeat: now - 30, state: "healthy"), true, .bad, "失联"),
        ("dead", Health(pid: 1, heartbeat: now - 1, state: "healthy"), false, .bad, "失联"),
        ("stopped", Health(pid: 1, heartbeat: now - 300, state: "stopped"), false, .idle, "未监控"),
        ("missing", nil, false, .idle, "未监控"),
    ]
    for (name, h, alive, level, title) in cases {
        let s = classify(h, now: now, pidAlive: { _ in alive })
        check(s.level == level && s.title == title, "classify \(name) → \(s.title)")
    }
    let log = """
    2026-11-20 10:25:59,609 [1] watching baseline 48.46.13.217; transient failures pause/retry up to 30s
    2026-11-20 12:54:34,946 [1] PAUSE/RETRY 1: elapsed=0.2s, paused=33; x
    2026-11-20 12:54:36,900 [1] PAUSE/RETRY 2: elapsed=2.1s, paused=33; x
    2026-11-20 12:54:38,436 [1] RESUME: original IP confirmed; resuming 33 processes
    2026-11-20 13:00:00,000 [1] PAUSE/RETRY 1: elapsed=0.1s, paused=4; x
    2026-11-20 13:00:31,000 [1] KILL: 出口查询持续失败超过重试窗口：超时；detail; matching Claude processes=4
    2026-11-20 13:10:00,000 [2] KILL: 手动一键关闭; matching Claude processes=7
    2026-11-20 13:58:06,388 [1] no Claude process left, exiting
    garbage
    """
    let ev = parseEvents(log)
    check(ev.map(\.kind) == [.start, .pause, .pause, .kill, .kill, .exit], "log kinds \(ev.map(\.kind))")
    check(describe(ev[1]) == "暂停 33 个进程 → 3s 后恢复", "pause folds with RESUME: \(describe(ev[1]))")
    check(ev[2].text == "失败" && ev[3].processes == 4, "pause ended by KILL is failed")
    check(describe(ev[4]) == "关闭 7 个进程 · 手动一键关闭", "manual kill: \(describe(ev[4]))")
    check(stats(ev, since: logStamp.date(from: "2026-11-20 00:00:00")!) == Stats(pauses: 2, kills: 2, lastIssue: ev[4].time), "24h stats")
    let conf = "# comment\nMIN_SCORE=95\n"
    check(confValue(confSetting(conf, "MIN_SCORE", "90"), "MIN_SCORE") == "90", "conf replaces a key")
    check(confSetting(conf, "ON_UNSTABLE", "kill").hasPrefix("# comment\nMIN_SCORE=95\nON_UNSTABLE=kill"), "conf appends a key and keeps comments")
    check(routeFor(nil, listening: { _, _ in false }).kind == .official, "no base URL is official")
    check(routeFor("http://127.0.0.1:15721", listening: { _, _ in false }) == Route(kind: .localDown, url: "127.0.0.1:15721"), "local proxy down")
    check(routeFor("http://localhost:15721", listening: { h, p in h == "127.0.0.1" && p == 15721 }).kind == .localUp, "local proxy up")
    check(routeFor("https://example.com/v1", listening: { _, _ in true }).kind == .custom, "custom endpoint")
    check(baseURL(fromSettings: Data(#"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:1"}}"#.utf8)) == "http://127.0.0.1:1", "settings base URL")
    check(shellQuote("a'b") == "'a'\\''b'", "shell quoting")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

// MARK: - Snapshots

@MainActor func snapshot(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let now = Date()
    let pass = Report(min: 95, ok: true, ip: "203.0.113.10", score: 97, grade: "A+", type: "住宅 IP", native: "原生 IP", network: "ISP", location: "美国 · 加利福尼亚", trust: 100)
    var fail = pass; fail.ok = false; fail.score = 88; fail.grade = "A"
    func samples(_ failing: Bool) -> [Sample] {
        (0..<100).map { i in
            let t = now.timeIntervalSince1970 - Double(100 - i) * 3
            if failing && (i == 71 || i == 72 || i >= 97) { return Sample(time: t, latency: nil, level: .retry) }
            let base = 220 + Int(60 * sin(Double(i) / 6)) + (i % 17 == 0 ? 380 : 0)
            return Sample(time: t, latency: base, level: .ok)
        }
    }
    let events = parseEvents("""
    \(logStamp.string(from: now.addingTimeInterval(-7200))),000 [1] watching baseline 203.0.113.10; x
    \(logStamp.string(from: now.addingTimeInterval(-3000))),000 [1] PAUSE/RETRY 1: elapsed=0.2s, paused=12; x
    \(logStamp.string(from: now.addingTimeInterval(-2997))),000 [1] RESUME: original IP confirmed; resuming 12 processes
    \(logStamp.string(from: now.addingTimeInterval(-600))),000 [1] PAUSE/RETRY 1: elapsed=0.2s, paused=9; x
    \(logStamp.string(from: now.addingTimeInterval(-596))),000 [1] RESUME: original IP confirmed; resuming 9 processes
    """)
    func model(_ configure: (GuardModel) -> Void) -> GuardModel {
        let m = GuardModel()
        m.now = now
        m.minScore = 95
        m.onUnstable = "pause"
        m.events = events
        m.day = stats(events, since: now.addingTimeInterval(-86400))
        configure(m)
        return m
    }
    func active(_ m: GuardModel, _ level: Level) {
        m.phase = .active; m.mode = .verified; m.report = pass; m.sessionIP = pass.ip
        m.since = now.addingTimeInterval(-7980)
        m.samples = samples(level == .retry)
        m.health = Health(pid: 1, ip: pass.ip, heartbeat: now.timeIntervalSince1970 - 1, state: level == .retry ? "retrying" : "healthy",
                          retry_count: 2, paused_count: 9, latency_ms: level == .retry ? nil : 236)
        m.status = level == .retry ? Status(level: .retry, title: "重试 2 · 剩 26s", label: "网络波动 · 已暂停 9 个进程") : Status(level: .ok, title: pass.ip!, label: "网络稳定")
        m.clients = ClientCounts(desktop: 1, desktop_sessions: 3, cli: 2, processes: 41)
    }
    let cases: [(String, CGFloat, GuardModel, Bool)] = [
        ("flow-checking", 420, model { m in m.phase = .checking; m.steps = [.done, .running, .waiting, .waiting] }, false),
        ("flow-pass", 420, model { m in m.phase = .decided; m.report = pass; m.steps = [.done, .done, .done, .waiting] }, false),
        ("flow-fail", 420, model { m in m.phase = .decided; m.report = fail; m.failure = reason(fail, min: 95); m.steps = [.done, .failed, .waiting, .waiting] }, false),
        ("console-healthy", 420, model { m in active(m, .ok); m.route = Route(kind: .localDown, url: "127.0.0.1:15721") }, false),
        ("console-choice-forced", 420, model { m in active(m, .ok); m.mode = .forced; m.report = fail; m.showChoice = true; m.clients = ClientCounts() }, false),
        ("console-retrying", 420, model { m in active(m, .retry); m.killArmed = now }, false),
        ("console-ended", 420, model { m in active(m, .ok); m.phase = .ended; m.mode = nil; m.endReason = "确认出口变化或冲突：出口 IP 与本次启动基准不一致"; m.status = Status(level: .bad, title: "已断开", label: "已断开"); m.clients = ClientCounts() }, false),
        ("panel-healthy", 340, model { m in active(m, .ok) }, true),
        ("panel-idle", 340, model { m in m.phase = .decided; m.report = fail; m.failure = "x" }, true),
    ]
    for scheme in [NSAppearance.Name.aqua, .darkAqua] {
        let dark = scheme == .darkAqua
        for (name, width, m, compact) in cases {
            let view: AnyView = name.hasPrefix("flow")
                ? AnyView(LaunchFlow(m: m, onSettings: {}))
                : AnyView(Dashboard(m: m, compact: compact, onSettings: {}, onWindow: compact ? {} : nil))
            render(view.background(Color(nsColor: dark ? NSColor(red: 0.11, green: 0.115, blue: 0.135, alpha: 1) : NSColor(red: 0.955, green: 0.955, blue: 0.965, alpha: 1))),
                   width: width, appearance: scheme, to: "\(dir)/\(name)-\(dark ? "dark" : "light").png")
        }
        let m = model { _ in }
        render(SettingsView(m: m, close: {}).background(Color(nsColor: dark ? NSColor(white: 0.14, alpha: 1) : .white)),
               width: 400, appearance: scheme, to: "\(dir)/settings-\(dark ? "dark" : "light").png")
    }
    print("snapshots: \(dir)")
}

/// Real AppKit drawing in an offscreen window, so bordered buttons, pickers and charts render.
@MainActor func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name, to path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
    host.appearance = NSAppearance(named: appearance)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { snapshot(to: args[i + 1]) }
    exit(0)
}
// A Claude session started outside the console (e.g. the terminal alias) failed its check: one confirmation.
if let i = args.firstIndex(of: "--confirm-session"), i + 1 < args.count, let pid = Int32(args[i + 1]), pid > 1 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let approved = MainActor.assumeIsolated { () -> Bool in
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "仍然启动这个 Claude Code 会话？"
        alert.informativeText = "CleanIP / ip.net.coffee 检测失败或未通过。继续将只对这个会话生效，出口 IP 变化监控继续保留。\n\n更推荐从 Claude IP Guard 控制台启动。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仅本次强制启动")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    guard approved, let ip = helper(["--baseline"]), helper(["--grant", String(pid), ip]) != nil else { exit(1) }
    exit(0)
}
// One console per user: a second launch brings the first one forward.
if let id = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
    other.activate()
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
