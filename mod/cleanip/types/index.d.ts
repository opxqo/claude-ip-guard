export type Report = {
  forced?: boolean
  ok: boolean
  why?: string
  ip?: string
  trust?: number   // ip.net.coffee trust_score: the gate
  score?: number   // CleanIP score: reference only
  grade?: string
  type?: string
  ip_type?: string
  native?: string
  network?: string
}

declare module 'claude-code' {
  interface PluginState {
    cleanip: { report: Report | null }
  }
}
