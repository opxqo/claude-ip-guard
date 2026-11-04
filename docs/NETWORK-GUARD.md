# Claude network consistency guard

This local guard protects Claude Code and its Claude Desktop host. It does not target Codex.

## Entry points

- `Claude (IP Guard).app`: checks CleanIP and ip.net.coffee, then waits for the user to press 启动 Claude. Only after that does it start the monitor, wait for it to be healthy with the same public IPv4, and open Claude Desktop. A passing verdict older than 2 minutes is discarded and the check runs again.
- `claude-guard`: the terminal gate uses the same checker and readiness handshake.
- `cleanip@local-mods`: uses the shared checker at session start, verifies live egress before accepting a prompt, and checks monitoring/authorization before each model step. Errors in the gating hooks fail closed.
- `claude-desktop-guard`: delegates to the native launcher.

## Network transport and monitor

`claude_network.py` is the common transport for CleanIP and exit-IP queries. It explicitly uses the current system HTTPS proxy when enabled, otherwise inherits the process proxy environment and OS route (including TUN). PAC-only or SOCKS-only system proxy configurations are rejected rather than silently queried through a different path. HTTPS certificate verification remains enabled and redirects cannot downgrade to HTTP. Probes use IPv4.

If the normal CleanIP connection fails at DNS, TCP or TLS handshake, that one request can retry using an HTTPS public-DNS A answer and curl `--resolve`. The URL, TLS hostname validation and proxy context remain in place. No system DNS or Clash configuration is edited.

ipify, icanhazip and checkip.amazonaws.com are queried concurrently (5 s per request). Successful results must be valid public IPv4 addresses and agree. Unavailable services are tolerated as long as at least one returns a valid IP and every valid answer matches. A prompt-time check (`claude-ip-override --verify`) reuses the monitor heartbeat when it is at most 5 seconds old and only probes live when it is older. No valid results, conflicting results, an unexpected IP, or a proxy change during measurement fails the check.

The monitor uses a singleton file lock and a fixed baseline. It publishes a healthy heartbeat only after a passing probe. Readiness checks verify the monitor process identity, heartbeat age (up to 10 seconds), baseline IP, and current proxy fingerprint. A lease prevents rebaselining while a previously observed Claude process is still alive, even if the monitor has exited.

Checks repeat after a 3-second wait; DNS, proxy reads and HTTPS timeouts contribute to detection latency. On a valid mismatching/conflicting IP, the monitor closes matching Claude processes and their descendants using PID birth checks, explicitly excluding Codex and the monitor's own descendants. If no reliable IP can be measured, it first publishes a retrying state and suspends owned Claude processes with SIGSTOP. It retries after a 2-second wait for an approximately 30-second window. A matching baseline restores healthy state and resumes the same processes with SIGCONT. Persistent failure closes them. The window includes network measurement latency. A pause journal lets a replacement monitor recover the same paused processes and does not resume processes that were already manually stopped. A monitor exiting unexpectedly while owning paused processes closes those processes rather than leaving them indefinitely frozen. Logs rotate at 1 MB with three backups.

## CleanIP lookup

`claude-ip-check` retries a failed CleanIP lookup (network error, timeout) up to 3 times, 2 seconds apart. A lookup that returns a clear verdict (score at or below the threshold, non-residential) is never retried. Stale `force-*.json` grants whose Claude process is gone are removed whenever a new grant is written.

## Second provider

After CleanIP passes, `claude-ip-check` also asks `https://ip.net.coffee/api/iprisk/<ip>` (through the same transport, `claude-ip-override --fetch-iprisk`). Both must pass: no datacenter/VPN/proxy/Tor/abuser flag, residential, `trust_score >= MIN_TRUST`, and the answer's `cidr` must contain the IP CleanIP reported. A failed lookup is retried 3 times and then fails closed. This is an undocumented page API and may change.

## Force mode

Two separate native confirmation dialogs are required. The override skips only the CleanIP score/residential policy for the current Claude process. It still requires a successful exit-IP probe and healthy monitoring. Authorization is bound to the process ID and birth time, and is invalid without a live matching monitor. It cannot silently change the active baseline. No text entry is required.

## Verification and limits

Run `python3 launcher/tests/test_network.py` for isolated network/lifecycle tests and `claude plugin test ~/.claude/local-mods/cleanip` for mod checks. `claude-ip-watch --dry-run <IPv4>` performs a read-only network check without starting a monitor or signalling processes.

This is an application-level detection and stop mechanism. It does not bind all Claude network sockets, install a firewall, enforce destination-based proxy rules, or cover IPv6. Equal exit-IP probes do not prove that Anthropic destinations use the same route. A running request can send traffic before a change is detected; a killed monitor is detected at a later guarded request. Directly opening the official app or disabling the mod can bypass admission checks. Socket-level guarantees require separately configured proxy/TUN/firewall controls.

Replacing scripts while a monitor is running does not replace the in-memory monitor; close Claude and use the launcher again to load the new version.

Retry verification: `python3 launcher/tests/test_network_retry.py` exercises transient failures, recovery, persistent failure, IP changes and STOP/CONT on a disposable sleep child. Live update preserved the existing Claude process identities and baseline; no user session was restarted.
