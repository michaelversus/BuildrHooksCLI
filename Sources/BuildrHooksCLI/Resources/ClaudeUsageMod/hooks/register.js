// SessionRateLimit in the published Claude Code 2.1.277 declarations:
// kind, percentUsed (0...100), resetsAt (ISO 8601). No context/cost/session data leaves here.
const executable = '__BUILDRHOOKS_EXECUTABLE__'

function normalize(limits) {
  if (!Array.isArray(limits) || limits.length > 64) throw new Error('invalid quota')
  const rate_limits = {}
  for (const window of limits) {
    if (window?.kind !== 'five_hour' && window?.kind !== 'seven_day') continue
    if (Object.hasOwn(rate_limits, window.kind) || typeof window.percentUsed !== 'number' ||
        !Number.isFinite(window.percentUsed) || window.percentUsed < 0 || window.percentUsed > 100) {
      throw new Error('invalid quota')
    }
    const quota = { used_percentage: window.percentUsed }
    if (window.resetsAt !== undefined) {
      // ISO timestamps only. Never guess epoch units from a numeric magnitude.
      if (typeof window.resetsAt !== 'string' || window.resetsAt.length > 40 ||
          !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(window.resetsAt)) {
        throw new Error('invalid reset')
      }
      const milliseconds = Date.parse(window.resetsAt)
      if (!Number.isSafeInteger(milliseconds) || milliseconds < 0) throw new Error('invalid reset')
      const year = Number(window.resetsAt.slice(0, 4))
      const month = Number(window.resetsAt.slice(5, 7))
      const day = Number(window.resetsAt.slice(8, 10))
      if (month < 1 || month > 12 || day < 1 ||
          day > new Date(Date.UTC(year, month, 0)).getUTCDate()) throw new Error('invalid reset')
      // Existing status-line capture accepts integer Unix seconds. Round down only
      // subsecond precision; this is a reset deadline, never a freshness timestamp.
      quota.resets_at = Math.floor(milliseconds / 1000)
    }
    rate_limits[window.kind] = quota
  }
  return JSON.stringify({ rate_limits })
}

export function register(on) {
  let busy = false
  on('session.measure', async ($, e, next) => {
    if (busy || next.signal.aborted) return next(e)
    busy = true
    try {
      const stdin = normalize(e.rateLimits)
      if (!next.signal.aborted) {
        await $.process.run([executable, 'claude', 'mod', 'capture', '--json'], { stdin, timeoutMs: 1500 })
      }
    } catch {
      // Permission, unsupported API, missing executable and malformed reports are
      // isolated from the conversation. Do not log payloads or provider error text.
    } finally {
      busy = false
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
