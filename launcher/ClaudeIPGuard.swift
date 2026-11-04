// Claude (IP Guard) launcher: a splash window that runs the CleanIP + ip.net.coffee check,
// starts the egress-IP watcher, then opens Claude. Fails closed.
//   ClaudeIPGuard                     normal launch
//   ClaudeIPGuard --snapshot <dir>    render pass/fail states to PNG and exit
import AppKit
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let checkTool = "\(home)/.claude/bin/claude-ip-check"
let watchTool = "\(home)/.claude/bin/claude-ip-watch"
let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
let overrideTool = "\(home)/.claude/bin/claude-ip-override"

func helper(_ arguments: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: overrideTool)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

@MainActor func confirmForce(_ reason: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let first = NSAlert()
    first.alertStyle = .warning
    first.messageText = "强制启动 · 第一次确认"
    first.informativeText = "检测未通过：\(reason)\n\n继续将跳过本次 CleanIP 与 ip.net.coffee 的检测，无法据此确认出口安全。出口 IP 查询暂时失败时会暂停重试；持续失败约 30 秒或确认 IP 改变时仍会关闭 Claude。授权在当前 Claude 进程退出后失效。"
    first.addButton(withTitle: "取消")
    first.addButton(withTitle: "我已了解，继续确认")
    guard first.runModal() == .alertSecondButtonReturn else { return false }
    let second = NSAlert()
    second.alertStyle = .critical
    second.messageText = "强制启动 · 第二次确认"
    second.informativeText = "再次确认：即使 CleanIP / ip.net.coffee 检测未通过，仍要启动 Claude？\n\n仅对本次运行生效，出口 IP 变化监控继续保留。"
    second.addButton(withTitle: "取消")
    second.addButton(withTitle: "仅本次强制启动")
    return second.runModal() == .alertSecondButtonReturn
}

let green = Color(red: 0x35 / 255, green: 0xA9 / 255, blue: 0x52 / 255)
let red = Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255)

