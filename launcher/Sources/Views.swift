// SwiftUI views: one set of cards shared by the menu bar panel and the console window.
import AppKit
import Charts
import SwiftUI

// MARK: - Look

enum Palette {
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.40)
    static let warn = Color(red: 1.00, green: 0.62, blue: 0.10)
    static let bad = Color(red: 1.00, green: 0.30, blue: 0.27)
    static let idle = Color(white: 0.55)
    static let accent = Color(red: 0.36, green: 0.52, blue: 1.00)
    static func of(_ l: Level) -> Color {
        switch l { case .ok: return ok; case .retry: return warn; case .bad: return bad; case .idle: return idle }
    }
}

struct CardStyle: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .primary).opacity(tint == nil ? 0.05 : 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.28)))
    }
}

extension View {
    func card(_ tint: Color? = nil) -> some View { modifier(CardStyle(tint: tint)) }
}

struct CardTitle: View {
    var text: String
    var symbol: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct PulseDot: View {
    var level: Level
    var size: CGFloat = 10
    @State private var pulse = false
    var body: some View {
        let c = Palette.of(level)
        ZStack {
            if level == .ok || level == .retry {
                Circle().fill(c.opacity(0.35)).frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(pulse ? 1 : 0.5).opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: level == .retry ? 0.9 : 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(c).frame(width: size, height: size)
                .shadow(color: c.opacity(0.7), radius: size * 0.5)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { pulse = true }
    }
}

struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ScoreRing: View {
    var score: Int?
    var grade: String?
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(score.map(String.init) ?? "—").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                Text(grade ?? "分").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

// MARK: - Cards

struct HeaderView: View {
    @ObservedObject var m: GuardModel
    var compact: Bool
    var onSettings: () -> Void
    var onWindow: (() -> Void)?

    var level: Level { m.phase == .active || m.phase == .ended ? m.status.level : .idle }
    var headline: String {
        switch m.phase {
        case .active: return m.status.label
        case .ended: return "守护已结束"
        case .checking: return "正在检测出口 IP"
        case .establishing: return "正在建立监控"
        case .decided: return m.passed ? "检测通过" : "检测未通过"
        }
    }
    var subline: String {
        if m.phase == .active, let s = m.since {
            let policy = m.onUnstable == "kill" ? "波动即关闭" : "波动暂停重试"
            return "已守护 \(clock(m.now.timeIntervalSince(s))) · \(policy)"
        }
        if m.phase == .ended { return m.endReason ?? "监控已停止" }
        return "Claude IP Guard"
    }

    var body: some View {
        HStack(spacing: 10) {
            PulseDot(level: level, size: compact ? 9 : 11)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(headline).font(.system(size: compact ? 15 : 17, weight: .semibold))
                    if m.mode == .forced { Pill(text: "强制", color: Palette.bad) }
                }
                Text(subline).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            if let onWindow {
                Button(action: onWindow) { Image(systemName: "macwindow") }.buttonStyle(.borderless).help("打开控制台")
            }
            Button(action: onSettings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("设置")
        }
    }
}

struct IPCard: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        let r = m.report
        let ip = m.sessionIP ?? m.health?.ip ?? r?.ip
        let ringColor: Color = (r?.ok ?? false) ? Palette.ok : (r?.trust == nil ? Palette.idle : Palette.bad)
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: "Claude 出口 IP", symbol: "globe.americas.fill", trailing: r?.location.map { String($0.prefix(18)) })
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ip ?? "—").font(.system(size: 22, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                    HStack(spacing: 4) {
                        if let t = r?.type { Pill(text: t, color: t.contains("非") ? Palette.bad : Palette.ok) }
                        if let n = r?.native { Pill(text: n, color: Palette.accent) }
                        ForEach(r?.flags ?? [], id: \.self) { f in Pill(text: f, color: Palette.bad) }
                        if let s = r?.score { Pill(text: "CleanIP \(s)\(r?.grade.map { " " + $0 } ?? "") · 参考", color: Palette.idle) }
                    }
                    if let org = r?.org { Text(org).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                ScoreRing(score: r?.trust.map { Int($0) }, grade: r?.trust.map(trustLabel) ?? "可信度", color: ringColor)
            }
        }
        .card()
    }
}

struct ProbeCard: View {
    @ObservedObject var m: GuardModel
    static let slots = 100

