import { Link, useParams } from 'react-router-dom'
import { t } from '../i18n'
import { useSession } from '../sessions/hooks'

/** One session: who plays, the games and the board, in one read. */
export default function SessionPage() {
  const { slug = '', id = '' } = useParams<{ slug: string; id: string }>()
  const { session, board, loading, error } = useSession(
    slug === '' ? null : slug,
    id === '' ? null : id,
  )
  const names = new Map(session?.participants.map((entry) => [entry.playerId, entry.name]) ?? [])
  const nameOf = (playerId: string) => names.get(playerId) ?? playerId

  return (
    <section className="mx-auto max-w-3xl p-4">
      <Link
        to={`/c/${encodeURIComponent(slug)}/sessions`}
        className="inline-flex min-h-11 items-center rounded-xl text-sm text-fg-dim hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('sessions.back')}
      </Link>

      {loading && (
        <p role="status" className="mt-2 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}
      {error === 'notFound' && (
        <p role="alert" className="mt-2 text-sm text-error">
          {t('session.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" className="mt-2 text-sm text-error">
          {t('session.error.load')}
        </p>
      )}

      {session !== null && (
        <>
          <header className="mt-2">
            <h1 className="text-xl font-bold text-fg sm:text-2xl">{session.title}</h1>
            <p className="mt-1 font-mono text-xs text-fg-dim">
              {t('session.meta', {
                date: session.date,
                startTime: session.startTime,
                slotMinutes: session.slotMinutes,
              })}
            </p>
            <p className="mt-1 font-mono text-[10px] text-fg-dim uppercase">
              {t('session.version', { status: session.status, version: session.version })}
            </p>
          </header>

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('session.participants')}</h2>
          {session.participants.length === 0 ? (
            <p className="mt-2 text-sm text-fg-dim">{t('session.participants.empty')}</p>
          ) : (
            <ul className="mt-2 flex flex-wrap gap-2">
              {session.participants.map((entry) => (
                <li
                  key={entry.playerId}
                  className="rounded-lg border border-border bg-elevated px-2 py-1 text-xs text-fg"
                >
                  {entry.name}
                  {entry.absent && (
                    <span className="ml-1 text-fg-dim">({t('session.absent')})</span>
                  )}
                </li>
              ))}
            </ul>
          )}

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('session.games')}</h2>
          {session.games.length === 0 ? (
            <p className="mt-2 text-sm text-fg-dim">{t('session.games.empty')}</p>
          ) : (
            <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">{t('session.games')}</caption>
                <thead>
                  <tr className="border-b border-border text-left text-xs text-fg-dim">
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.court')}
                    </th>
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.sideA')}
                    </th>
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.sideB')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.score')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.status')}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {session.games.map((game) => (
                    <tr
                      key={`${game.round}-${game.court}`}
                      className="border-b border-border-subtle last:border-b-0"
                    >
                      <td className="px-3 py-2 font-mono text-fg-dim">
                        {game.round + 1}.{game.court + 1}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideA.length === 0
                          ? t('session.side.empty')
                          : game.sideA.map(nameOf).join(' & ')}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideB.length === 0
                          ? t('session.side.empty')
                          : game.sideB.map(nameOf).join(' & ')}
                      </td>
                      <td className="px-3 py-2 text-right font-mono text-fg">
                        {game.scoreA === null || game.scoreB === null
                          ? '–'
                          : `${game.scoreA}–${game.scoreB}`}
                      </td>
                      <td className="px-3 py-2 text-right text-xs text-fg-dim">{game.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('session.standings')}</h2>
          {board === null || board.items.length === 0 ? (
            <p className="mt-2 text-sm text-fg-dim">{t('session.standings.empty')}</p>
          ) : (
            <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">{t('session.standings')}</caption>
                <thead>
                  <tr className="border-b border-border text-left text-xs text-fg-dim">
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.rank')}
                    </th>
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.player')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.wins')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.losses')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.diff')}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {board.items.map((row, index) => (
                    <tr
                      key={row.playerId}
                      className="border-b border-border-subtle last:border-b-0"
                    >
                      <td className="px-3 py-2 text-right font-mono text-fg-dim">{index + 1}</td>
                      <td className="px-3 py-2 text-fg">{row.name}</td>
                      <td className="px-3 py-2 text-right font-mono text-fg">{row.wins}</td>
                      <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.losses}</td>
                      <td className="px-3 py-2 text-right font-mono text-fg-dim">{row.diff}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </section>
  )
}
