// src/utils/time.ts
// Pure time/scheduling utilities — zero dependencies ke store atau framework.

import type { CourtTime, SessionConfig } from '../types'

export function timeToMinutes(t: string): number {
  const [h, m] = t.split(':').map(Number)
  return h * 60 + (m || 0)
}

export function minutesToTime(m: number): string {
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
}

export function computeTimeSlots(session: SessionConfig): string[] {
  const allSlots = new Set<string>()
  for (const ct of session.courtTimes) {
    const start = timeToMinutes(ct.start)
    const end = timeToMinutes(ct.end)
    for (let m = start; m < end; m += session.slotMinutes) {
      allSlots.add(minutesToTime(m))
    }
  }
  return [...allSlots].sort()
}

export function courtsAtTime(session: SessionConfig, time: string): number[] {
  const t = timeToMinutes(time)
  return session.courtTimes
    .map((ct, i) => ({ ct, i }))
    .filter(({ ct }) => {
      const start = timeToMinutes(ct.start)
      const end = timeToMinutes(ct.end)
      return t >= start && t + session.slotMinutes <= end
    })
    .map(({ i }) => i)
}

export function timeToSlotIndex(session: SessionConfig, time: string): number {
  return Math.floor((timeToMinutes(time) - timeToMinutes(session.sessionStart)) / session.slotMinutes)
}

export function computeSlotAllocation(courtTimes: CourtTime[], slotMinutes: number) {
  const slotsPerCourt = courtTimes.map((ct) =>
    Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / slotMinutes))
  )
  return { slotsPerCourt, totalGames: slotsPerCourt.reduce((a, b) => a + b, 0) }
}
