import { test, expect } from 'claude-code/testing'
import { register } from './register'

const harness = () => {
  const handlers: Record<string, any> = {}
  const errors: Record<string, any> = {}
  register(((name: string, fn: any) => {
    handlers[name] = fn
    return { catch: (handler: any) => { errors[name] = handler } }
  }) as any)
  let state: any
  const flags = { ready: true, healthy: true, live: true, aborts: 0, forwarded: 0 }
  const calls: string[][] = []
  const api: any = {
    state: { get: async () => ({ value: state }), set: async (_: any, value: any) => { state = value } },
    ui: { status: () => {}, toast: () => {} },
    turn: { abort: async () => { flags.aborts++ } },
    process: { run: async (argv: string[]) => {
      calls.push(argv)
      if (argv[0].endsWith('claude-ip-check')) return { exitCode: 0, stdout: JSON.stringify({ok: true, ip: '8.8.8.8', score: 98, type: '住宅 IP'}) }
      const pass = argv[1] === '--ensure' ? flags.ready : argv[1] === '--health' ? flags.healthy : argv[1] === '--verify' ? flags.live : false
      return { exitCode: pass ? 0 : 1 }
    } },
  }
  const next = async function* () { flags.forwarded++; yield { kind: 'test' }; return 'done' }
  const step = async () => {
    const gen = handlers['turn.step'](api, {turnId: 'test', index: 0}, next)
    while (!(await gen.next()).done) {}
  }
  return {handlers, errors, api, flags, calls, step}
}

test('normal session uses shared checker and waits for monitored matching IP', async () => {
  const h = harness()
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.calls[0][0].endsWith('claude-ip-check')).toBe(true)
  expect(h.calls[1].slice(1).join(' ')).toBe('--ensure 8.8.8.8')
  expect(await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).toBe('forwarded')
  h.flags.live = false
  expect((await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).drop).toBe('网络一致性检测未通过，请通过 IP Guard 重新检测')
})

test('tool-loop request is suppressed when the heartbeat goes stale', async () => {
  const h = harness()
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  await h.step()
  expect(h.flags.forwarded).toBe(1)
  h.flags.healthy = false
  await h.step()
  expect(h.flags.forwarded).toBe(1)
  expect(h.flags.aborts).toBe(1)
})

test('missing startup report fails closed for prompts and model requests', async () => {
  const h = harness()
  expect((await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).drop).toBe('已拦截:检测尚未完成')
  await h.step()
  expect(h.flags.forwarded).toBe(0)
  expect(h.flags.aborts).toBe(1)
})

test('monitor readiness failure cannot silently start a normal session', async () => {
  const h = harness()
  h.flags.ready = false
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect((await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).drop).toBe('已拦截:监控未就绪或出口不一致')
})

test('hook error handlers also fail closed', async () => {
  const h = harness()
  expect(h.errors['prompt.submit']().drop).toBe('网络保护检查失败，已拦截发送')
  const gen = h.errors['turn.step'](h.api, { turnId: 'test', index: 0 })
  expect((await gen.next()).done).toBe(true)
  expect(h.flags.aborts).toBe(1)
})
