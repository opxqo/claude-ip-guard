// Starting and stopping Claude clients, and the CLI's API route preflight.
import AppKit
import Darwin

struct ClientCounts: Decodable, Equatable {
    var desktop = 0           // Claude.app main processes
    var desktop_sessions = 0  // Claude Code sessions inside the desktop app
    var cli = 0               // terminal CLI sessions
    var processes = 0         // everything a kill would close
}

enum Clients {
    static func counts() -> ClientCounts? {
        let o = run(watchTool, ["--list"])
        guard o.status == 0 else { return nil }
        return try? JSONDecoder().decode(ClientCounts.self, from: Data(o.stdout.utf8))
    }

    /// SIGKILL every Claude Code process (desktop, CLI, children). Returns how many were closed.
    static func killAll() -> Int? {
        let o = run(watchTool, ["--kill-all"])
        guard o.status == 0, let d = try? JSONSerialization.jsonObject(with: Data(o.stdout.utf8)) as? [String: Any] else { return nil }
        return d["killed"] as? Int
    }

    static func openDesktop(_ done: @escaping (String?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: claudeApp, configuration: config) { _, err in
            main { done(err?.localizedDescription) }
        }
    }

    enum Terminal: String, CaseIterable { case terminal, warp
        var title: String { self == .terminal ? "Terminal" : "Warp" }
        var installed: Bool {
            FileManager.default.fileExists(atPath: self == .terminal ? "/System/Applications/Utilities/Terminal.app" : "/Applications/Warp.app")
        }
    }

    /// Opens the real CLI (not the claude-guard alias: the console session already covers it).
    static func openCLI(in terminal: Terminal, directory: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: claudeCLI) else { return "找不到 \(claudeCLI)" }
        switch terminal {
        case .terminal:
            let command = "cd \(shellQuote(directory)) && \(shellQuote(claudeCLI))"
            let source = """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscape(command))"
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { return (error[NSAppleScript.errorMessage] as? String) ?? "无法控制 Terminal（请在 系统设置 › 隐私与安全性 › 自动化 中允许）" }
            return nil
        case .warp:
            // Warp runs commands from a launch configuration file.
            let dir = "\(home)/.warp/launch_configurations"
            let path = "\(dir)/claude-ip-guard.yaml"
            let yaml = """
            ---
            name: Claude IP Guard CLI
            windows:
              - tabs:
                  - title: Claude Code
                    layout:
                      cwd: \(yamlQuote(directory))
                      commands:
                        - exec: \(yamlQuote(shellQuote(claudeCLI)))
            """
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try yaml.write(toFile: path, atomically: true, encoding: .utf8)
            } catch { return "无法写入 Warp 启动配置：\(error.localizedDescription)" }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "warp://launch/\(encoded)"), NSWorkspace.shared.open(url) else { return "无法打开 Warp" }
            return nil
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
func yamlQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

// MARK: - CLI route preflight (~/.claude/settings.json env.ANTHROPIC_BASE_URL)

struct Route: Equatable {
    enum Kind: Equatable { case official, localUp, localDown, custom }
    var kind: Kind
    var url: String?
    var message: String? {
        switch kind {
        case .official: return nil
        case .localUp: return "CLI 走本地代理 \(url ?? "")（CC Switch 等），不是官方账号"
        case .localDown: return "CLI 会连本地代理 \(url ?? "")，但它没在运行；请在 CC Switch 切回官方"
        case .custom: return "CLI 使用自定义 API 地址 \(url ?? "")"
        }
    }
}

/// Reads the base URL the CLI will use; the desktop app ignores this setting.
func baseURL(fromSettings data: Data?) -> String? {
    guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let env = root["env"] as? [String: Any] else { return nil }
    return env["ANTHROPIC_BASE_URL"] as? String
}

func routeFor(_ base: String?, listening: (String, Int) -> Bool) -> Route {
    guard let base, let u = URL(string: base), let host = u.host, !host.isEmpty else { return Route(kind: .official) }
    if host == "api.anthropic.com" { return Route(kind: .official) }
    let local = ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    guard local else { return Route(kind: .custom, url: base) }
    let port = u.port ?? (u.scheme == "https" ? 443 : 80)
    let short = "\(host):\(port)"
    return Route(kind: listening(host == "localhost" || host == "0.0.0.0" ? "127.0.0.1" : host, port) ? .localUp : .localDown, url: short)
}

/// A TCP connect to a local port, 300 ms at most.
func portListening(_ host: String, _ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, host == "::1" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else { return false }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 300) == 1 else { return false }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
    static let label = "local.claude-ip-guard"
    static var path: String { "\(home)/Library/LaunchAgents/\(label).plist" }
    static var enabled: Bool { FileManager.default.fileExists(atPath: path) }
    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(atPath: path); return }
        let app = Bundle.main.bundlePath
        guard app.hasSuffix(".app") else { return }
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", app], "RunAtLoad": true]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            FileManager.default.createFile(atPath: path, contents: d)
        }
    }
}
