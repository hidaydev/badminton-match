import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ApiError } from '../../auth/api'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n/en'
import { createTournament } from '../api'
import type { TeamInfo, TeamSnapshot } from '../types'
import {
  GROUP_DRAW_SLOTS,
  TEAM_CLASSES,
  TEAM_NAMES,
  drawGroupMatches,
  targetScore,
} from './rules'

const inputClass =
  'mt-1 block w-full min-h-11 rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent'

/** Local calendar day for the date input; toISOString would use UTC. */
function today(): string {
  const now = new Date()
  return [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
  ].join('-')
}

/** Same normalisation the domain uses for player-name uniqueness. */
function nameKey(value: string): string {
  return value.trim().replace(/\s+/g, ' ').toLowerCase()
}

type Props = {
  slug: string
}

/** New team tournament: name, date and one typed player per class per team.
 * Saving creates the six teams and the fixed nine-match group draw. */
export default function TeamNewForm({ slug }: Props) {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [date, setDate] = useState(today)
  const [rosters, setRosters] = useState<string[][]>(() =>
    TEAM_NAMES.map(() => TEAM_CLASSES.map(() => '')),
  )
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<MessageKey | null>(null)

  const updatePlayer = (teamIndex: number, classIndex: number, value: string) => {
    setRosters((previous) =>
      previous.map((team, currentTeam) =>
        currentTeam === teamIndex
          ? team.map((player, currentClass) =>
              currentClass === classIndex ? value : player,
            )
          : team,
      ),
    )
  }

  const valid = (): boolean => {
    if (name.trim() === '' || date.trim() === '') return false
    const seen = new Set<string>()
    for (const team of rosters) {
      for (const player of team) {
        const key = nameKey(player)
        if (key === '' || seen.has(key)) return false
        seen.add(key)
      }
    }
    return true
  }

  const create = async () => {
    if (!valid()) {
      setError('team.error.invalid')
      return
    }
    const teams: TeamInfo[] = TEAM_NAMES.map((teamName, teamIndex) => ({
      id: `t${teamIndex + 1}`,
      name: teamName,
      players: TEAM_CLASSES.map((cls, classIndex) => ({
        name: rosters[teamIndex][classIndex].trim(),
        cls,
      })),
    }))
    const snapshot: TeamSnapshot = {
      format: 'team',
      name: name.trim(),
      date: date.trim(),
      teams,
      matches: drawGroupMatches(teams.map((team) => team.id)),
    }

    setError(null)
    setCreating(true)
    try {
      const created = await createTournament(slug, snapshot)
      if (created.id === undefined) {
        setError('tournament.error.invalid')
        return
      }
      navigate(
        `/c/${encodeURIComponent(slug)}/tournaments/team/${encodeURIComponent(created.id)}`,
      )
    } catch (failure) {
      setError(
        failure instanceof ApiError && failure.status === 400
          ? 'team.error.invalid'
          : 'tournament.error.invalid',
      )
    } finally {
      setCreating(false)
    }
  }

  return (
    <form
      className="mt-4 space-y-4"
      onSubmit={(event) => {
        event.preventDefault()
        void create()
      }}
    >
      <div className="grid gap-3 sm:grid-cols-2">
        <div>
          <label htmlFor="team-tournament-name" className="text-xs text-fg-dim">
            {t('tournament.name')}
          </label>
          <input
            id="team-tournament-name"
            value={name}
            required
            autoComplete="off"
            onChange={(event) => setName(event.target.value)}
            className={inputClass}
          />
        </div>
        <div>
          <label htmlFor="team-tournament-date" className="text-xs text-fg-dim">
            {t('tournament.date')}
          </label>
          <input
            id="team-tournament-date"
            type="date"
            value={date}
            required
            onChange={(event) => setDate(event.target.value)}
            className={inputClass}
          />
        </div>
      </div>

      <h2 className="text-sm font-semibold text-fg">{t('team.teams')}</h2>
      <p className="text-sm text-fg-dim">{t('team.roster')}</p>

      <div className="grid gap-3 sm:grid-cols-2">
        {TEAM_NAMES.map((teamName, teamIndex) => (
          <fieldset
            key={teamName}
            className="rounded-2xl border border-border-subtle bg-surface p-4"
          >
            <legend className="px-1 text-sm font-semibold text-fg">{teamName}</legend>
            <div className="mt-2 space-y-2">
              {TEAM_CLASSES.map((cls, classIndex) => {
                const id = `team-${teamIndex}-class-${classIndex}`
                return (
                  <div key={cls}>
                    <label htmlFor={id} className="text-xs text-fg-dim">
                      {t('team.player')} · {cls}
                    </label>
                    <input
                      id={id}
                      value={rosters[teamIndex][classIndex]}
                      autoComplete="off"
                      onChange={(event) =>
                        updatePlayer(teamIndex, classIndex, event.target.value)
                      }
                      className={inputClass}
                    />
                  </div>
                )
              })}
            </div>
          </fieldset>
        ))}
      </div>

      <h2 className="text-sm font-semibold text-fg">{t('team.schedule')}</h2>
      <ul className="space-y-1 text-sm text-fg-dim">
        {GROUP_DRAW_SLOTS.map((slot, index) => (
          <li key={index}>
            {`${TEAM_NAMES[slot.teamA]} — ${TEAM_NAMES[slot.teamB]}`} · {slot.court} ·{' '}
            {t('team.target', { score: targetScore('group') })}
          </li>
        ))}
      </ul>

      {error !== null && (
        <p role="alert" aria-live="polite" className="text-sm text-error">
          {t(error)}
        </p>
      )}
      {creating && (
        <p role="status" className="text-sm text-fg-dim">
          {t('tournament.creating')}
        </p>
      )}

      <button
        type="submit"
        disabled={creating}
        className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground disabled:opacity-40 focus-visible:ring-2 focus-visible:ring-accent"
      >
        {creating ? t('tournament.creating') : t('tournament.save')}
      </button>
    </form>
  )
}