    var body: some View {
        let s = m.samples.suffix(Self.slots)
        let ok = s.compactMap(\.latency)
        let ceiling = max(400, (ok.max() ?? 0) + 60)
        let offset = Self.slots - s.count
        let last = m.health?.latency_ms
        let beat = m.health?.heartbeat.map { m.now.timeIntervalSince1970 - $0 }
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: "出口探测", symbol: "waveform.path.ecg",
                      trailing: [last.map { "\($0) ms" }, beat.map { "心跳 \(max(0, Int($0)))s" }].compactMap { $0 }.joined(separator: " · "))
            Chart {
                ForEach(Array(s.enumerated()), id: \.element.id) { i, sample in
                    BarMark(x: .value("t", i + offset), y: .value("ms", sample.latency ?? ceiling), width: .fixed(2))
                        .foregroundStyle(color(sample).opacity(sample.latency == nil ? 0.85 : 0.9))
                        .cornerRadius(1)
                }
            }
            .chartXScale(domain: 0...(Self.slots - 1))
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, ceiling / 2, ceiling]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)").font(.system(size: 8)).foregroundStyle(.tertiary) } }
                }
            }
            .frame(height: 64)
            HStack {
                Text(ok.isEmpty ? "等待探测数据…" : "平均 \(ok.reduce(0, +) / max(1, ok.count)) ms").foregroundStyle(.secondary)
                Spacer()
                let failed = s.filter { $0.latency == nil }.count
                Text("失败 \(failed) / \(s.count)").foregroundStyle(failed > 0 ? Palette.warn : .secondary)
            }
            .font(.system(size: 10.5)).monospacedDigit()
        }
        .card()
    }

    func color(_ s: Sample) -> Color {
        if s.latency == nil { return Palette.bad }
        if s.level == .retry { return Palette.warn }
        return (s.latency ?? 0) > 1500 ? Palette.warn : Palette.ok
    }
}

struct ClientRow: View {
    var symbol: String
    var name: String
    var detail: String
    var running: Bool
    var action: String
    var enabled: Bool
    var perform: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .medium))
                HStack(spacing: 4) {
                    Circle().fill(running ? Palette.ok : Palette.idle.opacity(0.6)).frame(width: 5, height: 5)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            Button(action: perform) { Text(action).font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 4) }
                .buttonStyle(.bordered).controlSize(.small).disabled(!enabled)
        }
    }
}

struct ClientsCard: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        let active = m.phase == .active
        let c = m.clients
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: "Claude 客户端", symbol: "square.stack.3d.up.fill", trailing: "\(c.processes) 个进程")
            ClientRow(symbol: "macwindow", name: "Claude 桌面端",
                      detail: c.desktop > 0 ? "运行中 · \(c.desktop_sessions) 个 Code 会话" : "未运行",
                      running: c.desktop > 0, action: c.desktop > 0 ? "切换" : "启动", enabled: active, perform: m.launchDesktop)
            ClientRow(symbol: "terminal", name: "Claude Code CLI",
                      detail: c.cli > 0 ? "运行中 · " + (c.cli_sources.map(cliSummary).flatMap { $0.isEmpty ? nil : $0 } ?? "\(c.cli) 个会话")
                                        : "在 \(Clients.Terminal(rawValue: m.terminal)?.title ?? "Terminal") 中打开",
                      running: c.cli > 0, action: "新建", enabled: active, perform: m.launchCLI)
            if let msg = m.route.message {
                Label(msg, systemImage: m.route.kind == .localDown ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(m.route.kind == .localDown ? Palette.warn : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !active { Text("建立监控后才能启动客户端").font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
        .card()
    }
}

struct StabilityCard: View {
    @ObservedObject var m: GuardModel
    var rows: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: "近 24 小时", symbol: "chart.bar.xaxis",
                      trailing: m.day.lastIssue.map { "上次异常 \(ago(m.now.timeIntervalSince($0)))" } ?? "无异常")
            HStack(spacing: 0) {
                stat("\(m.day.pauses)", "次暂停", m.day.pauses > 0 ? Palette.warn : Palette.ok)
                Divider().frame(height: 28)
                stat("\(m.day.kills)", "次关闭", m.day.kills > 0 ? Palette.bad : Palette.ok)
            }
            if rows > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.events.suffix(rows).reversed()) { e in
                        HStack(spacing: 6) {
                            Image(systemName: icon(e.kind)).font(.system(size: 9, weight: .bold)).foregroundStyle(tint(e)).frame(width: 12)
                            Text(shortStamp.string(from: e.time)).foregroundStyle(.tertiary).monospacedDigit()
                            Text(describe(e)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.system(size: 10.5))
                    }
                }
            }
        }
        .card()
    }
    func stat(_ n: String, _ label: String, _ c: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(n).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(c).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    func icon(_ k: EventKind) -> String {
        switch k { case .start: return "play.fill"; case .exit: return "stop.fill"; case .pause: return "pause.fill"; case .kill: return "xmark" }
    }
    func tint(_ e: Event) -> Color {
        switch e.kind { case .kill: return Palette.bad; case .pause: return e.text == "失败" ? Palette.bad : Palette.warn; default: return Palette.idle }
    }
}

