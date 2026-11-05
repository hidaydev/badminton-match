// Time helpers for the wizard. Pure functions; no store or framework imports.

import type { CourtTime, SessionConfig } from './types'

/** Today in WIB as YYYY-MM-DD, matching the server's calendar day. */
export function todayWIB(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Jakarta',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const get = (type: Intl.DateTimeFormatPartTypes) => parts.find((p) => p.type === type)?.value ?? ''
  return `${get('year')}-${get('month')}-${get('day')}`
}

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
    Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / slotMinutes)),
  )
  return { slotsPerCourt, totalGames: slotsPerCourt.reduce((a, b) => a + b, 0) }
}

/** Court label: a configured name, else A/B/C… */
export function courtLabel(courtNames: string[] | undefined, courtIndex: number): string {
  const name = courtNames?.[courtIndex]
  if (name) return name
  return courtIndex <= 25 ? String.fromCharCode(65 + courtIndex) : String(courtIndex + 1)
}
