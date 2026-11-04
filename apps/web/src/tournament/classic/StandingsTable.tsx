import { t } from '../../i18n'
import type { ClassicMatch, GroupId } from '../types'
import { computeGroupStandings } from './draw'

type Props = {
  groupId: GroupId
  pairIds: readonly string[]
  matches: readonly ClassicMatch[]
  nameOf: (pairId: string | null) => string
}

/**
 * Standings in domain order: wins, point difference, points for, then the first
 * head-to-head meeting. `P` is played = wins + losses.
 */
export function StandingsTable({ groupId, pairIds, matches, nameOf }: Props) {
  const rows = computeGroupStandings(groupId, pairIds, matches)
  const caption = `${t('classic.standings')} · ${t('classic.group', { group: groupId })}`

  return (
    <div className="mt-2 overflow-x-auto rounded-xl border border-border-subtle bg-surface">
      <table className="w-full border-collapse text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr className="border-b border-border text-xs text-fg-dim">
            <th scope="col" className="px-2 py-2 text-left font-semibold">
              {t('classic.pair')}
            </th>
            <th scope="col" className="px-2 py-2 text-right font-semibold">
              {t('classic.column.played')}
            </th>
            <th scope="col" className="px-2 py-2 text-right font-semibold">
              {t('classic.column.wins')}
            </th>
            <th scope="col" className="px-2 py-2 text-right font-semibold">
              {t('classic.column.losses')}
            </th>
            <th scope="col" className="px-2 py-2 text-right font-semibold">
              {t('classic.column.diff')}
            </th>
            <th scope="col" className="px-2 py-2 text-right font-semibold">
              {t('classic.column.pointsFor')}
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.pairId} className="border-b border-border-subtle last:border-b-0">
              <th scope="row" className="px-2 py-2 text-left font-normal text-fg">
                {nameOf(row.pairId)}
              </th>
              <td className="px-2 py-2 text-right font-mono text-fg-dim">
                {row.wins + row.losses}
              </td>
              <td className="px-2 py-2 text-right font-mono text-fg">{row.wins}</td>
              <td className="px-2 py-2 text-right font-mono text-fg-dim">{row.losses}</td>
              <td className="px-2 py-2 text-right font-mono text-fg">
                {row.diff > 0 ? `+${row.diff}` : row.diff}
              </td>
              <td className="px-2 py-2 text-right font-mono text-fg-dim">
                {row.pointsFor}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
