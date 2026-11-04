import { t } from '../../i18n'
import type { TeamStanding } from './rules'

type Props = {
  standings: readonly TeamStanding[]
}

/** Group table ordered by points, partai balance, then point difference. */
export default function TeamStandings({ standings }: Props) {
  return (
    <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
      <table className="w-full border-collapse text-sm">
        <caption className="sr-only">{t('team.standings')}</caption>
        <thead>
          <tr className="border-b border-border text-left text-xs text-fg-dim">
            <th scope="col" className="px-3 py-2 font-semibold">
              {t('team.team')}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {t('team.column.played')}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {t('team.column.wins')}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {t('team.column.losses')}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {t('team.column.points')}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {t('team.column.diff')}
            </th>
          </tr>
        </thead>
        <tbody>
          {standings.map((row) => (
            <tr key={row.teamId} className="border-b border-border-subtle last:border-b-0">
              <th scope="row" className="px-3 py-2 text-left font-normal text-fg">
                {row.teamName}
              </th>
              <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.played}</td>
              <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.wins}</td>
              <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.losses}</td>
              <td className="px-3 py-2 text-right font-mono text-fg">{row.points}</td>
              <td className="px-3 py-2 text-right font-mono text-fg-dim">
                {row.pointsFor - row.pointsAgainst}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
