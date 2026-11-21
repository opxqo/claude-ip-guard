import { test, expect } from 'claude-code/testing'
import { register } from './register'

// A Claude IP Guard console session replaces the per-session CleanIP lookup and confirmation.
const harness = (session: object | null, opts: { ready?: boolean; status?: boolean } = {}) => {
  const handlers: Record<string, any> = {}
  register(((name: string, fn: any) => { handlers[name] = fn; return { catch: () => ({}) } }) as any)
  let value: any
  const calls: string[] = []
  const api: any = {
    state: { set: async (_: any, v: any) => { value = v }, get: async () => ({ value }) },
    ui: { status: () => {}, toast: () => {} },
    process: { run: async (argv: string[]) => {
      calls.push(argv[0].endsWith('claude-ip-check') ? 'check' : argv[2]?.includes('--confirm-session') ? 'confirm' : argv[1])
      if (argv[1] === '--session') return session ? { exitCode: 0, stdout: JSON.stringify(session) } : { exitCode: 1, stdout: 'null' }
      if (argv[1] === '--ensure') return { exitCode: opts.ready === false ? 1 : 0 }
      if (argv[1] === '--status') return { exitCode: opts.status ? 0 : 1 }
      if (argv[1] === '--verify') return { exitCode: 0 }
      if (argv[0].endsWith('claude-ip-check')) return { exitCode: 0, stdout: JSON.stringify({ ok: true, ip: '8.8.8.8', score: 98, type: '住宅 IP' }) }
      return { exitCode: 1 }
    } },
  }
  return { handlers, api, calls, read: () => value }
}

test('verified console session skips the CleanIP re-check', async () => {
  const h = harness({ ip: '8.8.8.8', mode: 'verified', report: { ok: true, ip: '8.8.8.8', score: 97, type: '住宅 IP' } })
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.calls.includes('check')).toBe(false)
  expect(h.read().ok).toBe(true)
  expect(h.read().score).toBe(97)
  expect(await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).toBe('forwarded')
})

test('forced console session is accepted without a second confirmation', async () => {
  const h = harness({ ip: '8.8.8.8', mode: 'forced', report: { ok: false, why: 'score 88 <= 95', score: 88 } }, { status: true })
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.calls.includes('check')).toBe(false)
  expect(h.calls.includes('confirm')).toBe(false)
  expect(h.read().forced).toBe(true)
  expect(h.read().ok).toBe(false)
})

test('a console session whose monitor is not ready is not trusted', async () => {
  const h = harness({ ip: '8.8.8.8', mode: 'verified', report: { ok: true } }, { ready: false })
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.read().ok).toBe(false)
  expect(h.read().why).toBe('监控未就绪或出口不一致')
})

test('without a console session the original check still runs', async () => {
  const h = harness(null)
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.calls.includes('check')).toBe(true)
  expect(h.read().ok).toBe(true)
})
