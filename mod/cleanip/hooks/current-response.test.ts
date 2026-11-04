import { test, expect } from 'claude-code/testing'
import { judge, register } from './register'
import { currentResponse } from './current-response.fixture'

test('current CLI residential network is accepted when IP type is unknown', () => {
  const r = judge(currentResponse, 94)
  expect(r.ok).toBe(true)
  expect(r.type).toBe('住宅 IP')
  expect(r.network).toBe('住宅 IP')
})

test('network fallback retains threshold and explicit nonresidential refusals', () => {
  const plain = currentResponse.replace(/\x1b\[[0-9;]*m/g, '')
  const score = (n: number) => plain.replace(/(CleanIP\s*评分)[^\n]*/, `$1 ${n}/100 (A+)`)
  expect(judge(score(94), 94).ok).toBe(false)
  expect(judge(score(95), 94).ok).toBe(true)
  for (const type of ['机房 IP', '企业 IP', 'VPN', 'Tor']) {
    expect(judge(plain.replace('未知类型', type), 94).ok).toBe(false)
  }
  for (const network of ['机房 IP', '未知类型', '非住宅 IP', '住宅代理', 'ISP']) {
    expect(judge(plain.replace('住宅 IP', network), 94).ok).toBe(false)
  }
  expect(judge(plain.replace(/^\s*IP 类型[^\n]*\n/m, ''), 94).ok).toBe(true)
  expect(judge('', 94).ok).toBe(false)
})

const harness = (raw: string) => {
  const handlers: Record<string, any> = {}
  register(((name: string, handler: any) => { handlers[name] = handler; return { catch: () => ({}) } }) as any)
  let value: any
  const kills: unknown[] = []
  const api: any = {
    fs: { read: async () => 'MIN_SCORE=94\n' },
    http: { fetch: async () => ({ text: raw }) },
    state: { set: async (_key: any, v: any) => { value = v }, get: async () => ({ value }) },
    ui: { status: () => {}, toast: () => {} },
    process: { run: async (...args: any[]) => {
      if (args[0][0].endsWith('claude-ip-check')) return { exitCode: judge(raw, 94).ok ? 0 : 1, stdout: JSON.stringify(judge(raw, 94)) }
      if (args[0][1] === '--ensure' || args[0][1] === '--verify' || args[0][1] === '--health') return { exitCode: 0, stdout: 'ready' }
      kills.push(args)
      return { exitCode: 1 }
    } },
  }
  return { handlers, api, kills, report: () => value }
}

test('session start neither terminates nor blocks a valid current response', async () => {
  const h = harness(currentResponse)
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.report().ok).toBe(true)
  expect(h.kills.length).toBe(0)
  expect(await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).toBe('forwarded')
})

test('session start and prompt backstop still reject an invalid response', async () => {
  const h = harness('invalid response')
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.report().ok).toBe(false)
  expect(h.kills.filter((args: any) => args[0]?.[2] === 'kill -TERM $PPID').length).toBe(1)
  const result = await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')
  expect(result.drop).toBe('已拦截:检测失败')
})
