import type { ReactNode } from 'react'
import { formatDiff } from '../utils/formatDiff'

/**
 * The standings ledger, once. The public share page and the summary's
 * StandingsTab used to carry the same header row, the same column widths and
 * the same podium classes, so a change to the zero glyph or the rank tie had
 * to be made twice.
 *
 * The caller supplies the labels (the share page translates them, the v1
 * summary has its own short words) and one row per player. A row with
 * `onSelect` renders its name as a button, which is how the summary opens the
 * per-player sheet.
 */
export type StandingsRow = {
  /** Stable identity for the list key: a player id or a name. */
  key: string
  /** The rank cell, already formatted (`1st`, `2nd`, ...). */
  rank: string
  name: ReactNode
  wins: number
  losses: number
  diff: number
  pointsFor: number
  onSelect?: () => void
}

export type StandingsLabels = {
  name: string
  winsLosses: string
  diff: string
  points: string
}

function rowTone(rank: number): string {
  return rank <= 3
    ? 'bg-emerald-950/45 border-emerald-800/35'
    : 'bg-slate-800/30 border-slate-700/20'
}

function nameTone(rank: number): string {
  if (rank === 1) return 'text-sm font-bold text-emerald-300'
  if (rank <= 3) return 'text-sm font-semibold text-emerald-100/80'
  return 'text-sm font-medium text-slate-400'
}

function rankTone(rank: number): string {
  if (rank === 1) return 'text-accent'
  if (rank === 2) return 'text-slate-200'
  return 'text-slate-400'
}

function resultTone(wins: number, losses: number): string {
  if (wins > losses) return 'text-emerald-400'
  if (losses > wins) return 'text-red-400'
  return 'text-slate-400'
}

function diffTone(diff: number): string {
  if (diff > 0) return 'text-emerald-400'
  if (diff < 0) return 'text-red-400'
  return 'text-slate-400'
}

export function StandingsTable({
  rows,
  labels,
}: {
  rows: readonly StandingsRow[]
  labels: StandingsLabels
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2 pl-2 pr-2 mb-1">
        <span className="w-8 shrink-0 text-center text-[10px] font-bold text-slate-400">#</span>
        <span className="flex-1 text-[10px] font-bold text-slate-400">{labels.name}</span>
        <span className="w-11 shrink-0 text-center text-[10px] font-bold text-slate-400">
          {labels.winsLosses}
        </span>
        <span className="w-9 shrink-0 text-center text-[10px] font-bold text-slate-400">
          {labels.diff}
        </span>
        <span className="w-9 shrink-0 text-center text-[10px] font-bold text-slate-400">
          {labels.points}
        </span>
      </div>
      <ol role="list" className="flex flex-col gap-1.5">
        {rows.map((row, index) => {
          const rank = index + 1
          const nameClass = `min-w-0 truncate ${nameTone(rank)}`
          return (
            <li
              key={row.key}
              className={`flex items-center gap-2 pl-2 pr-2 py-2.5 rounded-xl border ${rowTone(rank)}`}
            >
              <span
                className={`w-8 shrink-0 text-center text-[11px] font-bold tabular-nums ${rankTone(rank)}`}
              >
                {row.rank}
              </span>
              {row.onSelect === undefined ? (
                <span className={`flex-1 ${nameClass}`}>{row.name}</span>
              ) : (
                <button
                  type="button"
                  onClick={row.onSelect}
                  className={`hit44 flex-1 text-left cursor-pointer active:opacity-70 ${nameClass}`}
                >
                  {row.name}
                </button>
              )}
              <span
                className={`w-11 shrink-0 text-center text-[11px] font-semibold tabular-nums ${resultTone(row.wins, row.losses)}`}
              >
                {row.wins}-{row.losses}
              </span>
              <span
                className={`w-9 shrink-0 text-center text-[11px] font-semibold tabular-nums ${diffTone(row.diff)}`}
              >
                {formatDiff(row.diff)}
              </span>
              <span className="w-9 shrink-0 text-center text-[11px] font-semibold tabular-nums text-slate-400">
                {row.pointsFor}
              </span>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
