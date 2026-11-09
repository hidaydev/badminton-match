/// <reference types="node" />
import { afterEach, describe, expect, it, vi } from 'vitest'
import { formatInstantDate } from '../day'
import { dayInZone, todayLocal } from '../../legacy/utils/time'
import { setActiveTimeZone } from '../day'

// The point of the helper is that the process timezone does not decide the
// day. Run the file at the far end of the date line to prove it.
process.env.TZ = 'Pacific/Kiritimati'

const INSTANT = '2026-11-03T23:30:00Z'

describe('instant formatting', () => {
  afterEach(() => {
    vi.useRealTimers()
    setActiveTimeZone(null)
  })

  it('renders the instants calendar day in the community timezone', () => {
    // 23:30 UTC is already 06:30 on the 4th in Jakarta, while the UTC slice of
    // the string says the 3rd.
    expect(formatInstantDate(INSTANT, 'Asia/Jakarta')).toBe('4 Nov 2026')
    expect(formatInstantDate(INSTANT, 'UTC')).toBe('3 Nov 2026')
  })

  it('accepts the space-and-short-offset shape the API writes', () => {
    expect(formatInstantDate('2026-11-01 10:00:00+07', 'Asia/Jakarta')).toBe('1 Nov 2026')
    // 03:00 UTC on the 1st is 10:00 WIB, and still the 1st.
    expect(formatInstantDate('2026-11-01T03:00:00Z', 'Asia/Jakarta')).toBe('1 Nov 2026')
  })

  it('leaves a value that is not a timestamp alone', () => {
    expect(formatInstantDate('not a date', 'Asia/Jakarta')).toBe('not a date')
  })

  it('follows the community zone for the default day', () => {
    // 16:30 UTC is 23:30 WIB on the 3rd and 00:30 WITA on the 4th.
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-03T16:30:00Z'))

    expect(todayLocal()).toBe('2026-11-03')
    setActiveTimeZone('Asia/Makassar')
    expect(todayLocal()).toBe('2026-11-04')
    expect(dayInZone('Asia/Jakarta')).toBe('2026-11-03')
  })
})
