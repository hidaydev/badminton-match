import { describe, expect, it } from 'vitest'
import { mockFetch } from '../test/fetchMock'
import { ApiError, SESSION_EXPIRED_EVENT } from './errors'
import { request } from '../auth/api'
import { t } from '../i18n'
import { ApiError as LegacyApiError } from '../legacy/queries/endpoints'
import { getSaveErrorMessage } from '../legacy/queries/errors'

describe('ApiError', () => {
  it('is one class for the v2 client and the legacy adapter', () => {
    expect(LegacyApiError).toBe(ApiError)
  })

  it('is recognised by the legacy message mapper when a v2 screen throws it', () => {
    const error = new ApiError('412 STALE_VERSION', 'STALE_VERSION', 412)
    expect(getSaveErrorMessage(error)).toBe(t('session.stale'))
  })
})

describe('request', () => {
  it('signals the shell when the session cookie is gone', async () => {
    mockFetch({
      'GET /api/c/acme/sessions': () => ({
        status: 401,
        body: { code: 'UNAUTHENTICATED', detail: 'no session cookie' },
      }),
    })
    const seen: string[] = []
    const listener = () => seen.push('expired')
    window.addEventListener(SESSION_EXPIRED_EVENT, listener)

    try {
      await expect(request('/c/acme/sessions')).rejects.toBeInstanceOf(ApiError)
    } finally {
      window.removeEventListener(SESSION_EXPIRED_EVENT, listener)
    }

    expect(seen).toEqual(['expired'])
  })
})