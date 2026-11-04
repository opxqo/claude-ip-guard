export type Report = {
  forced?: boolean
  ok: boolean
  why?: string
  ip?: string
  score?: number
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
