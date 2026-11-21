// The console's state: the launch check, the guard session, and live monitor readings.
import AppKit
import SwiftUI

enum Phase: Equatable { case checking, decided, establishing, active, ended }
enum StepState { case waiting, running, done, failed }
enum SessionMode: String { case verified, forced }

struct Sample: Identifiable, Equatable {
    var id: Double { time }
    var time: Double
    var latency: Int?   // nil: the probe failed
    var level: Level
}

final class GuardModel: ObservableObject {
    // Launch check
    @Published var phase: Phase = .checking
    @Published var steps: [StepState] = Array(repeating: .waiting, count: 4)
    @Published var report: Report?
    @Published var failure: String?
    var rawReport: String?
    var checkedAt: Date?

    // Session
    @Published var mode: SessionMode?
    @Published var sessionIP: String?
    @Published var since: Date?
    @Published var endReason: String?
    @Published var showChoice = false

    // Live readings
    @Published var health: Health?
    @Published var status = Status(level: .idle, title: "未监控", label: "未在守护")
    @Published var samples: [Sample] = []
    @Published var clients = ClientCounts()
    @Published var route = Route(kind: .official)
    @Published var events: [Event] = []
    @Published var day = Stats(pauses: 0, kills: 0, lastIssue: nil)
    @Published var now = Date()

    // Settings and transient UI
    @Published var onUnstable = Conf.onUnstable
    @Published var minScore = Conf.minScore
    @Published var minTrust = Conf.minTrust
    @Published var killArmed: Date?
    @Published var notice: String?
    @Published var busy = false
    @AppStorage("terminal") var terminal = Clients.Terminal.terminal.rawValue
    @AppStorage("cliDirectory") var cliDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    var titles: [String] { ["查询出口 IP · CleanIP", "纯净度高于 \(minScore) 且为住宅 IP", "风险核验 · ip.net.coffee", "建立 IP 监控"] }
    var live = false  // false in snapshots: no timers, no helpers
    private var lastBeat: Double?
    private var logStampSeen: Date?
    private var ticks = 0

    // MARK: Launch check

    func startCheck() {
        guard phase != .establishing else { return }
        phase = .checking
        steps = Array(repeating: .waiting, count: 4)
        report = nil; failure = nil; rawReport = nil; endReason = nil
        minScore = Conf.minScore; minTrust = Conf.minTrust
        steps[0] = .running
        background {
            let o = run(checkTool, ["--json"])
            let r = try? JSONDecoder().decode(Report.self, from: Data(o.stdout.utf8))
            main { self.afterCheck(r, raw: o.stdout) }
        }
    }

    private func afterCheck(_ r: Report?, raw: String) {
        guard let r else { return fail(0, "检测程序未返回有效结果") }
        guard r.ip != nil || r.ok else { return fail(0, "CleanIP 查询失败：\(r.why ?? "未取得响应")") }
        report = r; rawReport = raw; checkedAt = Date()
        if let m = r.min { minScore = m }
        steps[0] = .done
        steps[1] = .running
        after(0.3) {
            let cleanip = (r.score ?? 0) > (r.min ?? self.minScore) && (r.type?.contains("住宅") ?? false)
            guard r.ip != nil, cleanip else { return self.fail(1, reason(r, min: self.minScore)) }
            self.steps[1] = .done
            self.steps[2] = .running
            after(0.3) {
                guard r.ok else { return self.fail(2, reason(r, min: self.minScore)) }
                self.steps[2] = .done
                self.phase = .decided
            }
        }
    }

    private func fail(_ step: Int, _ why: String) {
        steps[step] = .failed
        failure = why
        phase = .decided
    }

    var passed: Bool { phase == .decided && failure == nil }

    // MARK: Session

