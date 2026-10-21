import { expect, test } from 'claude-code/testing'
import { register } from '../hooks/register.js'

test('forwards only plan quota and preserves the event', async ($, on) => {
  let calls = 0
  on('session.measure', ($, e) => ({ changed: e.changed }))
  on('process.run', ($, e) => {
    calls++
    expect(e.argv).toEqual(['__BUILDRHOOKS_EXECUTABLE__', 'claude', 'mod', 'capture', '--json'])
    expect(e.init.timeoutMs).toBe(1500)
    expect(JSON.parse(e.init.stdin)).toEqual({ rate_limits: {
      five_hour: { used_percentage: 0, resets_at: 2000000000 },
      seven_day: { used_percentage: 25 }
    } })
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  const result = await $.session.measure({
    context: { percent: 99 }, cost: { total: 100 }, changed: ['rateLimits'],
    rateLimits: [
      { kind: 'five_hour', percentUsed: 0, resetsAt: '2033-05-18T03:33:20Z' },
      { kind: 'seven_day', percentUsed: 25 },
      { kind: 'spend_limit', percentUsed: 200 }
    ]
  })
  expect(calls).toBe(1)
  expect(result).toEqual({ changed: ['rateLimits'] })
})

for (const limits of [[], [{ kind: 'spend_limit', percentUsed: 200 }],
  [{ kind: 'five_hour', percentUsed: 7 }], [{ kind: 'seven_day', percentUsed: 0 }]]) {
  test('accepts empty, unknown and partial quota ' + JSON.stringify(limits), async ($, on) => {
    let input
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', ($, e) => {
      input = JSON.parse(e.init.stdin)
      return { value: { exitCode: 0, stdout: '', stderr: '' } }
    })
    await $.session.measure({ context: {}, rateLimits: limits, changed: ['rateLimits'] })
    const expected = {}
    for (const limit of limits) {
      if (limit.kind !== 'spend_limit') expected[limit.kind] = { used_percentage: limit.percentUsed }
    }
    expect(input).toEqual({ rate_limits: expected })
  })
}

for (const bad of [
  [{ kind: 'five_hour', percentUsed: 2 }, { kind: 'five_hour', percentUsed: 3 }],
  ...[false, null, -1, 101, NaN, Infinity, '0'].map(percentUsed => [{ kind: 'five_hour', percentUsed }]),
  ...[1234, '2000000000000', '2033-02-30T00:00:00Z', '2033-13-01T00:00:00Z',
    '1969-01-01T00:00:00Z', 'invalid'].map(resetsAt => [{ kind: 'seven_day', percentUsed: 1, resetsAt }])
]) {
  test('rejects entire malformed quota ' + JSON.stringify(bad), async ($, on) => {
    let calls = 0
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', () => {
      calls++
      return { value: { exitCode: 0, stdout: '', stderr: '' } }
    })
    const result = await $.session.measure({ context: {}, rateLimits: bad, changed: ['rateLimits'] })
    expect(calls).toBe(0)
    expect(result).toEqual({ changed: ['rateLimits'] })
  })
}

for (const failure of ['denied', 'nonzero']) {
  test('isolates bridge failure: ' + failure, async ($, on) => {
    let calls = 0
    on('session.measure', ($, e) => ({ changed: e.changed }))
    on('process.run', () => {
      calls++
      return failure === 'denied' ? { deny: 'execution disabled' } :
        { value: { exitCode: 17, stdout: '', stderr: 'unavailable' } }
    })
    for (let i = 0; i < 2; i++) {
      const result = await $.session.measure({ context: {}, rateLimits: [], changed: ['rateLimits'] })
      expect(result).toEqual({ changed: ['rateLimits'] })
    }
    expect(calls).toBe(2)
  })
}

test('drops concurrent work and skips an abandoned callback before process execution', async () => {
  let handler
  register((name, callback) => {
    handler = callback
    return { catch() {} }
  })
  let release
  let calls = 0
  const engine = { process: { run: async () => {
    calls++
    await new Promise(resolve => { release = resolve })
    return { exitCode: 0, stdout: '', stderr: '' }
  } } }
  const controller = new AbortController()
  let passed = 0
  const next = Object.assign(async e => { passed++; return { changed: e.changed } },
    { signal: controller.signal })
  const event = { rateLimits: [], changed: ['rateLimits'] }
  const pending = handler(engine, event, next)
  await handler(engine, event, next)
  expect(calls).toBe(1)
  release()
  await pending
  controller.abort()
  await handler(engine, event, next)
  expect(calls).toBe(1)
  expect(passed).toBe(3)
})
