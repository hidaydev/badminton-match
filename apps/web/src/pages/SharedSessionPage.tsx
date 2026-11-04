import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { t } from '../i18n'
import { getSharedSession } from '../share/api'
import type { SharedSession } from '../share/api'

type Settled = {
  code: string
  value: SharedSession | null
  error: 'notFound' | 'failed' | null
}

/**
 * The spectator screen. It renders outside the auth gate, so it must not assume
 * a user, a community or a board: everything it shows comes from the code.
 */
export default function SharedSessionPage() {
  const { code = '' } = useParams<{ code: string }>()
  const [settled, setSettled] = useState<Settled | null>(null)

  useEffect(() => {
    if (code === '') return
    let active = true
    getSharedSession(code)
      .then((value) => {
        if (active) setSettled({ code, value, error: null })
      })
      .catch((problem: unknown) => {
        if (!active) return
        const missing = problem instanceof ApiError && problem.status === 404
        setSettled({ code, value: null, error: missing ? 'notFound' : 'failed' })
      })
    return () => {
      active = false
    }
  }, [code])

  const current = settled !== null && settled.code === code ? settled : null
  const loading = code !== '' && current === null
  const session = current?.value ?? null

  return (
    <section className="mx-auto max-w-3xl p-4">
      <header className="flex items-baseline justify-between gap-3">
        <p className="text-sm font-semibold text-accent">{t('shared.title')}</p>
        {session !== null && (
          <p className="text-xs text-fg-dim">{session.community.name}</p>
        )}
      </header>

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}
      {current?.error === 'notFound' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('shared.error.missing')}
        </p>
      )}
      {current?.error === 'failed' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('shared.error.load')}
        </p>
      )}

      {session !== null && (
        <>
          <h1 className="mt-2 text-xl font-bold text-fg sm:text-2xl">
            {session.session.title}
          </h1>
          <p className="mt-1 font-mono text-xs text-fg-dim">
            {session.session.date} · {session.session.status}
          </p>

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
                      key={game.id}
                      className="border-b border-border-subtle last:border-b-0"
                    >
                      <td className="px-3 py-2 font-mono text-fg-dim">
                        {game.round + 1}.{game.court + 1}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideA.length === 0
                          ? t('session.side.empty')
                          : game.sideA.join(' & ')}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideB.length === 0
                          ? t('session.side.empty')
                          : game.sideB.join(' & ')}
                      </td>
                      <td className="px-3 py-2 text-right font-mono text-fg">
                        {game.scoreA === null || game.scoreB === null
                          ? '–'
                          : `${game.scoreA}–${game.scoreB}`}
                      </td>
                      <td className="px-3 py-2 text-right text-xs text-fg-dim">
                        {game.status}
                      </td>
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
