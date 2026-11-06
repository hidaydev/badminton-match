// Client mirror of modules/session/scoring.nim. The server stays authoritative;
// this only keeps the editor from offering a set the API will refuse, and it
// must be changed in step with the engine's validation rules.
import type { SessionScoring, SetScore } from '../types'

export interface SetVerdict {
  error: string | null
  set: number // 1-based; 0 means the complaint is about the list
}

export function setsWon(sets: SetScore[]): { a: number; b: number } {
  let a = 0
  let b = 0
  for (const set of sets) {
    if (set.a > set.b) a += 1
    else b += 1
  }
  return { a, b }
}

export function totalPoints(sets: SetScore[]): { a: number; b: number } {
  let a = 0
  let b = 0
  for (const set of sets) {
    a += set.a
    b += set.b
  }
  return { a, b }
}

export function matchComplete(rules: SessionScoring, sets: SetScore[]): boolean {
  const won = setsWon(sets)
  return won.a >= rules.gamesToWin || won.b >= rules.gamesToWin
}

export function winnerOf(rules: SessionScoring, sets: SetScore[]): 'A' | 'B' | null {
  const won = setsWon(sets)
  if (won.a >= rules.gamesToWin) return 'A'
  if (won.b >= rules.gamesToWin) return 'B'
  return null
}

export function validateSet(rules: SessionScoring, set: SetScore, index: number): string | null {
  const prefix = `Set ${index}: `
  if (!Number.isInteger(set.a) || !Number.isInteger(set.b)) return `${prefix}scores must be whole numbers`
  if (set.a < 0 || set.b < 0) return `${prefix}scores cannot be negative`
  if (set.a > 99 || set.b > 99) return `${prefix}scores must be between 0 and 99`
  if (set.a === set.b) return `${prefix}scores cannot be equal`
  const high = Math.max(set.a, set.b)
  const low = Math.min(set.a, set.b)
  if (high > rules.maxPoints) return `${prefix}the score is above the cap of ${rules.maxPoints}`
  if (high < rules.pointsToWin) return `${prefix}the winner must reach ${rules.pointsToWin}`
  if (high === rules.maxPoints) return null
  const need = rules.deuceAt !== null && low >= rules.deuceAt ? rules.winBy : 1
  if (high - low < need) {
    return rules.deuceAt !== null
      ? `${prefix}win by ${rules.winBy} at ${rules.deuceAt}–${rules.deuceAt}`
      : `${prefix}the winning margin is too small`
  }
  return null
}

export function validateSets(rules: SessionScoring, sets: SetScore[]): SetVerdict {
  if (sets.length > 2 * rules.gamesToWin - 1) {
    return { error: 'Too many sets for this format', set: 0 }
  }
  let wonA = 0
  let wonB = 0
  for (let index = 0; index < sets.length; index += 1) {
    const single = validateSet(rules, sets[index], index + 1)
    if (single !== null) return { error: single, set: index + 1 }
    if (wonA >= rules.gamesToWin || wonB >= rules.gamesToWin) {
      return { error: `Set ${index + 1}: the match is already won`, set: index + 1 }
    }
    if (sets[index].a > sets[index].b) wonA += 1
    else wonB += 1
  }
  return { error: null, set: 0 }
}

/** A finished match's set line, e.g. `21–18 · 19–21 · 21–17`. */
export function describeSets(sets: SetScore[]): string {
  return sets.map((set) => `${set.a}–${set.b}`).join(' · ')
}