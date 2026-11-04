import { test, expect } from 'claude-code/testing'
import { judge, statusLine, parseMin } from './register'

const page = (score: number, type: string) =>
  `  IP              \x1b[1m1.2.3.4\x1b[0m  (IPv4)\n  网络类型        ISP\n  IP 类型         ${type}\n  原生 / 广播      原生 IP \n  CleanIP 评分    \x1b[1m${score}\x1b[0m/100 (A+)\n`

test('score above 95 and residential passes', () => {
  expect(judge(page(97, ' 住宅 IP ')).ok).toBe(true)
})
test('score 95 is refused', () => {
  expect(judge(page(95, ' 住宅 IP ')).ok).toBe(false)
})
test('datacenter is refused even with a high score', () => {
  expect(judge(page(99, ' 机房 IP ')).ok).toBe(false)
})
test('garbage is refused', () => {
  expect(judge('oops').ok).toBe(false)
})
test('status line condenses the card', () => {
  expect(statusLine(judge(page(97, ' 住宅 IP ')))).toBe('97 A+ ▰▰▰▰▰▰▰▰▰▱ · 原生 · 住宅 · ISP · 1.2.3.4')
  expect(statusLine(judge(page(88, ' 住宅 IP ')))).toBe('88 A+ ▰▰▰▰▰▰▰▰▱▱ ⛔ 未通过 · 评分 ≤ 95 · 1.2.3.4')
})
test('failed lookup still reads clearly', () => {
  expect(statusLine({ ok: false, why: '网络错误' })).toBe('⛔ 未通过 · 网络错误')
})
test('bracketed plain-text report (non-curl agent) reads the same', () => {
  const plain = '  IP              1.2.3.4  (IPv4)\n  网络类型        ISP\n  IP 类型         [住宅 IP]\n  原生 / 广播     [原生 IP]\n  CleanIP 评分    [###################-] 97/100 (A+)\n'
  expect(statusLine(judge(plain))).toBe('97 A+ ▰▰▰▰▰▰▰▰▰▱ · 原生 · 住宅 · ISP · 1.2.3.4')
})
test('threshold comes from the config file text', () => {
  expect(parseMin('MIN_SCORE=90\n')).toBe(90)
  expect(parseMin('# c\nMIN_SCORE=80\nMIN_SCORE=97\n')).toBe(97)
  expect(parseMin('MIN_SCORE=150')).toBe(95)
  expect(parseMin('')).toBe(95)
})
test('a lower threshold lets a lower score through', () => {
  expect(judge(page(92, ' 住宅 IP '), 90).ok).toBe(true)
  expect(judge(page(92, ' 住宅 IP '), 95).ok).toBe(false)
})