    /// One confirmation; it covers every client started while this console runs.
    func forceStart() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "仍然强制启动守护？"
        alert.informativeText = "检测未通过：\(failure ?? "未知原因")\n\n将跳过本次 CleanIP / ip.net.coffee 判定，以当前出口 IP 为基准继续监控。IP 一旦变化仍会立即关闭全部 Claude。授权只在本次控制台运行期间有效。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制启动")
        alert.buttons[1].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        establish(.forced)
    }

    func establish(_ mode: SessionMode) {
        // A verdict older than two minutes is stale: check again instead of trusting it.
        if mode == .verified, let at = checkedAt, Date().timeIntervalSince(at) > 120 { return startCheck() }
        phase = .establishing
        steps[3] = .running
        let known = report?.ip
        let raw = rawReport ?? "null"
        background {
            let ip = mode == .verified ? known : helper(["--baseline"])
            let begun = ip.flatMap { helper(["--session-begin", $0, mode.rawValue, raw]) }
            main {
                guard let ip, begun != nil else {
                    self.steps[3] = .failed
                    self.failure = ip == nil ? "无法查询出口 IPv4，不能建立监控" : "监控启动失败：出口可能已变化，或仍有 Claude 使用旧基准 IP"
                    self.phase = .decided
                    return
                }
                self.steps[3] = .done
                self.mode = mode
                self.sessionIP = ip
                self.since = Date()
                self.phase = .active
                self.showChoice = true
                self.tick()
            }
        }
    }

    /// Ends the guard: stop the monitor and drop the session. Used on quit and before a re-check.
    func endSession() {
        _ = helper(["--stop-watch"])
        _ = helper(["--session-end"])
        mode = nil; since = nil
    }

    func recheck() {
        background {
            if self.clients.processes == 0 { _ = helper(["--stop-watch"]) }
            _ = helper(["--session-end"])
            main { self.mode = nil; self.since = nil; self.startCheck() }
        }
    }

    // MARK: Clients

    func launchDesktop() {
        showChoice = false
        Clients.openDesktop { err in self.flash(err.map { "无法打开 Claude：\($0)" } ?? "已打开 Claude 桌面端") }
    }

    func launchCLI() {
        showChoice = false
        let t = Clients.Terminal(rawValue: terminal) ?? .terminal
        let err = Clients.openCLI(in: t, directory: cliDirectory)
        flash(err ?? "已在 \(t.title) 中打开 Claude Code")
    }

    func monitorOnly() { showChoice = false }

    /// First press arms for 3 seconds; the second press closes everything.
    func pressKill() {
        if let armed = killArmed, Date().timeIntervalSince(armed) < 3 { killNow() } else {
            killArmed = Date()
            after(3.05) { if let a = self.killArmed, Date().timeIntervalSince(a) >= 3 { self.killArmed = nil } }
        }
    }

    func killNow() {
        killArmed = nil
        background {
            let n = Clients.killAll()
            main {
                self.flash(n.map { $0 == 0 ? "没有正在运行的 Claude 进程" : "已关闭 \($0) 个 Claude 进程" } ?? "关闭失败：找不到监控脚本")
                self.refreshClients()
            }
        }
    }

    func setPolicy(_ p: String) {
        onUnstable = p
        Conf.set("ON_UNSTABLE", p)
    }

    func setThresholds(score: Int, trust: Int) {
        minScore = score; minTrust = trust
        Conf.set("MIN_SCORE", String(score))
        Conf.set("MIN_TRUST", String(trust))
    }

    func flash(_ text: String) {
        notice = text
        after(3.5) { if self.notice == text { self.notice = nil } }
    }

    // MARK: Live readings

    func startPolling() {
        live = true
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func tick() {
        guard live else { return }
        now = Date()
        let h = readHealth()
        health = h
        status = classify(h, now: now.timeIntervalSince1970, pidAlive: pidAlive)
        if let beat = h?.heartbeat, beat != lastBeat, h?.state == "healthy" || h?.state == "retrying" {
            lastBeat = beat
            samples.append(Sample(time: beat, latency: h?.state == "healthy" ? h?.latency_ms : nil, level: status.level))
            if samples.count > 100 { samples.removeFirst(samples.count - 100) }
        }
        if phase == .active, let h, h.state == "blocked" || h.state == "stopped" || status.level == .bad {
            if h.state == "blocked" || h.state == "stopped" || !(h.pid.map(pidAlive) ?? false) {
                endReason = h.state == "blocked" ? (h.reason?.isEmpty == false ? h.reason : "出口异常") : "监控已停止"
                phase = .ended
                mode = nil
            }
        }
        ticks += 1
        if ticks % 3 == 1 { refreshClients() }
        if ticks % 5 == 1 { refreshEvents() }
    }

    func refreshClients() {
        background {
            let c = Clients.counts()
            let r = routeFor(baseURL(fromSettings: FileManager.default.contents(atPath: settingsPath)), listening: portListening)
            main {
                if let c { self.clients = c }
                self.route = r
            }
        }
    }

    func refreshEvents() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date
        guard mtime != logStampSeen || events.isEmpty else { return }
        logStampSeen = mtime
        background {
            let e = parseEvents(readLogTail())
            main {
                self.events = e
                self.day = stats(e, since: Date().addingTimeInterval(-86400))
            }
        }
    }
}
