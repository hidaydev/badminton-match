import type { ReactNode } from 'react'
import { formatDiff } from '../utils/formatDiff'

/**
 * The standings ledger, once (CMP-07). Six surfaces drew the same rank cell,
 * the same name column and the same points columns by hand, so a change to the
 * zero glyph or the rank tie had to be made six times.
 *
 * The six surfaces do not share one shape: the session ledger and the public
 * share page print five fixed columns, the group card prints a one-line grid,
 * the team tournament prints points pills over a member list, the classic
 * tournament prints a stage line under the name, and the rankings page prints a
 * drill-in row with a movement arrow. Each shape is a `layout` here, and each
 * layout keeps the classes it had at its call site, because the screens are
 * pinned by pixel baselines that must not move for a refactor.
 *
 * The caller supplies the labels and one row per player (or team).
 */
export type StandingsLayout = 'ledger' | 'compact' | 'team' | 'record' | 'rank'

export type StandingsRow = {
  /** Stable identity for the list key: a player id, a team id or a name. */
  key: string
  name: ReactNode
  /** Ledger: the rank cell, already formatted (`1st`). Rank: the rank number. */
  rank?: ReactNode
  wins?: number
  losses?: number
  diff?: number
  pointsFor?: number
  /** Team layout: the standings points pill, which is not the for/against total. */
  points?: number
  /** Team layout: the against half of the for/against pill. */
  pointsAgainst?: number
  /** Record layout: the line under the name, e.g. the tournament stage. */
  sublabel?: ReactNode
  /** Team layout: the block under the row, e.g. the team's players. */
  details?: ReactNode
  /** Rank layout: the movement cell (▲ / ▼ / ·). */
  delta?: ReactNode
  /** Rank layout: the second rank line, e.g. the global rank inside a tier. */
  rankDetail?: ReactNode
  /** Rank layout: a badge beside the name, e.g. the rating tier. */
  nameExtra?: ReactNode
  onSelect?: () => void
  /** compact and team layouts: a row in the qualifying zone. */
  highlighted?: boolean
}

/**
 * The words, supplied by the caller: this primitive holds no literal, because a
 * component in `src/` may not carry a UI string of its own (FE-13).
 */
export type StandingsLabels = {
  /** Ledger header: Name. */
  name?: string
  winsLosses?: string
  diff?: string
  points?: string
  /** Compact header and record pill: the win and loss words. */
  wins?: string
  losses?: string
  /** Team rows: the suffix after the points number. */
  pointsSuffix?: string
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

function Ledger({ rows, labels }: { rows: readonly StandingsRow[]; labels?: StandingsLabels }) {
  if (labels?.name === undefined || labels.winsLosses === undefined || labels.diff === undefined || labels.points === undefined) {
    throw new Error('StandingsTable: the ledger layout needs name, winsLosses, diff and points labels')
  }
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
                {row.rank ?? rank}
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
                className={`w-11 shrink-0 text-center text-[11px] font-semibold tabular-nums ${resultTone(row.wins ?? 0, row.losses ?? 0)}`}
              >
                {row.wins ?? 0}-{row.losses ?? 0}
              </span>
              <span
                className={`w-9 shrink-0 text-center text-[11px] font-semibold tabular-nums ${diffTone(row.diff ?? 0)}`}
              >
                {formatDiff(row.diff ?? 0)}
              </span>
              <span className="w-9 shrink-0 text-center text-[11px] font-semibold tabular-nums text-slate-400">
                {row.pointsFor ?? 0}
              </span>
            </li>
          )
        })}
      </ol>
    </div>
  )
}

const COMPACT_GRID =
  'grid grid-cols-[1.5rem_1fr_1.5rem_1.5rem_2.5rem_0.75rem]'

/**
 * One line per pair inside a group card. The zero difference prints a dash
 * here, not the `0` the ledger prints, because the group card has one character
 * of room; that is the only place the two readings differ.
 */
