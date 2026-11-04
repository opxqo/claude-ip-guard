"""Shared transport and readiness checks for the Claude IP guard."""
import concurrent.futures
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path.home() / '.claude/run'
WATCH = Path.home() / '.claude/bin/claude-ip-watch'
URLS = ('https://api.ipify.org', 'https://ipv4.icanhazip.com', 'https://checkip.amazonaws.com')
# A heartbeat this young was published after a passing probe, so a prompt check can reuse it.
FRESH_HEARTBEAT = 5
HEALTH = ROOT / 'ip-watch-health.json'


class QueryError(ValueError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


class ProbeUnavailable(ValueError):
    """No reliable measurement: pause and retry, rather than infer an IP change."""


class ExitChanged(ValueError):
    """A valid observed IP conflicts with the fixed baseline."""


def transport():
    p = subprocess.run(['/usr/sbin/scutil', '--proxy'], capture_output=True, text=True, timeout=3)
    if p.returncode:
        raise ValueError('无法读取系统代理状态')
    entries = dict(line.strip().split(' : ', 1) for line in p.stdout.splitlines() if ' : ' in line)
    args = []
    if entries.get('HTTPSEnable') == '1':
        host, port = entries.get('HTTPSProxy'), entries.get('HTTPSPort')
        if not host or not port:
            raise ValueError('系统 HTTPS 代理配置不完整')
        args = ['--proxy', 'http://%s:%s' % (host, port)]
    elif entries.get('ProxyAutoConfigEnable') == '1' or entries.get('SOCKSEnable') == '1':
        raise ValueError('当前 PAC/SOCKS 系统代理路径尚未支持一致性检测')
    env_proxy = {k: v for k, v in os.environ.items() if k.lower().endswith('_proxy')}
    fingerprint = hashlib.sha256(json.dumps([entries, env_proxy], sort_keys=True).encode()).hexdigest()
    return args, fingerprint


def _curl_fetch(url, timeout=5, context=None, resolve=None):
    args, _ = context or transport()
    if resolve:
        args = [*args, '--resolve', 'cleanip.io:443:' + str(ipaddress.IPv4Address(resolve))]
    p = subprocess.run(['/usr/bin/curl', '-4', '-f', '-sS', '-L', '--proto', '=https',
                        '--proto-redir', '=https', '--connect-timeout', '4',
                        '--max-time', str(timeout), *args, url], capture_output=True, text=True,
                       timeout=timeout + 2)
    if p.returncode:
        reason = {6: 'DNS 解析失败', 7: '无法建立连接', 22: '检测服务返回 HTTP 错误',
                  28: 'HTTPS 查询超时', 35: 'HTTPS/TLS 握手失败',
                  60: 'HTTPS 证书验证失败'}.get(p.returncode, 'HTTPS 查询失败')
        raise QueryError(p.returncode, '%s（curl %s）' % (reason, p.returncode))
    return p.stdout


def fetch(url, timeout=5, context=None):
    ctx = context or transport()
    try:
        return _curl_fetch(url, timeout, ctx)
    except QueryError as original:
        if url != 'https://cleanip.io/cli' or original.code not in (6, 7, 28, 35):
            raise
        # Resolve only this request, without changing system DNS, proxy or the URL.
        # --resolve preserves TLS SNI and hostname/certificate verification.
        try:
            answer = json.loads(_curl_fetch('https://dns.google/resolve?name=cleanip.io&type=A', 3, ctx))
            if answer.get('Status') != 0:
                raise ValueError('DNS answer unavailable')
            addresses = [str(ipaddress.IPv4Address(row['data'])) for row in answer.get('Answer', [])
                         if row.get('type') == 1 and ipaddress.IPv4Address(row['data']).is_global]
            if not addresses:
                raise ValueError('DNS answer has no public IPv4')
            if transport()[1] != ctx[1]:
                raise ValueError('代理配置已变化')
            return _curl_fetch(url, min(timeout, 6), ctx, resolve=addresses[0])
        except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            raise QueryError(original.code, str(original) + '；备用 DNS 连接也未成功') from None


def classify(values, expected=None):
    ips = []
    for value in values:
        try:
            ip = ipaddress.IPv4Address(value.strip())
            if ip.is_global:
                ips.append(str(ip))
        except (ValueError, AttributeError):
            pass
    if not ips:
        raise ProbeUnavailable('所有出口查询服务均未返回有效公网 IPv4')
    if len(set(ips)) != 1:
        raise ExitChanged('出口查询结果不一致，可能存在分流或出口轮换')
    if expected and ips[0] != expected:
        raise ExitChanged('出口 IP 与本次启动基准不一致')
    return ips[0]


def probe(expected=None):
    ctx = transport()
    def read(url):
        try: return fetch(url, context=ctx), ''
        except (ValueError, subprocess.TimeoutExpired) as exc:
            return '', str(exc)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(URLS)) as pool:
        results = list(pool.map(read, URLS))
    if transport()[1] != ctx[1]:
        raise ProbeUnavailable('检测期间代理配置发生变化，请重试')
    try:
        return classify([value for value, _ in results], expected), ctx[1]
    except ProbeUnavailable as exc:
        details = '; '.join('%s: %s' % (url.split('/')[2], error or '响应不是有效公网 IPv4')
                            for url, (_, error) in zip(URLS, results))
        raise ProbeUnavailable(str(exc) + '；' + details) from None


