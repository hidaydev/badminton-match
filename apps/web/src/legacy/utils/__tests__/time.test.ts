import { describe, expect, it } from 'vitest'
import {
  computeSlotAllocation,
  computeTimeSlots,
  courtsAtTime,
  formatMergedCourtTimes,
  timeToSlotIndex,
} from '../time'
import { toTimeString } from '../../types'
import type { CourtTime, SessionConfig } from '../../types'

const courtTime = (start: string, end: string): CourtTime => ({
  start: toTimeString(start),
  end: toTimeString(end),
})

const sessionConfig = (overrides: Partial<SessionConfig> = {}): SessionConfig => ({
  title: 'Morning',
  date: '2026-11-08',
  courts: 2,
  sessionStart: toTimeString('09:00'),
  slotMinutes: 30,
  courtTimes: [courtTime('09:00', '10:00'), courtTime('09:30', '11:00')],
  playerCount: 8,
  courtNames: [],
  locked: false,
  ...overrides,
})

describe('computeTimeSlots', () => {
  it('produces one entry per slot and stops before the last court end time', () => {
    const slots = computeTimeSlots(sessionConfig())

    expect(slots).toEqual(['09:00', '09:30', '10:00', '10:30'])
    expect(slots).not.toContain('11:00')
  })

  it('keeps a slot only once when two courts share its start', () => {
    const slots = computeTimeSlots(
      sessionConfig({
        courtTimes: [courtTime('09:00', '10:00'), courtTime('09:00', '09:30')],
      }),
    )

    expect(slots).toEqual(['09:00', '09:30'])
  })
})

describe('computeSlotAllocation', () => {
  it('counts slots per court and sums them, even when the windows overlap', () => {
    const allocation = computeSlotAllocation(
      [courtTime('09:00', '10:00'), courtTime('09:30', '11:00')],
      30,
    )

    expect(allocation).toEqual({ slotsPerCourt: [2, 3], totalGames: 5 })
  })

  it('floors a window that cannot fit a single slot at zero', () => {
    const allocation = computeSlotAllocation([{ start: toTimeString('10:00'), end: toTimeString('09:00') }], 30)

    expect(allocation).toEqual({ slotsPerCourt: [0], totalGames: 0 })
  })
})

describe('courtsAtTime', () => {
  it('returns the courts whose window still fits a full slot', () => {
    const session = sessionConfig()

    expect(courtsAtTime(session, '09:30')).toEqual([0, 1])
    expect(courtsAtTime(session, '10:00')).toEqual([1])
    expect(courtsAtTime(session, '11:00')).toEqual([])
  })
})

describe('timeToSlotIndex', () => {
  it('counts slots from the session start', () => {
    const session = sessionConfig()

    expect(timeToSlotIndex(session, '09:00')).toBe(0)
    expect(timeToSlotIndex(session, '09:30')).toBe(1)
    expect(timeToSlotIndex(session, '10:15')).toBe(2)
  })
})

describe('formatMergedCourtTimes', () => {
  it('collapses overlapping windows into a single range', () => {
    expect(formatMergedCourtTimes([courtTime('09:00', '10:00'), courtTime('09:30', '11:00')])).toBe(
      '09:00–11:00',
    )
    expect(formatMergedCourtTimes([courtTime('10:00', '11:00'), courtTime('09:00', '12:00')])).toBe(
      '09:00–12:00',
    )
  })

  it('sorts the windows and keeps a real gap between ranges', () => {
    expect(formatMergedCourtTimes([courtTime('14:00', '16:00'), courtTime('09:00', '10:00')])).toBe(
      '09:00–10:00 · 14:00–16:00',
    )
  })

  it('returns an empty string for no court times', () => {
    expect(formatMergedCourtTimes([])).toBe('')
  })
})