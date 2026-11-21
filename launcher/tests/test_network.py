import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

BIN = Path(__file__).resolve().parents[2] / 'bin'
sys.path.insert(0, str(BIN))
import claude_network as net


def module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


watch = module('watch', BIN / 'claude-ip-watch')
override = module('override', BIN / 'claude-ip-override')
check = module('check', BIN / 'claude-ip-check')


class NetworkTests(unittest.TestCase):
    def test_cleanip_dns_fallback_preserves_hostname_and_proxy_context(self):
        ctx = (['--proxy', 'http://127.0.0.1:7897'], 'unchanged')
        with patch.object(net, 'transport', return_value=ctx), patch.object(net, '_curl_fetch', side_effect=[
                net.QueryError(35, 'TLS failed'), json.dumps({'Status': 0, 'Answer': [{'type': 1, 'data': '8.8.8.8'}]}), 'cleanip report']) as query:
            self.assertEqual(net.fetch('https://cleanip.io/cli', 6), 'cleanip report')
            self.assertEqual(query.call_args.args, ('https://cleanip.io/cli', 6, ctx))
            self.assertEqual(query.call_args.kwargs, {'resolve': '8.8.8.8'})

    def test_dns_fallback_does_not_override_cert_errors_or_private_addresses(self):
        with patch.object(net, 'transport', return_value=([], 'ctx')), patch.object(net, '_curl_fetch', side_effect=net.QueryError(60, 'certificate invalid')) as query:
            with self.assertRaises(net.QueryError): net.fetch('https://cleanip.io/cli')
            self.assertEqual(query.call_count, 1)
        with patch.object(net, 'transport', return_value=([], 'ctx')), patch.object(net, '_curl_fetch', side_effect=[net.QueryError(35, 'TLS failed'), json.dumps({'Status': 0, 'Answer': [{'type': 1, 'data': '127.0.0.1'}]})]) as query:
            with self.assertRaises(net.QueryError): net.fetch('https://cleanip.io/cli')
            self.assertEqual(query.call_count, 2)

    GOOD = {'ip': '8.8.8.8', 'cidr': '8.8.8.0/24', 'is_datacenter': False, 'isResidential': True, 'is_vpn': False,
            'is_proxy': False, 'is_tor': False, 'is_abuser': False, 'trust_score': 100, 'countryCode': 'us'}

    def test_coffee_verdict_is_the_gate(self):
        exit_ = {'ip': '8.8.8.8', 'loc': 'US'}
        ok, why, d = check.verdict(exit_, self.GOOD, 80, '8.8.8.8')
        self.assertTrue(ok); self.assertIsNone(why); self.assertEqual(d['trust'], 100)
        for change, text in [({'is_datacenter': True}, '机房'), ({'is_vpn': True}, 'VPN'), ({'is_abuser': True}, '滥用'),
                             ({'isResidential': False}, '不是住宅'), ({'trust_score': 79}, '可信度 79'),
                             ({'trust_score': None}, '没有该 IP 的可信度'), ({'cidr': '1.1.1.0/24'}, '另一个 IP'),
                             ({'cidr': None, 'ip': '1.1.1.1'}, '另一个 IP'), ({'countryCode': 'hk'}, '香港')]:
            with self.subTest(change=change):
                ok, why, _ = check.verdict(exit_, {**self.GOOD, **change}, 80, '8.8.8.8')
                self.assertFalse(ok); self.assertIn(text, why)
        self.assertTrue(check.verdict(exit_, {**self.GOOD, 'isResidential': None, 'asn_kind': 'residential'}, 80, '8.8.8.8')[0])
        self.assertTrue(check.verdict(exit_, {**self.GOOD, 'trust_score': 79}, 70, '8.8.8.8')[0])
        self.assertIn('中国大陆', check.verdict({'ip': '8.8.8.8', 'loc': 'CN'}, {**self.GOOD, 'countryCode': ''}, 80, '8.8.8.8')[1])

    def test_split_routing_and_unconfirmed_generic_exit_fail(self):
        exit_ = {'ip': '8.8.8.8', 'loc': 'US'}
        ok, why, _ = check.verdict(exit_, self.GOOD, 80, '9.9.9.9')
        self.assertFalse(ok); self.assertIn('分流', why)
        ok, why, _ = check.verdict(exit_, self.GOOD, 80, None, '超时')
        self.assertFalse(ok); self.assertIn('超时', why)
        self.assertIn('IPv6', check.verdict({'ip': '2001:db8::1', 'loc': 'US'}, self.GOOD, 80, None)[1])

    def run_report(self, exit_=('8.8.8.8', 'US'), risk=None, generic='8.8.8.8', cleanip='IP 8.8.8.8\nIP 类型 住宅 IP 原生 IP\nCleanIP 评分 45/100 (D)\n'):
        risk = self.GOOD if risk is None else risk
        def fetch(url, timeout=5, context=None):
            if 'claude.ai' in url:
                if exit_ is None: raise net.QueryError(28, 'HTTPS 查询超时（curl 28）')
                return 'fl=1\nip=%s\nloc=%s\n' % exit_
            if 'iprisk' in url:
                if isinstance(risk, Exception): raise risk
                return json.dumps(risk)
            if 'cleanip' in url:
                if cleanip is None: raise net.QueryError(35, 'TLS')
                return cleanip
            raise AssertionError(url)
        probe = (lambda: (generic, 'proxy')) if not isinstance(generic, Exception) else Mock(side_effect=generic)
        with patch.object(net, 'fetch', side_effect=fetch), patch.object(net, 'probe', side_effect=probe), \
             patch.object(check.time, 'sleep'), patch.object(check, 'min_trust', return_value=80):
            return check.report()

    def test_cleanip_is_reference_only(self):
        r = self.run_report()
        self.assertTrue(r['ok']); self.assertEqual((r['score'], r['grade'], r['native']), (45, 'D', '原生 IP'))
        self.assertEqual(r['cleanip']['type'], '住宅 IP')
        r = self.run_report(cleanip=None)
        self.assertTrue(r['ok']); self.assertIsNone(r['cleanip']); self.assertIn('TLS', r['cleanip_error'])

    def test_report_fails_closed_on_lookup_failures(self):
        r = self.run_report(exit_=None)
        self.assertFalse(r['ok']); self.assertIn('无法取得 Claude 出口 IP', r['why'])
        r = self.run_report(risk=net.QueryError(28, 'HTTPS 查询超时（curl 28）'))
        self.assertFalse(r['ok']); self.assertIn('ip.net.coffee 查询失败', r['why'])
        r = self.run_report(generic=net.ExitChanged('Claude 出口 8.8.8.8 与通用出口 9.9.9.9 不一致（分流）'))
        self.assertFalse(r['ok']); self.assertIn('分流', r['why']); self.assertEqual(r['generic_ip'], '9.9.9.9')

    def test_monitor_requires_claude_exit_to_match(self):
        t = 'fl=1\nip=8.8.8.8\nloc=US\n'
        self.assertEqual(net.classify_claude(['8.8.8.8', '', '8.8.8.8'], [t, '']), '8.8.8.8')
        with self.assertRaises(net.ExitChanged): net.classify_claude(['8.8.8.8'], ['ip=9.9.9.9\n', t])
        with self.assertRaises(net.ProbeUnavailable): net.classify_claude(['8.8.8.8'], ['', '<html>'])
        with self.assertRaises(net.ExitChanged): net.classify_claude(['8.8.8.8'], [t], '1.1.1.1')
        self.assertEqual(net.CLAUDE_URLS, ('https://api.anthropic.com/cdn-cgi/trace', 'https://claude.ai/cdn-cgi/trace'))

    def test_public_ip_validation_and_fallback(self):
        self.assertEqual(net.classify(['8.8.8.8\n', '8.8.8.8']), '8.8.8.8')
        self.assertEqual(net.classify(['bad html', '8.8.8.8'], '8.8.8.8'), '8.8.8.8')
        for values in [[], ['', 'timeout'], ['127.0.0.1', '198.18.0.63'], ['8.8.8.8', '1.1.1.1']]:
            with self.subTest(values=values), self.assertRaises(ValueError): net.classify(values)
        with self.assertRaises(ValueError): net.classify(['1.1.1.1'], '8.8.8.8')

    def test_probe_rejects_proxy_change_during_lookup(self):
        with patch.object(net, 'transport', side_effect=[([], 'old'), ([], 'new')]), patch.object(net, 'fetch', return_value='8.8.8.8'):
            with self.assertRaises(ValueError): net.probe()

    def test_heartbeat_identity_state_and_proxy_are_required(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'HEALTH', Path(tmp) / 'health'), patch.object(net, 'process_identity', return_value='same'), patch.object(net, 'transport', return_value=([], 'proxy')):
            good = dict(pid=123, identity='same', state='healthy', heartbeat=net.time.time(), ip='8.8.8.8', transport='proxy')
            net.HEALTH.write_text(json.dumps(good))
            self.assertIsNotNone(net.health('8.8.8.8'))
            self.assertIsNone(net.health('1.1.1.1'))
            for delta in [dict(heartbeat=0), dict(identity='old-pid'), dict(state='blocked'), dict(transport='old-proxy')]:
                net.HEALTH.write_text(json.dumps({**good, **delta}))
                self.assertIsNone(net.health())

    def test_live_monitor_cannot_be_rebased(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'health', return_value=None), patch.object(net.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, str(net.WATCH), '')), patch.object(net.subprocess, 'Popen') as spawn:
            (net.ROOT / 'ip-watch.pid').write_text('123 8.8.8.8')
            with self.assertRaises(ValueError): net.ensure('1.1.1.1')
            spawn.assert_not_called()

    def test_dead_monitor_cannot_rebase_a_still_running_claude(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'process_identity', return_value='same-birth'):
            (net.ROOT / 'ip-watch-lease.json').write_text(json.dumps({'ip': '8.8.8.8', 'processes': {'123': 'same-birth'}}))
            with self.assertRaises(ValueError): net.validate_lease('1.1.1.1')
            with patch.object(net, 'process_identity', return_value=None): net.validate_lease('1.1.1.1')
            net.validate_lease('8.8.8.8')

    def test_verify_needs_fresh_health_and_matching_live_ip(self):
        with patch.object(net, 'health', return_value=None), patch.object(net, 'probe') as probe:
            with self.assertRaises(ValueError): net.verify()
            probe.assert_not_called()
        with patch.object(net, 'health', side_effect=[{'ip': '8.8.8.8'}, None]), patch.object(net, 'probe'):
            with self.assertRaises(ValueError): net.verify()

    def test_verify_reuses_a_fresh_heartbeat_but_probes_a_stale_one(self):
        with patch.object(net, 'health', return_value={'ip': '8.8.8.8', 'heartbeat': net.time.time()}), patch.object(net, 'probe') as probe:
            self.assertEqual(net.verify()['ip'], '8.8.8.8')
            probe.assert_not_called()
        stale = {'ip': '8.8.8.8', 'heartbeat': net.time.time() - net.FRESH_HEARTBEAT - 1}
        with patch.object(net, 'health', side_effect=[stale, stale]), patch.object(net, 'probe') as probe:
            net.verify()
            probe.assert_called_once_with('8.8.8.8')

    def test_three_probe_endpoints_tolerate_one_failure_but_not_a_conflict(self):
        self.assertEqual(len(net.URLS), 3)
        self.assertEqual(net.classify(['', '8.8.8.8\n', 'timeout'], '8.8.8.8'), '8.8.8.8')
        with self.assertRaises(net.ExitChanged): net.classify(['8.8.8.8', '8.8.8.8', '1.1.1.1'])

    def test_stale_force_grants_are_pruned_and_live_ones_kept(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(override, 'ROOT', Path(tmp)):
            for pid in (101, 102): (Path(tmp) / f'force-{pid}.json').write_text(json.dumps({'pid': pid}))
            (Path(tmp) / 'force-103.json').write_text('not json')
            with patch.object(override, 'process', side_effect=lambda pid: {'parent': 1} if pid == 101 else None):
                override.prune()
            self.assertEqual([p.name for p in Path(tmp).glob('force-*.json')], ['force-101.json'])

    def test_target_selection_excludes_codex_and_monitor_descendants(self):
        rows = ('10 1 /Applications/Claude.app/Contents/MacOS/Claude\n'
                '11 10 /Applications/Claude.app/Contents/Frameworks/Claude Helper\n'
                '12 10 /Applications/Codex.app/Contents/MacOS/Codex\n'
                '13 12 /usr/bin/some-codex-child\n'
                '14 1 /bin/zsh\n'
                f'{os.getpid()} 10 /usr/bin/python3\n'
                f'15 {os.getpid()} /usr/bin/curl\n')
        with patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, rows, '')):
            self.assertEqual(set(watch.targets()), {10, 11})

    def test_termination_checks_process_birth_before_signalling(self):
        with patch.object(net, 'process_identity', side_effect=['reused', 'same']), patch.object(watch.os, 'kill') as kill:
            watch.terminate({123: 'old', 124: 'same'})
            kill.assert_called_once_with(124, watch.signal.SIGKILL)

    def run_watcher(self, failures=False):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'HEALTH', Path(tmp) / 'health'), patch.object(net, 'CONFIG', Path(tmp) / 'conf'), patch.object(net, 'process_identity', return_value='test-process'), patch.object(watch.sys, 'argv', ['watch', '8.8.8.8']), patch.object(watch.signal, 'signal'), patch.object(watch, 'targets', side_effect=[{123: 'claude'}, {}] if not failures else [{123: 'claude'}, {123: 'claude', 124: 'new-claude'}]), patch.object(net, 'probe', side_effect=net.ExitChanged('changed') if failures else None, return_value=('8.8.8.8', 'proxy')), patch.object(watch, 'terminate') as terminate, patch.object(watch.threading.Event, 'wait'), patch.object(watch, 'notify'):
            code = watch.main()
            self.assertEqual(code, 1 if failures else 0)
            self.assertEqual(json.loads(net.HEALTH.read_text())['state'], 'blocked' if failures else 'stopped')
            self.assertFalse((net.ROOT / 'ip-watch.pid').exists())
            if failures: self.assertEqual(set(terminate.call_args[0][0]), {123, 124})
            else: terminate.assert_not_called()
            # Close handlers so a repeated test does not hold the temporary log open.
            log = watch.logging.getLogger('claude-ip-watch')
            for h in log.handlers[:]: h.close(); log.removeHandler(h)

    def test_watcher_success_publishes_then_stops_when_claude_exits(self): self.run_watcher()
    def test_watcher_failure_closes_matching_processes_and_cleans_state(self): self.run_watcher(True)

    def test_singleton_lock_does_not_overwrite_owner_state(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(watch.sys, 'argv', ['watch', '8.8.8.8']):
            lock = open(Path(tmp) / 'ip-watch.lock', 'a')
            watch.fcntl.flock(lock, watch.fcntl.LOCK_EX | watch.fcntl.LOCK_NB)
            self.assertEqual(watch.main(), 1)
            self.assertFalse((Path(tmp) / 'ip-watch.pid').exists())
            lock.close()

    def test_system_https_proxy_is_explicit_and_pac_is_not_silently_direct(self):
        for output, expected in [('HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7897', ['--proxy','http://127.0.0.1:7897']), ('HTTPSEnable : 0\nSOCKSEnable : 0', [])]:
            with patch.object(net.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                self.assertEqual(net.transport()[0], expected)
        with patch.object(net.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'ProxyAutoConfigEnable : 1', '')):
            with self.assertRaises(ValueError): net.transport()

    def test_force_authorization_dies_with_monitor_or_process(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(override, 'ROOT', Path(tmp)), patch.object(override, 'watcher_ready', return_value=True):
            info = dict(parent=1, command='/Applications/Claude.app/Contents/MacOS/Claude', started='same birth')
            (Path(tmp) / 'force-123.json').write_text(json.dumps(dict(pid=123, ip='8.8.8.8', **info)))
            with patch.object(override, 'process', side_effect=lambda pid: info if pid == 123 else None):
                self.assertIsNotNone(override.status(123))
                with patch.object(override, 'watcher_ready', return_value=False): self.assertIsNone(override.status(123))
            with patch.object(override, 'process', return_value=None): self.assertIsNone(override.status(123))


    def test_client_counts_split_desktop_and_cli_sessions(self):
        home = str(Path.home())
        rows = {10: (1, '/Applications/Claude.app/Contents/MacOS/Claude'),
                11: (10, '/Applications/Claude.app/Contents/Frameworks/Claude Helper'),
                12: (10, home + '/Library/Application Support/Claude/claude-code/2/x/claude.app/Contents/MacOS/claude'),
                20: (1, '/bin/zsh'), 21: (20, home + '/.local/bin/claude'), 22: (21, '/bin/zsh'),
                30: (1, '/Applications/Codex.app/Contents/MacOS/Codex')}
        self.assertEqual(watch.clients(rows), {'desktop': 1, 'desktop_sessions': 1, 'cli': 1, 'cli_sources': {'其他': 1}, 'processes': 5})

    def test_kill_all_signals_only_claude_targets_and_logs(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(watch, 'targets', return_value={10: 'c', 11: 'c'}), patch.object(net, 'process_identity', return_value='birth'), patch.object(watch.os, 'kill') as kill:
            self.assertEqual(watch.kill_all('test'), 2)
            self.assertEqual(sorted(c.args[0] for c in kill.call_args_list), [10, 11])
            self.assertIn('KILL: test; matching Claude processes=2', (Path(tmp) / 'ip-watch.log').read_text())

    def test_unstable_policy_reads_last_valid_line(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'CONFIG', Path(tmp) / 'conf'):
            self.assertEqual(net.unstable_policy(), 'pause')
            net.CONFIG.write_text('ON_UNSTABLE=kill\nON_UNSTABLE=bogus\n')
            self.assertEqual(net.unstable_policy(), 'kill')

    def test_hold_keeps_watcher_alive_without_claude(self):
        """With a live console hold, an empty process list does not end the monitor."""
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'HEALTH', Path(tmp) / 'health'), patch.object(net, 'CONFIG', Path(tmp) / 'conf'), patch.object(net, 'process_identity', return_value='console'), patch.object(watch.sys, 'argv', ['watch', '8.8.8.8']), patch.object(watch.signal, 'signal'), patch.object(watch, 'targets', return_value={}), patch.object(net, 'probe', return_value=('8.8.8.8', 'proxy')), patch.object(watch, 'notify'):
            net.hold(4242)
            waits = []
            def wait(_t):
                waits.append(1)
                if len(waits) == 3: net.hold_path().unlink()
            with patch.object(watch.threading.Event, 'wait', side_effect=wait):
                self.assertEqual(watch.main(), 0)
            self.assertGreaterEqual(len(waits), 3)
            health = json.loads(net.HEALTH.read_text())
            self.assertEqual(health['state'], 'stopped')
            log = watch.logging.getLogger('claude-ip-watch')
            for h in log.handlers[:]: h.close(); log.removeHandler(h)

    def test_forced_console_session_authorises_claude_descendants_only(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(override, 'ROOT', Path(tmp)), patch.object(override, 'SESSION', Path(tmp) / 'guard-session.json'), patch.object(override, 'watcher_ready', return_value=True):
            console = dict(parent=1, command=override.LAUNCHER, started='console birth')
            claude = dict(parent=1, command='/Applications/Claude.app/Contents/MacOS/Claude', started='c')
            node = dict(parent=50, command='/usr/bin/node', started='n')
            table = {7: console, 50: claude, 51: node, 60: dict(parent=1, command='/bin/zsh', started='z')}
            override.SESSION.write_text(json.dumps(dict(pid=7, started='console birth', command=override.LAUNCHER, ip='8.8.8.8', mode='forced')))
            with patch.object(override, 'process', side_effect=lambda pid: table.get(pid)):
                self.assertIsNotNone(override.status(51))
                self.assertIsNone(override.status(60))
                with patch.object(override, 'watcher_ready', return_value=False): self.assertIsNone(override.status(51))
                override.SESSION.write_text(json.dumps(dict(pid=7, started='console birth', command=override.LAUNCHER, ip='8.8.8.8', mode='verified')))
                self.assertIsNone(override.status(51))
            # Console gone: the session is void.
            with patch.object(override, 'process', return_value=None): self.assertIsNone(override.session())

    def test_session_commands_refuse_other_callers(self):
        with patch.object(override, 'process', return_value=dict(parent=1, command='/bin/zsh', started='x')):
            with self.assertRaises(ValueError): override.session_begin('8.8.8.8', 'forced')
            with self.assertRaises(ValueError): override.session_end()

    def test_executable_resolves_a_process_started_through_path(self):
        child = subprocess.Popen(['sleep', '30'])  # argv[0] without a path, like T3 Code's `claude`
        try:
            shown = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'comm='], text=True).strip()
            self.assertNotIn('/', shown)
            self.assertEqual(net.executable(child.pid, shown), '/bin/sleep')
            self.assertEqual(net.executable(child.pid, '/already/absolute'), '/already/absolute')
        finally:
            child.kill(); child.wait()
        self.assertEqual(net.executable(child.pid, 'gone'), 'gone')

    def test_bare_claude_started_by_another_app_is_a_cli_target(self):
        versions = str(Path.home() / '.local/share/claude/versions/2.1.330')
        rows = '19394 1 /Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)\n51144 19394 claude\n51150 51144 /bin/zsh\n'
        with patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, rows, '')), \
             patch.object(net, 'executable', side_effect=lambda pid, shown: versions if shown == 'claude' else shown):
            self.assertEqual(set(watch.targets()), {51144, 51150})
            self.assertEqual(watch.clients()['cli'], 1)
            self.assertEqual(watch.clients()['cli_sources'], {'T3 Code (Beta)': 1})

    def test_cli_sources_name_the_launching_app(self):
        home = str(Path.home())
        cli = home + '/.local/bin/claude'
        rows = {5: (1, '/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal'), 6: (5, '/usr/bin/login'),
                7: (6, '/bin/zsh'), 8: (7, cli), 9: (7, cli),
                20: (1, '/Applications/Warp.app/Contents/MacOS/stable'), 21: (20, '/bin/zsh'), 22: (21, cli),
                30: (1, '/usr/sbin/sshd'), 31: (30, cli)}
        self.assertEqual(watch.clients(rows)['cli_sources'], {'Terminal': 2, 'Warp': 1, '其他': 1})

if __name__ == '__main__': unittest.main(verbosity=2)
