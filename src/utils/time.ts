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

/**
 * Merge overlapping court time ranges and return a formatted string.
 * Example: "09:00–11:00 · 14:00–16:00"
 */
export function formatMergedCourtTimes(courtTimes: CourtTime[]): string {
  if (courtTimes.length === 0) return ''
  const ranges = courtTimes
    .map((ct) => ({ start: timeToMinutes(ct.start), end: timeToMinutes(ct.end) }))
    .sort((a, b) => a.start - b.start)
  const merged: { start: number; end: number }[] = []
  for (const r of ranges) {
    if (merged.length === 0 || r.start > merged[merged.length - 1].end) {
      merged.push({ ...r })
    } else {
      merged[merged.length - 1].end = Math.max(merged[merged.length - 1].end, r.end)
    }
  }
  return merged.map((r) => `${minutesToTime(r.start)}–${minutesToTime(r.end)}`).join(' · ')
}
