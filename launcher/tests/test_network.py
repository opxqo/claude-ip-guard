import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def test_transport_failure_survives_in_checker_json(self):
        script = (BIN / 'claude-ip-check').read_text()
        parser = script.split("/usr/bin/python3 -c '", 1)[1].rsplit("'", 1)[0]
        error = 'HTTPS/TLS 握手失败（curl 35）'
        result = subprocess.run(['/usr/bin/python3', '-c', parser], input='', text=True, capture_output=True,
                                env={**os.environ, 'MIN': '70', 'MODE': '--json', 'LOOKUP_ERROR': error}, timeout=5)
        self.assertEqual(json.loads(result.stdout)['why'], error)
        self.assertEqual(result.returncode, 1)

    def test_shared_checker_keeps_score_and_residential_policy(self):
        script = (BIN / 'claude-ip-check').read_text()
        parser = script.split("/usr/bin/python3 -c '", 1)[1].rsplit("'", 1)[0]
        for kind, network, score, expected in [('住宅 IP', 'ISP', 98, True), ('未知类型', '住宅 IP', 98, True), ('机房 IP', 'ISP', 98, False), ('住宅 IP', 'ISP', 70, False)]:
            raw = f'IP 8.8.8.8\nIP 类型 {kind}\n网络类型 {network}\nCleanIP 评分 {score}/100 (A+)\n'
            result = subprocess.run(['/usr/bin/python3', '-c', parser], input=raw, text=True, capture_output=True, env={**os.environ, 'MIN': '70', 'MODE': '--json'}, timeout=5)
            self.assertIs(json.loads(result.stdout)['ok'], expected)
            self.assertEqual(result.returncode, 0 if expected else 1)

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

    def test_checker_retries_only_failed_lookups(self):
        script = (BIN / 'claude-ip-check').read_text()
        self.assertIn('for attempt in 1 2 3', script)
        self.assertIn('(( lookup_status == 0 )) && break', script)

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
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'HEALTH', Path(tmp) / 'health'), patch.object(net, 'process_identity', return_value='test-process'), patch.object(watch.sys, 'argv', ['watch', '8.8.8.8']), patch.object(watch.signal, 'signal'), patch.object(watch, 'targets', side_effect=[{123: 'claude'}, {}] if not failures else [{123: 'claude'}, {123: 'claude', 124: 'new-claude'}]), patch.object(net, 'probe', side_effect=net.ExitChanged('changed') if failures else None, return_value=('8.8.8.8', 'proxy')), patch.object(watch, 'terminate') as terminate, patch.object(watch.threading.Event, 'wait'), patch.object(watch, 'notify'):
            code = watch.main()
            self.assertEqual(code, 1 if failures else 0)
            self.assertEqual(json.loads(net.HEALTH.read_text())['state'], 'stopped')
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


if __name__ == '__main__': unittest.main(verbosity=2)
