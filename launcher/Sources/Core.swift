// Shared paths, helper calls, the CleanIP report, monitor health and log parsing.
// Pure functions here are covered by --selftest.
import AppKit
import Darwin

let home = FileManager.default.homeDirectoryForCurrentUser.path
let checkTool = "\(home)/.claude/bin/claude-ip-check"
let watchTool = "\(home)/.claude/bin/claude-ip-watch"
let overrideTool = "\(home)/.claude/bin/claude-ip-override"
let claudeCLI = "\(home)/.local/bin/claude"
let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
let configPath = "\(home)/.claude/ip-guard.conf"
let guidePath = "\(home)/.claude/launcher/NETWORK-GUARD.md"
let settingsPath = "\(home)/.claude/settings.json"
let runDir = "\(home)/.claude/run"
let healthPath = "\(runDir)/ip-watch-health.json"
let logPath = "\(runDir)/ip-watch.log"
let staleAfter = 10.0 // same freshness rule as claude_network.health()

// MARK: - Running the shell helpers

struct Output { var status: Int32; var stdout: String }

/// Runs a helper synchronously (call off the main thread for anything that probes the network).
func run(_ tool: String, _ arguments: [String]) -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return Output(status: -1, stdout: "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Output(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func helper(_ arguments: [String]) -> String? {
    let o = run(overrideTool, arguments)
    return o.status == 0 ? o.stdout : nil
}

func background(_ work: @escaping () -> Void) { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

// MARK: - CleanIP + ip.net.coffee report (claude-ip-check --json)

struct Report: Codable, Equatable {
    var min: Int?
    var ok: Bool
    var why: String?
    var ip: String?
    var score: Int?
    var grade: String?
    var type: String?
    var native: String?
    var network: String?
    var location: String?
    var trust: Double?
}

/// Human reason for a failed verdict, CleanIP's own rule first.
func reason(_ r: Report, min: Int) -> String {
    if let s = r.score, s <= (r.min ?? min) { return "纯净度 \(s) 分，需要高于 \(r.min ?? min) 分" }
    if let t = r.type, !t.contains("住宅") { return "不是住宅 IP（\(t)）" }
    return r.why ?? "检测未通过"
}

// MARK: - ip-guard.conf

func confValue(_ text: String, _ key: String) -> String? {
    for line in text.split(separator: "\n").reversed() {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(key + "=") { return String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    return nil
}

/// Replaces the last `key=` line (keeping comments and order) or appends one.
func confSetting(_ text: String, _ key: String, _ value: String) -> String {
    var lines = text.components(separatedBy: "\n")
    if let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }) {
        lines[i] = "\(key)=\(value)"
    } else {
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        lines.append("\(key)=\(value)")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

enum Conf {
    static var text: String { (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "" }
    static func int(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        guard let v = confValue(text, key).flatMap(Int.init), range.contains(v) else { return fallback }
        return v
    }
    static var minScore: Int { int("MIN_SCORE", 0...99, 95) }
    static var minTrust: Int { int("MIN_TRUST", 0...100, 80) }
    static var onUnstable: String { confValue(text, "ON_UNSTABLE") == "kill" ? "kill" : "pause" }
    static func set(_ key: String, _ value: String) {
        try? confSetting(text, key, value).write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Monitor health (written by claude-ip-watch)

struct Health: Decodable, Equatable {
    var pid: Int?
    var ip: String?
    var heartbeat: Double?
    var state: String?
    var reason: String?
    var retry_count: Int?
    var paused_count: Int?
    var retry_deadline: Double?
    var transport: String?
    var latency_ms: Int?
    var on_unstable: String?
    var held: Bool?
}

enum Level: Equatable { case ok, retry, bad, idle }

struct Status: Equatable {
    var level: Level
    var title: String  // after the dot in the menu bar
    var label: String  // headline in the panel
}

func readHealth() -> Health? {
    guard let d = FileManager.default.contents(atPath: healthPath) else { return nil }
    return try? JSONDecoder().decode(Health.self, from: d)
}

func pidAlive(_ pid: Int) -> Bool { pid > 0 && (kill(pid_t(pid), 0) == 0 || errno == EPERM) }

func classify(_ h: Health?, now: Double, pidAlive: (Int) -> Bool) -> Status {
    guard let h, let state = h.state else { return Status(level: .idle, title: "未监控", label: "未在守护") }
    if state == "stopped" { return Status(level: .idle, title: "未监控", label: "监控已停止") }
    if state == "blocked" { return Status(level: .bad, title: "已断开", label: "已断开 · Claude 已被关闭") }
    let age = now - (h.heartbeat ?? 0)
    let alive = h.pid.map(pidAlive) ?? false
    if !alive || age > staleAfter || age < -2 {
        return Status(level: .bad, title: "失联", label: alive ? "监控心跳过期（\(Int(age)) 秒）" : "监控进程已不存在")
    }
    switch state {
    case "healthy":
        return Status(level: .ok, title: h.ip ?? "健康", label: "网络稳定")
    case "retrying":
        let left = h.retry_deadline.map { max(0, Int(($0 - now).rounded(.up))) }
        return Status(level: .retry, title: "重试 \(h.retry_count ?? 0)" + (left.map { " · 剩 \($0)s" } ?? ""),
                      label: "网络波动 · 已暂停 \(h.paused_count ?? 0) 个进程")
    default:
        return Status(level: .bad, title: "未知", label: "未知状态 \(state)")
    }
}

// MARK: - Monitor log (ip-watch.log)

enum EventKind: Equatable { case start, exit, pause, kill }

struct Event: Equatable, Identifiable {
    var id: Date { time }
    var time: Date
    var kind: EventKind
    var text: String
    var end: Date? = nil  // pause: when RESUME or KILL arrived
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

/// Folds a pause run (PAUSE/RETRY 1…n, then RESUME or KILL) into one event.
func parseEvents(_ log: String) -> [Event] {
    var out: [Event] = []
    var open: Int? = nil
    for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let g = groups(lineRE, String(line)), let stamp = g[0], let msg = g[2],
              let second = logStamp.date(from: stamp) else { continue }
        let t = second.addingTimeInterval(Double(g[1] ?? "0").map { $0 / 1000 } ?? 0)
        if let p = groups(pauseRE, msg) {
            if open == nil || Int(p[0] ?? "") == 1 {
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
    switch e.kind {
    case .start: return "监控启动 · 基准 \(e.text)"
    case .exit: return "Claude 全部退出，监控结束"
    case .kill:
        let n = e.processes.map { "关闭 \($0) 个进程 · " } ?? ""
        return "\(n)\(String(e.text.prefix(30)))"
    case .pause:
        let n = e.processes.map { "暂停 \($0) 个进程" } ?? "暂停"
        guard let end = e.end else { return "\(n) · 重试中…" }
        let secs = Int(end.timeIntervalSince(e.time).rounded())
        return e.text == "失败" ? "\(n) → \(secs)s 后仍失败" : "\(n) → \(secs)s 后恢复"
    }
}

struct Stats: Equatable { var pauses: Int; var kills: Int; var lastIssue: Date? }

func stats(_ events: [Event], since: Date) -> Stats {
    let recent = events.filter { $0.time >= since }
    return Stats(pauses: recent.filter { $0.kind == .pause }.count,
                 kills: recent.filter { $0.kind == .kill }.count,
                 lastIssue: events.filter { $0.kind == .pause || $0.kind == .kill }.map(\.time).max())
}

/// The last ~256 KB of the log covers a day of events and keeps each read cheap.
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

func ago(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(0, s)) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