struct KillButton: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        let armed = m.killArmed.map { m.now.timeIntervalSince($0) < 3 } ?? false
        Button(action: m.pressKill) {
            HStack(spacing: 8) {
                Image(systemName: armed ? "exclamationmark.octagon.fill" : "power")
                    .font(.system(size: 13, weight: .bold))
                Text(armed ? "再按一次，关闭 \(m.clients.processes) 个进程" : "立即关闭全部 Claude")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                KeyCap(text: "⌃⌥⌘K")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                LinearGradient(colors: armed ? [Color(red: 0.85, green: 0.1, blue: 0.1), Color(red: 0.6, green: 0.0, blue: 0.05)]
                                             : [Color(red: 1.0, green: 0.36, blue: 0.32), Color(red: 0.86, green: 0.16, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: Palette.bad.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("全局快捷键 ⌃⌥⌘K 直接关闭，无需确认")
    }
}

struct PolicyPicker: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        HStack(spacing: 8) {
            Text("网络波动时").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { m.onUnstable }, set: { m.setPolicy($0) })) {
                Text("暂停重试 30s").tag("pause")
                Text("立即关闭").tag("kill")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        }
    }
}

struct ChoiceBanner: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("监控已建立，接下来启动什么？").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                choice("macwindow", "桌面端", m.launchDesktop)
                choice("terminal", "CLI", m.launchCLI)
                choice("eye", "只监控", m.monitorOnly)
            }
        }
        .card(Palette.accent)
    }
    func choice(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EndedBanner: View {
    @ObservedObject var m: GuardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(m.endReason ?? "监控已停止", systemImage: "bolt.horizontal.circle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.bad)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("守护已停止，重新检测后才能继续启动 Claude").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("重新检测", action: m.recheck).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .card(Palette.bad)
    }
}

struct Toast: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

// MARK: - Screens

struct Dashboard: View {
    @ObservedObject var m: GuardModel
    var compact: Bool
    var onSettings: () -> Void
    var onWindow: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            HeaderView(m: m, compact: compact, onSettings: onSettings, onWindow: onWindow)
            if m.phase == .ended { EndedBanner(m: m) }
            if m.phase == .active && m.showChoice { ChoiceBanner(m: m) }
            if m.phase != .active && m.phase != .ended {
                SetupCard(m: m, onWindow: onWindow)
            }
            IPCard(m: m)
            ProbeCard(m: m)
            ClientsCard(m: m)
            StabilityCard(m: m, rows: compact ? 3 : 6)
            KillButton(m: m)
            PolicyPicker(m: m)
        }
        .padding(14)
        .frame(width: compact ? 340 : 420)
        .overlay(alignment: .bottom) {
            if let n = m.notice { Toast(text: n).padding(.bottom, 56).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.notice)
        .animation(.easeInOut(duration: 0.2), value: m.phase)
    }
}