struct Report: Decodable {
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

enum StepState { case waiting, running, done, failed }

final class Model: ObservableObject {
    // Threshold from ~/.claude/ip-guard.conf, same rule as claude-ip-check.
    static var minScore: Int {
        let text = (try? String(contentsOfFile: "\(home)/.claude/ip-guard.conf", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("MIN_SCORE=") {
            if let n = Int(line.dropFirst(10).trimmingCharacters(in: .whitespaces)), (0...99).contains(n) { return n }
        }
        return 95
    }
    // MIN_TRUST for the ip.net.coffee second opinion, same rule as claude-ip-check.
    static var minTrust: Int {
        let text = (try? String(contentsOfFile: "\(home)/.claude/ip-guard.conf", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("MIN_TRUST=") {
            if let n = Int(line.dropFirst(10).trimmingCharacters(in: .whitespaces)), (0...100).contains(n) { return n }
        }
        return 80
    }
    @Published var min = Model.minScore
    var titles: [String] { ["查询出口 IP(CleanIP)", "评分高于 \(min) 且为住宅 IP", "核验 IP 风险(ip.net.coffee)", "启动 IP 监听", "打开 Claude"] }
    @Published var steps: [StepState] = Array(repeating: .waiting, count: 5)
    @Published var report: Report?
    @Published var failure: String?
    @Published var forcing = false

    @MainActor func forceLaunch() {
        guard !forcing, let why = failure, confirmForce(why) else { return }
        if CommandLine.arguments.contains("--preview-force") {
            failure = "两次确认已完成（预览模式，未启动 Claude、未授权）"
            return
        }
        forcing = true
        DispatchQueue.global().async {
            let ip = helper(["--baseline"])
            let ready = ip.map { helper(["--ensure", $0]) != nil } ?? false
            DispatchQueue.main.async {
                guard let ip, ready else {
                    self.failure = "无法查询出口 IPv4，不能建立 IP 变化监控。请恢复网络后重试。"
                    self.forcing = false
                    return
                }
                let wasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty == false
                NSWorkspace.shared.openApplication(at: claudeApp, configuration: .init()) { app, err in
                    guard let app, err == nil else {
                        DispatchQueue.main.async { self.failure = "无法打开 Claude"; self.forcing = false }
                        return
                    }
                    DispatchQueue.global().async {
                        let granted = helper(["--grant", String(app.processIdentifier), ip]) != nil
                        DispatchQueue.main.async {
                            self.forcing = false
                            if granted { NSApp.terminate(nil) }
                            else {
                                if !wasRunning { app.terminate() }
                                self.failure = "本次授权或 IP 监听启动失败，未启用强制模式。请关闭 Claude 后重试。"
                            }
                        }
                    }
                }
            }
        }
    }

    var isFailed: Bool { failure != nil }

    func run() {
        steps = Array(repeating: .waiting, count: 5)
        report = nil
        failure = nil
        min = Model.minScore
        steps[0] = .running
        DispatchQueue.global().async {
            let r = Self.check()
            DispatchQueue.main.async { self.afterCheck(r) }
        }
    }

    private func afterCheck(_ r: Report?) {
        guard let r else { return fail(0, "检测程序未返回有效结果，请重新检测") }
        guard r.ip != nil || r.ok else {
            return fail(0, "CleanIP 查询失败：\(r.why ?? "未取得响应")")
        }
        report = r
        if let m = r.min { min = m }
        steps[0] = .done
        steps[1] = .running
        after(0.35) {
            // CleanIP's own verdict first; the ip.net.coffee verdict is what is left when it still fails overall.
            let cleanipPass = (r.score ?? 0) > (r.min ?? self.min) && (r.type?.contains("住宅") ?? false)
            guard r.ip != nil, cleanipPass else { return self.fail(1, self.reason(r)) }
            self.steps[1] = .done
            self.steps[2] = .running
            after(0.35) {
                guard r.ok, let ip = r.ip else { return self.fail(2, self.reason(r)) }
                self.steps[2] = .done
                self.steps[3] = .running
                after(0.3) {
                    guard Self.startWatcher(ip) else { return self.fail(3, "IP 监听启动失败") }
                    self.steps[3] = .done
                    self.steps[4] = .running
                    NSWorkspace.shared.openApplication(at: claudeApp, configuration: .init()) { _, err in
                        DispatchQueue.main.async {
                            if let err { return self.fail(4, "无法打开 Claude:\(err.localizedDescription)") }
                            self.steps[4] = .done
                            after(1.0) { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
    }

    private func fail(_ step: Int, _ why: String) {
        steps[step] = .failed
        failure = why
    }

    func reason(_ r: Report) -> String {
        if let s = r.score, s <= (r.min ?? min) { return "纯净度 \(s) 分,需要高于 \(r.min ?? min) 分" }
        if let t = r.type, !t.contains("住宅") { return "不是住宅 IP(\(t))" }
        return r.why ?? "检测未通过"
    }

    static func check() -> Report? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: checkTool)
        p.arguments = ["--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    // Wait for a live heartbeat and matching exit IP before opening Claude.
    static func startWatcher(_ ip: String) -> Bool {
        return helper(["--ensure", ip]) != nil
    }
}

func after(_ s: Double, _ f: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
}

// MARK: - Views

struct Ring: View {
    var color: Color
    var size: CGFloat
    var body: some View {
        Circle().strokeBorder(color, lineWidth: size * 0.22).frame(width: size, height: size)
    }
}

struct Tag: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.35)))
    }
}

struct StepRow: View {
    var title: String
    var state: StepState
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .waiting: Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                case .running: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(red)
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(state == .waiting ? .secondary : .primary)
            Spacer()
        }
    }
}

struct Splash: View {
    @ObservedObject var model: Model
    var icon: NSImage?

    var accent: Color { model.isFailed ? red : green }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 44, height: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude · 安全启动").font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 5) {
                        Ring(color: green, size: 10)
                        Text("出口 IP 检测由 cleanip.io 与 ip.net.coffee 提供").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            VStack(spacing: 9) {
                ForEach(model.titles.indices, id: \.self) { i in
                    StepRow(title: model.titles[i], state: model.steps[i])
                }
            }

            result
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.25)))