function Compact({ rows, labels }: { rows: readonly StandingsRow[]; labels?: StandingsLabels }) {
  if (labels?.wins === undefined || labels.losses === undefined) {
    throw new Error('StandingsTable: the compact layout needs wins and losses labels')
  }
  return (
    <>
      <div className={`${COMPACT_GRID} text-[10px] text-fg-dim mb-1 px-1 gap-x-2`}>
        <span>#</span>
        <span></span>
        <span className="text-center">{labels.wins}</span>
        <span className="text-center">{labels.losses}</span>
        <span className="text-center">+/-</span>
        <span></span>
      </div>
      {rows.map((row, index) => {
        const diff = row.diff ?? 0
        return (
          <div
            key={row.key}
            className={`${COMPACT_GRID} items-center py-1 px-1 rounded gap-x-2 text-xs ${row.highlighted === true ? 'bg-accent/5' : ''}`}
          >
            <span className={`font-bold font-mono ${row.highlighted === true ? 'text-accent' : 'text-fg-dim'}`}>
              {index + 1}
            </span>
            <span className={`truncate font-medium ${row.highlighted === true ? 'text-fg' : 'text-fg-dim'}`}>
              {row.name}
            </span>
            <span className={`text-center font-mono ${row.highlighted === true ? 'text-fg' : 'text-fg-dim'}`}>
              {row.wins ?? 0}
            </span>
            <span className={`text-center font-mono ${row.highlighted === true ? 'text-fg' : 'text-fg-dim'}`}>
              {row.losses ?? 0}
            </span>
            <span
              className={`text-center font-mono font-medium ${diff > 0 ? 'text-success' : diff < 0 ? 'text-error' : 'text-fg-dim'}`}
            >
              {diff > 0 ? `+${diff}` : diff === 0 ? '—' : diff}
            </span>
            <span className={`w-1.5 h-1.5 rounded-full mx-auto ${row.highlighted === true ? 'bg-accent' : ''}`} />
          </div>
        )
      })}
    </>
  )
}

/** Team tournament: points, win record and for/against, with a member line below. */
function Team({ rows, labels }: { rows: readonly StandingsRow[]; labels?: StandingsLabels }) {
  if (labels?.pointsSuffix === undefined) {
    throw new Error('StandingsTable: the team layout needs a pointsSuffix label')
  }
  return (
    <>
      {rows.map((row, index) => (
        <div
          key={row.key}
          className={`border-b border-border-subtle last:border-0 ${row.highlighted === true ? 'bg-accent/5' : ''}`}
        >
          <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5 px-4 py-2.5">
            <span
              className={`w-5 text-sm font-sans shrink-0 ${index === 0 ? 'text-accent' : index === 1 ? 'text-fg' : 'text-fg-dim'}`}
            >
              {row.rank ?? index + 1}
            </span>
            <span className="flex-1 text-sm text-fg truncate">{row.name}</span>
            <div className="flex items-center gap-1.5 shrink-0">
              <span className="bg-elevated px-2 py-0.5 rounded text-xs font-mono font-bold text-accent">
                {row.points ?? row.pointsFor ?? 0}{labels.pointsSuffix}
              </span>
              <span className="bg-elevated px-2 py-0.5 rounded text-xs font-mono text-fg font-medium">
                {row.wins ?? 0}-{row.losses ?? 0}
              </span>
              <span className="bg-elevated px-2 py-0.5 rounded text-xs font-mono text-fg-dim">
                {row.pointsFor ?? 0}-{row.pointsAgainst ?? 0}
              </span>
            </div>
          </div>
          {row.details !== undefined && (
            <div className="px-4 pb-2.5 pt-0 flex flex-wrap gap-x-3 gap-y-0.5">{row.details}</div>
          )}
        </div>
      ))}
    </>
  )
}