def process_identity(pid):
    p = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
                       capture_output=True, text=True, timeout=3)
    return p.stdout.strip() if p.returncode == 0 else None


def health(expected=None):
    try:
        d = json.loads(HEALTH.read_text())
        # Python 3.9 on macOS may use a process-relative monotonic origin.
        # Epoch time is comparable across the launcher, monitor and CLI processes.
        age = time.time() - d['heartbeat']
        return (d if d['state'] == 'healthy' and 0 <= age <= 10
                and (not expected or d['ip'] == expected)
                and process_identity(d['pid']) == d['identity']
                and transport()[1] == d['transport'] else None)
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        return None


def verify():
    d = health()
    if not d:
        raise ValueError('IP 监控未就绪、心跳失效或代理配置已变化')
    if time.time() - d.get('heartbeat', 0) <= FRESH_HEARTBEAT:
        return d
    probe(d['ip'])
    if not health(d['ip']):
        raise ValueError('出口检测期间监控状态发生变化')
    return d


def validate_lease(ip):
    """A monitor restart must not change the baseline of a still-running Claude."""
    path = ROOT / 'ip-watch-lease.json'
    try:
        d = json.loads(path.read_text())
    except FileNotFoundError:
        return
    except (OSError, ValueError):
        raise ValueError('监控基准记录损坏，请检查后重试')
    if d.get('ip') == ip:
        return
    if any(identity and process_identity(int(pid)) == identity
           for pid, identity in d.get('processes', {}).items()):
        raise ValueError('仍有 Claude 使用旧基准 IP，请先退出后再建立新基准')


def ensure(ip):
    ip = str(ipaddress.IPv4Address(ip))
    validate_lease(ip)
    if health(ip): return
    # Never replace the baseline of a living monitor to accommodate a changed network.
    pidfile = ROOT / 'ip-watch.pid'
    try:
        pid, existing_ip = pidfile.read_text().split()
        p = subprocess.run(['/bin/ps', '-p', str(int(pid)), '-o', 'args='], capture_output=True, text=True)
        alive = p.returncode == 0 and str(WATCH) in p.stdout
    except (OSError, ValueError): alive = False
    if alive and existing_ip != ip:
        raise ValueError('已有监控的基准 IP 不同，请先退出 Claude 再重新检测')
    if not alive:
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(os.devnull, 'wb') as null:
            subprocess.Popen([str(WATCH), ip], stdout=null, stderr=null, start_new_session=True)
    for _ in range(100):
        if health(ip): return
        time.sleep(0.1)
    raise ValueError('监控尚未完成有效出口检测，拒绝启动')
