import { test, expect } from 'claude-code/testing'
import { register } from './register'

const harness = (confirmation: boolean, grantAfterConfirmation = true) => {
  const handlers: Record<string, any> = {}
  register(((name: string, fn: any) => { handlers[name] = fn; return { catch: () => ({}) } }) as any)
  let value: any
  let authorized = false
  let confirmations = 0
  let kills = 0
  const api: any = {
    fs: { read: async () => 'MIN_SCORE=70\n' },
    http: { fetch: async () => { throw Error('offline') } },
    state: { set: async (_: any, v: any) => { value = v }, get: async () => ({ value }) },
    ui: { status: () => {}, toast: () => {} },
    process: { run: async (argv: string[]) => {
      if (argv[0].endsWith('claude-ip-check')) return { exitCode: 1, stdout: JSON.stringify({ ok: false, why: '网络错误' }) }
      if (argv[1] === '--verify') return { exitCode: authorized ? 0 : 1 }
      if (argv[1] === '--status') return { exitCode: authorized ? 0 : 1 }
      if (argv[2]?.includes('--confirm-session')) {
        confirmations++
        authorized = confirmation && grantAfterConfirmation
        return { exitCode: confirmation ? 0 : 1 }
      }
      if (argv[2] === 'kill -TERM $PPID') kills++
      return { exitCode: 0 }
    } },
  }
  return { handlers, api, read: () => ({ value, confirmations, kills }), expire: () => { authorized = false } }
}

test('confirmed override allows this session and keeps failed report honest', async () => {
  const h = harness(true)
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.read().value.ok).toBe(false)
  expect(h.read().value.forced).toBe(true)
  expect(h.read().confirmations).toBe(1)
  expect(h.read().kills).toBe(0)
  expect(await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).toBe('forwarded')
  h.expire()
  expect((await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).drop).toBe('本次强制授权已失效，请重新启动并确认')
})

test('cancelled confirmation continues to refuse the session', async () => {
  const h = harness(false)
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.read().kills).toBe(1)
  expect((await h.handlers['prompt.submit'](h.api, {}, async () => 'forwarded')).drop).toBe('已拦截:网络错误')
})

test('confirmation without a valid monitored grant is refused', async () => {
  const h = harness(true, false)
  await h.handlers['session.start'](h.api, {}, async () => 'started')
  expect(h.read().kills).toBe(1)
})
