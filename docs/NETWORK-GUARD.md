# Claude network consistency guard

This local guard protects Claude Code and its Claude Desktop host. It does not target Codex.

## Entry points

- `Claude (IP Guard).app`: a resident console (Dock window, menu bar panel, global ⌃⌥⌘K). It runs `claude-ip-check` (ip.net.coffee method, CleanIP for reference); on a pass the user establishes the guard, on a failure the user may force it after one confirmation. Establishing starts the monitor with a console hold and writes the console session. The user then opens Claude Desktop, the CLI (Terminal or Warp), or nothing. A passing verdict older than 2 minutes is discarded and the check runs again.
- `claude-guard`: the terminal gate uses the same checker and readiness handshake.
- `cleanip@local-mods`: at session start it reuses a live console session (verified, or forced) and otherwise runs the shared checker; verifies live egress before accepting a prompt, and checks monitoring/authorization before each model step. Errors in the gating hooks fail closed.
- `claude-desktop-guard`: delegates to the native launcher.

## Console session, hold and kill

`claude-ip-override --session-begin <ip> verified|forced <report>` may only be called by the console executable. It writes `run/guard-session.json` (console pid, birth time, IP, mode, the check report) and `run/ip-watch-hold.json`. The session is valid only while that exact console process lives. A forced session authorises `--status` for any process with a Claude ancestor while the monitor is healthy, so desktop and CLI sessions started under it need no further confirmation. Per-process `force-<pid>.json` grants remain for sessions started outside the console (`--confirm-session`, now one dialog).

While the hold's process (pid + birth) lives, the monitor does not exit when no Claude process is running. Once the hold is released it exits as soon as no Claude process is left.

`claude-ip-watch --kill-all` SIGKILLs every target (same selection as an IP change: desktop, CLI and descendants, Codex excluded, birth time rechecked) and logs `KILL: 手动一键关闭`. `--list` reports desktop, embedded-session and CLI counts. `claude-ip-override --stop-watch` sends SIGTERM to the monitor named in `ip-watch.pid`.

`ON_UNSTABLE` in `ip-guard.conf` is re-read on every probe. With `kill`, the first failed probe closes all Claude processes instead of pausing. A confirmed IP change always closes immediately. After a close, the health file keeps `state: blocked` and the reason, rather than `stopped`. Health also carries `latency_ms` (the last probe's duration), `on_unstable` and `held`.

The console reads `ip-watch-health.json` every second and applies the same freshness rule as `claude_network.health()`. It is not part of any gate: its displayed state never authorises Claude.

## Network transport and monitor

`claude_network.py` is the common transport for every lookup (Claude trace, ip.net.coffee, CleanIP, exit-IP probes). It explicitly uses the current system HTTPS proxy when enabled, otherwise inherits the process proxy environment and OS route (including TUN). PAC-only or SOCKS-only system proxy configurations are rejected rather than silently queried through a different path. HTTPS certificate verification remains enabled and redirects cannot downgrade to HTTP. Probes use IPv4.

If the normal CleanIP connection fails at DNS, TCP or TLS handshake, that one request can retry using an HTTPS public-DNS A answer and curl `--resolve`. The URL, TLS hostname validation and proxy context remain in place. No system DNS or Clash configuration is edited.

Each probe queries ipify, icanhazip and checkip.amazonaws.com, plus Cloudflare's `/cdn-cgi/trace` on `api.anthropic.com` (Claude Code) and `claude.ai` (the desktop app), concurrently (5 s per request). Generic answers must be valid public IPv4 addresses and agree; unavailable generic services are tolerated as long as one answers. At least one Anthropic trace must answer, and every Anthropic answer must equal the generic IP: a proxy rule that routes Anthropic elsewhere (split routing) is treated as an IP change and closes Claude. No Anthropic answer is treated as unavailable (pause/retry). A prompt-time check (`claude-ip-override --verify`) reuses the monitor heartbeat when it is at most 5 seconds old and only probes live when it is older. No valid results, conflicting results, an unexpected IP, or a proxy change during measurement fails the check.

The monitor uses a singleton file lock and a fixed baseline. It publishes a healthy heartbeat only after a passing probe. Readiness checks verify the monitor process identity, heartbeat age (up to 10 seconds), baseline IP, and current proxy fingerprint. A lease prevents rebaselining while a previously observed Claude process is still alive, even if the monitor has exited.

Checks repeat after a 3-second wait; DNS, proxy reads and HTTPS timeouts contribute to detection latency. On a valid mismatching/conflicting IP, the monitor closes matching Claude processes and their descendants using PID birth checks, explicitly excluding Codex and the monitor's own descendants. If no reliable IP can be measured, it first publishes a retrying state and suspends owned Claude processes with SIGSTOP. It retries after a 2-second wait for an approximately 30-second window. A matching baseline restores healthy state and resumes the same processes with SIGCONT. Persistent failure closes them. The window includes network measurement latency. A pause journal lets a replacement monitor recover the same paused processes and does not resume processes that were already manually stopped. A monitor exiting unexpectedly while owning paused processes closes those processes rather than leaving them indefinitely frozen. Logs rotate at 1 MB with three backups.

## Launch check (ip.net.coffee method)

`claude-ip-check` follows https://ip.net.coffee/claude/ . It reads the exit Claude sees from `https://claude.ai/cdn-cgi/trace`, then asks `https://ip.net.coffee/api/iprisk/<ip>`. It passes only when the exit is a public IPv4; the answer's `cidr` contains it; there is no datacenter/VPN/proxy/Tor/abuser flag; it is residential (`isResidential` or `asn_kind`); `trust_score >= MIN_TRUST`; the country (ip.net.coffee `countryCode`, or the trace's `loc`) is not one Claude does not serve; and a full monitor probe confirms the generic and Anthropic exits equal it (no split routing). The trace and the risk lookup are retried 3 times, 2 seconds apart, and then fail closed. The risk endpoint is an undocumented page API and may change.

CleanIP (`https://cleanip.io/cli`) is fetched in parallel, at most twice, and reported under `cleanip` (and `score`/`grade`/`native` at the top level) for display only. Its result never changes the verdict, and its failure is recorded in `cleanip_error`.

Stale `force-*.json` grants whose Claude process is gone are removed whenever a new grant is written.

## Force mode

One native confirmation is required (in the console, or `--confirm-session` for an outside session). The override skips only the launch-check verdict. It still requires a successful exit-IP probe and healthy monitoring. Authorization is bound to the process ID and birth time, and is invalid without a live matching monitor. It cannot silently change the active baseline. No text entry is required.

## Verification and limits

Run `python3 launcher/tests/test_network.py` for isolated network/lifecycle tests and `claude plugin test ~/.claude/local-mods/cleanip` for mod checks. `claude-ip-watch --dry-run <IPv4>` performs a read-only network check without starting a monitor or signalling processes.

This is an application-level detection and stop mechanism. It does not bind all Claude network sockets, install a firewall, enforce destination-based proxy rules, or cover IPv6. Equal exit-IP probes do not prove that Anthropic destinations use the same route. A running request can send traffic before a change is detected; a killed monitor is detected at a later guarded request. Directly opening the official app or disabling the mod can bypass admission checks. Socket-level guarantees require separately configured proxy/TUN/firewall controls.

Replacing scripts while a monitor is running does not replace the in-memory monitor; quit the console (which stops the monitor) and open it again to load the new version.

Retry verification: `python3 launcher/tests/test_network_retry.py` exercises transient failures, recovery, persistent failure, IP changes and STOP/CONT on a disposable sleep child. Live update preserved the existing Claude process identities and baseline; no user session was restarted.
