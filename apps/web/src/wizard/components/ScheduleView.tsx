import { t } from '../../i18n'
import { courtLabel, minutesToTime, timeToMinutes } from '../time'
import type { Player, ScheduleSlot, SessionConfig } from '../types'

export default function ScheduleView({
  schedule,
  players,
  session,
}: {
  schedule: ScheduleSlot[]
  players: Player[]
  session: SessionConfig
}) {
  if (schedule.length === 0) {
    return <p className="text-sm text-slate-400">{t('wizard.generate.noGames')}</p>
  }

  const nameOf = (id: string) => players.find((player) => player.id === id)?.name ?? '?'
  const rounds = [...new Set(schedule.map((slot) => slot.slot))].sort((a, b) => a - b)
  const startMinutes = timeToMinutes(session.sessionStart)

  return (
    <div className="flex flex-col gap-4">
      {rounds.map((round) => {
        const games = schedule.filter((slot) => slot.slot === round).sort((a, b) => a.court - b.court)
        return (
          <section key={round} className="flex flex-col gap-2">
            <div className="flex items-baseline gap-2">
              <h3 className="text-sm font-semibold text-fg">{t('wizard.generate.round', { round: round + 1 })}</h3>
              <span className="text-xs font-mono text-fg-dim">
                {minutesToTime(startMinutes + round * session.slotMinutes)}
              </span>
            </div>
            <div className="grid gap-2 sm:grid-cols-2">
              {games.map((game) => (
                <article
                  key={`${game.slot}-${game.court}`}
                  className="rounded-xl border border-border-subtle bg-surface p-3"
                >
                  <p className="text-[10px] font-mono uppercase tracking-wider text-fg-dim">
                    {t('wizard.generate.court', { court: courtLabel(session.courtNames, game.court) })}
                  </p>
                  <div className="mt-2 flex items-center gap-2">
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-semibold text-fg truncate">
                        {game.teamA.map(nameOf).join(' & ')}
                      </p>
                      <p className="text-sm font-semibold text-fg truncate">
                        {game.teamB.map(nameOf).join(' & ')}
                      </p>
                    </div>
                    <span className="text-[10px] font-mono text-fg-dim shrink-0">{t('wizard.constraints.vs')}</span>
                  </div>
                </article>
              ))}
            </div>
          </section>
        )
      })}
    </div>
  )
}
