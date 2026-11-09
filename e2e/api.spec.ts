import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, request, test } from 'playwright/test'

/**
 * The anonymous edge of the API, driven over its own socket.
 *
 * QAE-02 to QAE-06 were found by hand against a local build. These checks turn
 * the ones that hold today into a permanent regression, and every one of them
 * talks to the API the e2e harness started (`./task e2e`), never to a mock.
 * The browser projects ignore this file; the `api` project runs it once.
 */
const apiURL = process.env.E2E_API_URL ?? 'http://127.0.0.1:18093'
const flagURL = process.env.E2E_FLAG_API_URL ?? 'http://127.0.0.1:18094'

/**
 * The limit this deployment really has, read from the seed the harness applies
 * instead of repeated here. A test with its own copy of 1 MiB would pass a rule
 * the deployment no longer has (the same reasoning as BE-16).
 */
function seededBodyLimit(): number {
  const seed = readFileSync(
    join(__dirname, '..', 'db', 'seeds', 'platform_config.sql'),
    'utf8',
  )
  const value = seed.match(
    /'security\.max_body_bytes'\s*,\s*'int'\s*,\s*'(\d+)'/,
  )
  if (!value) {
    throw new Error(
      'security.max_body_bytes is missing from db/seeds/platform_config.sql',
    )
  }
  return Number(value[1])
}

/** A valid JSON body of exactly `size` bytes; the handler ignores unknown keys. */
function paddedBody(size: number): string {
  const head = '{"name":"Audit Probe","pad":"'
  const tail = '"}'
  const pad = size - head.length - tail.length
  if (pad < 0) throw new Error(`${size} bytes cannot hold the probe body`)
  return head + 'x'.repeat(pad) + tail
}

test('QAE-02: a 2 MB body is answered with 413, not a closed socket', async () => {
  const api = await request.newContext({ baseURL: apiURL })
  const response = await api.post('/c/qae-probe/join-requests', {
    data: paddedBody(2 * 1024 * 1024),
    headers: { 'Content-Type': 'application/json' },
  })

  expect(response.status()).toBe(413)
  expect(response.headers()['content-type']).toContain(
    'application/problem+json',
  )
  const problem = await response.json()
  expect(problem.code).toBe('BODY_TOO_LARGE')
  expect(problem.status).toBe(413)
  expect(problem.detail.length).toBeGreaterThan(0)
  await api.dispose()
})

test('QAE-02: the 413 carries the same envelope as every other rejection', async () => {
  const api = await request.newContext({ baseURL: apiURL })
  const tooLarge = await api.post('/c/qae-probe/join-requests', {
    data: paddedBody(seededBodyLimit() + 1),
    headers: { 'Content-Type': 'application/json' },
  })
  const notFound = await api.get('/qae-probe-no-such-route')

  expect(tooLarge.status()).toBe(413)
  expect(notFound.status()).toBe(404)
  const problemKeys = Object.keys(await tooLarge.json()).sort()
  const notFoundKeys = Object.keys(await notFound.json()).sort()
  expect(problemKeys).toEqual(notFoundKeys)
  await api.dispose()
})

test('QAE-02: the boundary is the configured limit, one byte either side', async () => {
  const api = await request.newContext({ baseURL: apiURL })
  const limit = seededBodyLimit()

  // At the limit the body reaches the handler, and the anti-enumeration
  // acknowledgement is the proof it did.
  const atLimit = await api.post('/c/qae-probe/join-requests', {
    data: paddedBody(limit),
    headers: { 'Content-Type': 'application/json' },
  })
  expect(atLimit.status()).toBe(202)

  const overLimit = await api.post('/c/qae-probe/join-requests', {
    data: paddedBody(limit + 1),
    headers: { 'Content-Type': 'application/json' },
  })
  expect(overLimit.status()).toBe(413)
  expect((await overLimit.json()).code).toBe('BODY_TOO_LARGE')
  await api.dispose()
})

test('QAE-02: a body past the transport ceiling leaves the API serving', async () => {
  const api = await request.newContext({ baseURL: apiURL })

  // mummy closes the socket before any handler runs once a body passes its own
  // `maxBodyLen` (16 MiB, the registry ceiling). No answer is possible there,
  // so the outcome is either the 413 the guard sends or no HTTP response at
  // all; what must never happen is a 5xx or a dead process.
  let answered: number | null = null
  try {
    const response = await api.post('/c/qae-probe/join-requests', {
      data: paddedBody(20 * 1024 * 1024),
      headers: { 'Content-Type': 'application/json' },
    })
    answered = response.status()
  } catch {
    answered = null
  }
  expect([null, 413]).toContain(answered)

  const health = await api.get('/healthz')
  expect(health.status()).toBe(200)
  expect((await health.json()).status).toBe('ok')
  await api.dispose()
})

test('QAE-03: MAJADU_TEST_ROUTES cannot degrade a release build', async () => {
  // The harness starts this instance from the same binary with the flag set.
  // A release build compiles the flag out, so every answer below belongs to the
  // real application. The stub would answer `{"status":"stub"}` on /healthz,
  // 404 on /readyz and 404 on every data route while /healthz stayed 200, which
  // is the process an orchestrator would keep in service.
  const flag = await request.newContext({ baseURL: flagURL })

  const health = await flag.get('/healthz')
  expect(health.status()).toBe(200)
  expect((await health.json()).status).toBe('ok')

  expect((await flag.get('/readyz')).status()).toBe(200)

  const data = await flag.get('/c/qae-probe/sessions')
  expect(data.status()).toBe(401)
  await flag.dispose()
})

test('QAE-04: the join request answers 202 to every anonymous caller', async () => {
  // The 202 is an acknowledgement, not a receipt: an anonymous caller cannot
  // tell a stored request from a malformed one, from a community that does not
  // exist, or from a community that is not accepting. The check pins that
  // indistinguishability, so making the answer truthful later forces this test
  // and `docs/qa/sessions/QAE-04-join-202.md` to change together.
  const api = await request.newContext({ baseURL: apiURL })

  const wellFormed = await api.post('/c/qae-probe/join-requests', {
    data: { name: 'Audit Probe', phone: '0812' },
  })
  const malformed = await api.post('/c/qae-probe/join-requests', {
    data: '{bad',
    headers: { 'Content-Type': 'application/json' },
  })
  const unknown = await api.post('/c/qae-probe-no-such-community/join-requests', {
    data: { name: 'Audit Probe', phone: '0812' },
  })

  for (const response of [wellFormed, malformed, unknown]) {
    expect(response.status()).toBe(202)
    expect(await response.json()).toEqual({ status: 'accepted' })
  }
  await api.dispose()
})