/** Classic tournament: the stage line sits under the name, the record in a pill. */
function Record({ rows, labels }: { rows: readonly StandingsRow[]; labels?: StandingsLabels }) {
  if (labels?.wins === undefined || labels.losses === undefined) {
    throw new Error('StandingsTable: the record layout needs wins and losses labels')
  }
  return (
    <>
      {rows.map((row, index) => (
        <li
          key={row.key}
          className="flex items-center gap-3 px-4 py-3 border-b border-border-subtle last:border-0 hover:bg-elevated/40 transition-colors"
        >
          <span
            className={`font-mono font-bold w-5 text-sm shrink-0 ${index === 0 ? 'text-accent' : index === 1 ? 'text-slate-200' : index === 2 ? 'text-[#e0985c]' : 'text-fg-dim'}`}
          >
            {row.rank ?? index + 1}
          </span>
          <div className="flex-1 min-w-0">
            <div className="text-sm text-fg font-medium truncate">{row.name}</div>
            <div className="text-[10px] text-fg-dim mt-0.5">{row.sublabel}</div>
          </div>
          <div className="text-right shrink-0">
            <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-lg bg-elevated border border-border-subtle font-mono text-[11px]">
              <span className="text-success font-semibold">{row.wins ?? 0}{labels.wins}</span>
              <span className="text-border">·</span>
              <span className="text-error font-semibold">{row.losses ?? 0}{labels.losses}</span>
            </span>
          </div>
        </li>
      ))}
    </>
  )
}

/** Rankings: a drill-in row with a movement arrow, a tier badge and points. */
function Rank({ rows }: { rows: readonly StandingsRow[] }) {
  return (
    <>
      {rows.map((row) => (
        <li key={row.key}>
          <button
            onClick={row.onSelect}
            className={`hit44 w-full flex items-center gap-2.5 px-3.5 py-2.5 text-left hover:bg-elevated transition-colors ${row.highlighted === true ? 'bg-accent/[0.04]' : ''}`}
          >
            {/* Rank number, plus the global rank while a tier filter is on. */}
            <div className="w-9 shrink-0 flex flex-col items-start justify-center">
              <span
                className={`font-mono text-sm leading-none tabular-nums ${row.highlighted === true ? 'text-accent font-bold' : 'text-fg-dim'}`}
              >
                #{row.rank}
              </span>
              {row.rankDetail !== undefined && (
                <span className="text-[11px] font-mono text-fg-dim leading-tight mt-0.5 tabular-nums">
                  #{row.rankDetail}
                </span>
              )}
            </div>
            {row.delta !== undefined && (
              <span className="w-3 shrink-0 font-mono text-[10px] leading-none text-center tabular-nums">
                {row.delta}
              </span>
            )}
            <div className="flex-1 min-w-0 flex items-center gap-2">
              <span className="text-sm font-medium text-fg truncate">{row.name}</span>
              {row.nameExtra}
            </div>
            <div className="shrink-0 flex items-center">
              <span className="font-mono text-sm font-bold text-fg leading-none tabular-nums">
                {(row.pointsFor ?? 0).toLocaleString('en-US')}
              </span>
            </div>
          </button>
        </li>
      ))}
    </>
  )
}

export type StandingsTableProps = {
  rows: readonly StandingsRow[]
  /** Defaults to the five-column session ledger. */
  layout?: StandingsLayout
  /** The ledger prints a header row from these; the other layouts print their own. */
  labels?: StandingsLabels
}

export function StandingsTable({ rows, labels, layout = 'ledger' }: StandingsTableProps) {
  switch (layout) {
    case 'compact':
      return <Compact rows={rows} labels={labels} />
    case 'team':
      return <Team rows={rows} labels={labels} />
    case 'record':
      return <Record rows={rows} labels={labels} />
    case 'rank':
      return <Rank rows={rows} />
    default:
      return <Ledger rows={rows} labels={labels} />
  }
}