            if model.isFailed {
                HStack {
                    Button("强制启动…") { model.forceLaunch() }.disabled(model.forcing)
                    Spacer()
                    Button("关闭") { NSApp.terminate(nil) }.keyboardShortcut(.cancelAction).disabled(model.forcing)
                    Button("重新检测") { model.run() }.keyboardShortcut(.defaultAction).disabled(model.forcing)
                }
                if model.forcing { Text("正在建立本次授权与 IP 监听…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder var result: some View {
        if let r = model.report {
            VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.ip ?? "—").font(.system(size: 19, weight: .bold, design: .monospaced))
                    HStack(spacing: 6) {
                        if let n = r.native { Tag(text: n, color: green) }
                        if let t = r.type { Tag(text: t, color: t.contains("住宅") ? green : red) }
                        if let w = r.network { Tag(text: w, color: .blue) }
                        if let t = r.trust { Tag(text: "可信度 \(Int(t))", color: Int(t) >= Model.minTrust ? green : red) }
                    }
                    if let l = r.location { Text(l).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(r.score.map(String.init) ?? "—")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                    HStack(spacing: 2) {
                        Text(r.grade ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                        Text("/ 100").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let why = model.failure {
                Divider().padding(.vertical, 10)
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(red)
            }
            }
        } else if let why = model.failure {
            Label(why, systemImage: "wifi.exclamationmark").font(.system(size: 12.5, weight: .medium)).foregroundStyle(red)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测出口 IP…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App

func appIcon() -> NSImage? {
    if let p = Bundle.main.path(forResource: "AppIcon", ofType: "png") { return NSImage(contentsOfFile: p) }
    return NSImage(contentsOfFile: "\(home)/.claude/launcher/AppIcon.png")
}

@MainActor func snapshot(to dir: String) {
    let ok = Report(ok: true, ip: "203.0.113.10", score: 97, grade: "A+", type: "住宅 IP", native: "原生 IP", network: "ISP", location: "美国 · 示例州 · 示例市", trust: 100)
    var bad = ok
    bad.ok = false
    bad.score = 88
    bad.grade = "A"
    var coffee = ok
    coffee.ok = false
    coffee.trust = 55
    coffee.why = "net.coffee: trust 55 < 80"
    let cases: [(String, Report, [StepState], String?)] = [
        ("splash-pass", ok, [.done, .done, .done, .done, .done], nil),
        ("splash-fail", bad, [.done, .failed, .waiting, .waiting, .waiting], Model().reason(bad)),
        ("splash-running", ok, [.done, .done, .done, .running, .waiting], nil),
        ("splash-coffee-fail", coffee, [.done, .done, .failed, .waiting, .waiting], coffee.why),
    ]
    for scheme in [ColorScheme.light, .dark] {
        for (name, r, steps, why) in cases {
            let m = Model()
            m.report = r
            m.steps = steps
            m.failure = why
            let view = Splash(model: m, icon: appIcon()).padding(20).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: Splash(model: model, icon: appIcon()))
        host.layoutSubtreeIfNeeded()
        window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--preview-force") {
            model.steps[0] = .failed
            model.failure = "预览：CleanIP 暂时不可用"
        } else { model.run() }
        // Keep the borderless window sized to its content as steps change.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = self.window.contentView else { return }
                let s = v.fittingSize
                if s != self.window.frame.size {
                    var f = self.window.frame
                    f.origin.y += f.size.height - s.height
                    f.size = s
                    self.window.setFrame(f, display: true)
                }
            }
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--confirm-session"), i + 1 < args.count, let pid = Int32(args[i + 1]), pid > 1 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let approved = MainActor.assumeIsolated { confirmForce("Claude Code 会话的 CleanIP / ip.net.coffee 检测失败或未通过") }
    guard approved, let ip = helper(["--baseline"]), helper(["--grant", String(pid), ip]) != nil else { exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { snapshot(to: args[i + 1]) }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
