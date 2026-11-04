import type { Register } from 'claude-code'

import type { Report } from '../types'

// CleanIP's plain-text report (ANSI colours stripped). Same rule as ~/.claude/bin/claude-ip-check.
const OVERRIDE = '__HOME__/.claude/bin/claude-ip-override'
const LAUNCHER = '__HOME__/Applications/Claude (IP Guard).app/Contents/MacOS/ClaudeIPGuard'

const CHECK = '__HOME__/.claude/bin/claude-ip-check'
const CONFIG = '__HOME__/.claude/ip-guard.conf' // MIN_SCORE=<0-99>, shared with claude-ip-check
const DEFAULT_MIN = 95

export const parseMin = (text: string): number => {
  const m = [...text.matchAll(/^MIN_SCORE=(\d+)\s*$/gm)].pop()
  const n = m ? Number(m[1]) : NaN
  return n >= 0 && n <= 99 ? n : DEFAULT_MIN
}

const report = { plugin: 'cleanip', key: 'report' } as const

const field = (t: string, label: string) =>
  new RegExp(`^\\s*${label}\\s+(.+?)\\s*$`, 'm').exec(t)?.[1]?.replace(/[\[\]]/g, '').replace(/\s+/g, ' ').trim()

export const judge = (raw: string, min = DEFAULT_MIN): Report => {
  const t = raw.replace(/\x1b\[[0-9;]*m/g, '')
  const ip = /^\s*IP\s+([0-9a-fA-F:.]+)(?:\s|$)/m.exec(t)?.[1]
  const score = /CleanIP\s*评分.*?(\d+)\s*\/\s*100(?:\s*\((\S+?)\))?/.exec(t)
  const ip_type = field(t, 'IP 类型')
  const network = field(t, '网络类型')
  // Prefer the explicit IP type; use a residential network only when it is unknown.
  const type = (!ip_type || ['未知类型', '未知'].includes(ip_type)) && network?.replace(/\s+/g, '') === '住宅IP'
    ? '住宅 IP'
    : ip_type
  if (!ip || !score || !type) return { ok: false, why: '检测失败' }

  const r: Report = {
    ok: true,
    ip,
    score: Number(score[1]),
    grade: score[2],
    type,
    ip_type,
    native: field(t, '原生 / 广播'),
    network,
  }
  if (r.score! <= min) return { ...r, ok: false, why: `评分 ≤ ${min}` }
  if (!type.includes('住宅')) return { ...r, ok: false, why: '非住宅 IP' }
  return r
}

// The status line is one line of plain text: no image and no colour of its own.
const gauge = (score: number) => {
  const n = Math.max(0, Math.min(10, Math.floor(score / 10)))
  return '▰'.repeat(n) + '▱'.repeat(10 - n)
}
const tag = (s?: string) => s?.replace(/\s*IP$/, '')

export const statusLine = (r: Report): string => {
  const score = r.score === undefined ? '' : ` ${r.score}${r.grade ? ` ${r.grade}` : ''} ${gauge(r.score)}`
  const head = score.trim()
  if (!r.ok) return [`${head ? `${head} ` : ''}⛔ 未通过`, r.why, r.ip].filter(Boolean).join(' · ')
  const tags = [tag(r.native), tag(r.type), r.network].filter(Boolean).join(' · ')
  return [head, tags, r.ip].filter(Boolean).join(' · ')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    let r: Report
    try {
      const checked = await $.process.run([CHECK, '--json'], { timeoutMs: 70000 })  // the checker retries a failed lookup up to 3 times
      const parsed = JSON.parse(checked.stdout)
      if (typeof parsed.ok !== 'boolean' || (parsed.ok && typeof parsed.ip !== 'string')) throw Error('invalid report')
      r = parsed
      if (r.ok && r.ip) {
        const ready = await $.process.run([OVERRIDE, '--ensure', r.ip], { timeoutMs: 15000 }).catch(() => null)
        if (ready?.exitCode !== 0) r = { ...r, ok: false, why: '监控未就绪或出口不一致' }
      }
    } catch {
      r = { ok: false, why: '网络错误' }
    }
    await $.state.set(report, r)
    $.ui.status(statusLine(r))

    if (!r.ok) {
      let authorized = await $.process.run([OVERRIDE, '--status'], { timeoutMs: 5000 }).catch(() => null)
      if (authorized?.exitCode !== 0) {
        const confirmation = await $.process.run(
          ['/bin/sh', '-c', 'exec "$1" --confirm-session "$PPID"', 'cleanip-confirm', LAUNCHER],
          { timeoutMs: 180000 },
        ).catch(() => null)
        if (confirmation?.exitCode === 0) {
          authorized = await $.process.run([OVERRIDE, '--status'], { timeoutMs: 5000 }).catch(() => null)
        }
      }
      if (authorized?.exitCode === 0) {
        await $.state.set(report, { ...r, forced: true })
        $.ui.status('⚠ 本次强制启动 · CleanIP 检测未通过 · IP 变化监控保留')
        return started
      }
      $.ui.toast(`IP 未通过:${r.why}。正在关闭 Claude Code。`)
      await $.process.run(['sh', '-c', 'kill -TERM $PPID'], { timeoutMs: 5000 }).catch(() => undefined)
    }
    return started
  })

  // Verify the live egress before accepting a user prompt.
  on('prompt.submit', async ($, e, next) => {
    const { value: r } = await $.state.get(report).catch(() => ({ value: null }))
    if (!r || (!r.ok && !r.forced)) return { drop: `已拦截:${r?.why ?? '检测尚未完成'}` }
    if (r.forced) {
      const authorization = await $.process.run([OVERRIDE, '--status'], { timeoutMs: 5000 }).catch(() => null)
      if (authorization?.exitCode !== 0) return { drop: '本次强制授权已失效，请重新启动并确认' }
    }
    const live = await $.process.run([OVERRIDE, '--verify'], { timeoutMs: 12000 }).catch(() => null)
    return live?.exitCode === 0 ? next(e) : { drop: '网络一致性检测未通过，请通过 IP Guard 重新检测' }
  }).catch(() => ({ drop: '网络保护检查失败，已拦截发送' }))

  // A tool loop can make more model requests without another user prompt.
  on('turn.step', async function* ($, e, next) {
    const { value: r } = await $.state.get(report).catch(() => ({ value: null }))
    const valid = r && (r.ok || r.forced)
      ? await $.process.run([OVERRIDE, r.forced ? '--status' : '--health'], { timeoutMs: 5000 }).catch(() => null)
      : null
    if (valid?.exitCode !== 0) {
      $.ui.status('⛔ 网络监控未就绪或授权失效，已停止模型请求')
      await $.turn.abort({ turnId: e.turnId }).catch(() => undefined)
      return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
    }
    return yield* next(e)
  }).catch(async function* ($, e) {
    await $.turn.abort({ turnId: e.turnId }).catch(() => undefined)
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
  })
}
