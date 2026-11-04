"""Offline retry tests plus real STOP/CONT on a disposable sleep child only."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parents[2] / 'bin'
sys.path.insert(0, str(BIN))
import claude_network as net
loader = importlib.machinery.SourceFileLoader('watch_retry', str(BIN / 'claude-ip-watch'))
spec = importlib.util.spec_from_loader(loader.name, loader)
watch = importlib.util.module_from_spec(spec)
loader.exec_module(watch)


class RetryTests(unittest.TestCase):
    def scenario(self, probes, grace=30):
        snapshots, signals = [], []
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'HEALTH', Path(tmp) / 'health'), patch.object(net, 'process_identity', return_value='birth'), patch.object(watch.sys, 'argv', ['watch', '8.8.8.8']), patch.object(watch.signal, 'signal'), patch.object(watch, 'notify'), patch.object(watch, 'GRACE_SECONDS', grace), patch.object(net, 'probe', side_effect=probes) as probe, patch.object(watch.os, 'kill', side_effect=lambda pid, sig: signals.append(sig)), patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'S', '')):
            def target_set():
                return {99999999: 'claude'} if probe.call_count < len(probes) else {}
            def snapshot(_timeout):
                snapshots.append(json.loads(net.HEALTH.read_text()))
            with patch.object(watch, 'targets', side_effect=target_set), patch.object(watch.threading.Event, 'wait', side_effect=snapshot):
                code = watch.main()
            self.assertFalse((Path(tmp) / 'ip-watch-paused.json').exists())
            log = (Path(tmp) / 'ip-watch.log').read_text()
            self.assertEqual(json.loads(net.HEALTH.read_text())['state'], 'stopped')
        return code, snapshots, signals, log

    def test_transient_failure_pauses_then_resumes_same_process(self):
        code, states, signals, log = self.scenario([net.ProbeUnavailable('timeout'), ('8.8.8.8', 'proxy')])
        self.assertEqual(code, 0)
        self.assertEqual([d['state'] for d in states], ['retrying', 'healthy'])
        self.assertEqual(signals, [signal.SIGSTOP, signal.SIGCONT])
        self.assertIn('RESUME:', log)
        self.assertNotIn('KILL:', log)

    def test_repeated_failures_do_not_repeat_stop_or_reset_deadline(self):
        code, states, signals, log = self.scenario([net.ProbeUnavailable('DNS'), net.ProbeUnavailable('TLS'), ('8.8.8.8', 'proxy')])
        self.assertEqual(code, 0)
        self.assertEqual(states[0]['retry_deadline'], states[1]['retry_deadline'])
        self.assertEqual(states[1]['retry_count'], 2)
        self.assertEqual(signals, [signal.SIGSTOP, signal.SIGCONT])

    def test_confirmed_change_during_retry_closes_without_resuming(self):
        code, states, signals, log = self.scenario([net.ProbeUnavailable('timeout'), net.ExitChanged('new IP')])
        self.assertEqual(code, 1)
        self.assertIn(signal.SIGSTOP, signals)
        self.assertIn(signal.SIGKILL, signals)
        self.assertNotIn(signal.SIGCONT, signals)
        self.assertIn('确认出口变化或冲突', log)

    def test_sustained_failure_closes_only_after_budget_expires(self):
        code, states, signals, log = self.scenario([net.ProbeUnavailable('timeout')], grace=0)
        self.assertEqual(code, 1)
        self.assertIn(signal.SIGSTOP, signals)
        self.assertIn(signal.SIGKILL, signals)
        self.assertIn('超过重试窗口', log)

    def test_real_disposable_child_stops_and_continues(self):
        child = subprocess.Popen(['/bin/sleep', '30'])
        try:
            with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)):
                paused = watch.PausedProcesses('8.8.8.8')
                identity = net.process_identity(child.pid)
                paused.pause({child.pid: identity})
                state = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'state='], text=True)
                self.assertIn('T', state)
                # A replacement monitor reads the journal and resumes the same child.
                replacement = watch.PausedProcesses('8.8.8.8')
                replacement.resume()
                state = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'state='], text=True)
                self.assertNotIn('T', state)
                self.assertIsNone(child.poll())
        finally:
            child.kill()
            child.wait()

    def test_existing_user_stop_is_not_owned_or_resumed(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(net, 'ROOT', Path(tmp)), patch.object(net, 'process_identity', return_value='birth'), patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'T', '')), patch.object(watch.os, 'kill') as kill:
            paused = watch.PausedProcesses('8.8.8.8')
            paused.pause({99999999: 'birth'})
            paused.resume()
            kill.assert_not_called()

    def test_probe_errors_keep_details_and_change_is_distinct(self):
        with patch.object(net, 'transport', return_value=([], 'proxy')), patch.object(net, 'fetch', side_effect=net.QueryError(35, 'TLS error')):
            with self.assertRaises(net.ProbeUnavailable) as failure: net.probe('8.8.8.8')
            self.assertIn('api.ipify.org: TLS error', str(failure.exception))
            self.assertIn('ipv4.icanhazip.com: TLS error', str(failure.exception))
        with self.assertRaises(net.ExitChanged): net.classify(['1.1.1.1'], '8.8.8.8')


if __name__ == '__main__': unittest.main(verbosity=2)