/// Shown in the panel while the guard is not running yet.
struct SetupCard: View {
    @ObservedObject var m: GuardModel
    var onWindow: (() -> Void)?
    var body: some View {
        HStack {
            Text(m.phase == .decided ? (m.passed ? "检测已通过，去控制台建立监控" : "检测未通过，可在控制台强制启动") : "正在检测出口 IP…")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            if let onWindow { Button("打开控制台", action: onWindow).controlSize(.small) }
        }
        .card(Palette.accent)
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
                case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.bad)
                }
            }
            .frame(width: 16, height: 16)
            Text(title).font(.system(size: 12.5)).foregroundStyle(state == .waiting ? .secondary : .primary)
            Spacer()
        }
    }
}

/// The console window before the guard runs: check, then establish or force.
struct LaunchFlow: View {
    @ObservedObject var m: GuardModel
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon = appIcon() { Image(nsImage: icon).resizable().frame(width: 46, height: 46) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude IP Guard").font(.system(size: 18, weight: .bold))
                    Text("网络维稳控制台 · 以 ip.net.coffee 为准，CleanIP 仅参考")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onSettings) { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }

            VStack(spacing: 9) {
                ForEach(m.titles.indices, id: \.self) { i in StepRow(title: m.titles[i], state: m.steps[i]) }
            }
            .card()

            IPCard(m: m)

            if let why = m.failure {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .card(Palette.bad)
            }

            actions
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder var actions: some View {
        switch m.phase {
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在检测出口 IP…").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .establishing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在建立 IP 监控…").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .decided where m.passed:
            HStack {
                Button("重新检测", action: m.startCheck)
                Spacer()
                Button(action: { m.establish(.verified) }) { Text("建立监控").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        case .decided:
            HStack {
                Button(action: m.forceStart) {
                    Label("仍然强制启动", systemImage: "bolt.shield")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.bad)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Palette.bad.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.bad.opacity(0.45)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: m.startCheck) { Text("重新检测").frame(minWidth: 100) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        default:
            EmptyView()
        }
    }
}

struct ConsoleRoot: View {
    @ObservedObject var m: GuardModel
    var onSettings: () -> Void
    var body: some View {
        Group {
            if m.phase == .active || m.phase == .ended {
                Dashboard(m: m, compact: false, onSettings: onSettings)
            } else {
                LaunchFlow(m: m, onSettings: onSettings)
            }
        }
        .padding(.top, 18)  // under the transparent title bar
    }
}

struct SettingsView: View {
    @ObservedObject var m: GuardModel
    var close: () -> Void
    @State private var trust = Conf.minTrust
    @State private var login = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "CLI", symbol: "terminal")
                Picker("打开方式", selection: $m.terminal) {
                    ForEach(Clients.Terminal.allCases, id: \.rawValue) { t in
                        Text(t.title + (t.installed ? "" : "（未安装）")).tag(t.rawValue)
                    }
                }
                HStack {
                    Text("启动目录").font(.system(size: 12))
                    Text(m.cliDirectory).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false
                        p.directoryURL = URL(fileURLWithPath: m.cliDirectory)
                        if p.runModal() == .OK, let u = p.url { m.cliDirectory = u.path }
                    }
                }
            }.card()
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "检测门槛（下次检测生效）", symbol: "slider.horizontal.3")
                Stepper("ip.net.coffee 可信度不低于 \(trust)", value: $trust, in: 0...100)
                Text("CleanIP 分数只作参考，不影响放行。").font(.system(size: 11)).foregroundStyle(.secondary)
            }.card()
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "守护", symbol: "shield.lefthalf.filled")
                PolicyPicker(m: m)
                Toggle("登录时打开控制台", isOn: $login).onChange(of: login) { _, on in LoginItem.set(on) }
                Button("打开说明 NETWORK-GUARD.md") { NSWorkspace.shared.open(URL(fileURLWithPath: guidePath)) }.buttonStyle(.link)
            }.card()
            HStack {
                Spacer()
                Button("完成") { m.setMinTrust(trust); close() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 400)
    }
}

func appIcon() -> NSImage? {
    if let p = Bundle.main.path(forResource: "AppIcon", ofType: "png") { return NSImage(contentsOfFile: p) }
    return NSImage(contentsOfFile: "\(home)/.claude/launcher/AppIcon.png")
}
