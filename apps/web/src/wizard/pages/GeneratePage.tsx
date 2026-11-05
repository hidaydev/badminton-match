import { useState } from 'react'
import { Link, Navigate, useNavigate, useParams } from 'react-router-dom'
import { t } from '../../i18n'
import ScheduleView from '../components/ScheduleView'
import { generate } from '../generator'
import type { GenerateContext } from '../generator'
import { PublishError, publishDraft } from '../publish'
import { useWizard } from '../context'
import { timeToMinutes, timeToSlotIndex } from '../time'
import type { MatchConstraint } from '../types'

export default function GeneratePage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const navigate = useNavigate()
  const { draft, slotsPerCourt, setResult, setServerSession } = useWizard()
  const [error, setError] = useState<string | null>(null)
  const [publishError, setPublishError] = useState<string | null>(null)
  const [publishing, setPublishing] = useState(false)

  if (!draft.session.locked) {
    return <Navigate to={`/c/${encodeURIComponent(slug)}/session/new`} replace />
  }
  if (draft.players.length !== draft.session.playerCount) {
    return <Navigate to={`/c/${encodeURIComponent(slug)}/session/players`} replace />
  }

  const base = `/c/${encodeURIComponent(slug)}`
  const result = draft.lastResult
  const playerMap = new Map(draft.players.map((player) => [player.id, player]))
  const nameOf = (id: string) => playerMap.get(id)?.name ?? '?'
  const describeFix = (match: MatchConstraint) => {
    const [A1, A2, B1, B2] = match.slots
    const side = (ids: string[]) => ids.filter(Boolean).map(nameOf).join(' + ') || t('wizard.generate.anyone')
    if ((A1 || A2) && (B1 || B2)) {
      return `${side([A1, A2])} ${t('wizard.constraints.vs')} ${side([B1, B2])}`
    }
    return t('wizard.generate.unplacedPaired', { names: side([A1, A2, B1, B2].filter(Boolean)) })
  }

  function handleGenerate() {
    setError(null)
    if (draft.players.length < 4) {
      setError(t('wizard.generate.needPlayers'))
      return
    }
    if (draft.players.length < slotsPerCourt.length * 4) {
      setError(t('wizard.generate.needCourts', { n: slotsPerCourt.length * 4, courts: slotsPerCourt.length }))
      return
    }
    const offsets = draft.session.courtTimes.map((ct) =>
      Math.floor((timeToMinutes(ct.start) - timeToMinutes(draft.session.sessionStart)) / draft.session.slotMinutes),
    )
    const context: GenerateContext = {
      players: draft.players,
      slotsPerCourt,
      fixMatches: draft.fixMatches,
      courtOffsets: offsets,
      timeToSlotIndex: (time) => timeToSlotIndex(draft.session, time),
    }
    try {
      setResult(generate(context))
    } catch {
      setError(t('wizard.generate.error'))
    }
  }

  async function handlePublish() {
    setPublishError(null)
    setPublishing(true)
    try {
      const { sessionId } = await publishDraft(slug, draft)
      setServerSession(sessionId)
      navigate(`${base}/sessions/${encodeURIComponent(sessionId)}`)
    } catch (problem) {
      setPublishError(problem instanceof PublishError ? problem.message : t('wizard.generate.publishError'))
    } finally {
      setPublishing(false)
    }
  }

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h2 className="text-lg font-bold text-fg mb-0.5">{t('wizard.generate.title')}</h2>
        <p className="text-slate-400 text-xs sm:text-sm">
          {draft.session.courts === 1
            ? t('wizard.generate.subtitleOne', {
                players: draft.players.length,
                games: slotsPerCourt.reduce((a, b) => a + b, 0),
              })
            : t('wizard.generate.subtitle', {
                players: draft.players.length,
                games: slotsPerCourt.reduce((a, b) => a + b, 0),
                courts: draft.session.courts,
              })}
        </p>
      </div>

      {error !== null && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm" role="alert">
          {error}
        </div>
      )}
      {publishError !== null && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm" role="alert">
          {publishError}
        </div>
      )}

      {result && result.unplacedFixMatches.length > 0 && (
        <div className="p-3 bg-amber-900/30 border border-amber-700 rounded-xl text-amber-400 text-sm flex flex-col gap-1.5">
          <span className="font-medium">
            {result.unplacedFixMatches.length === 1
              ? t('wizard.generate.unplacedOne')
              : t('wizard.generate.unplaced', { count: result.unplacedFixMatches.length })}
          </span>
          {result.unplacedFixMatches.map((id) => {
            const match = draft.fixMatches.find((candidate) => candidate.id === id)
            if (!match) return null
            return (
              <span key={id} className="text-xs text-amber-300 pl-3">
                · {describeFix(match)}
              </span>
            )
          })}
        </div>
      )}

      {result ? (
        <ScheduleView schedule={result.schedule} players={draft.players} session={draft.session} />
      ) : (
        <button
          type="button"
          onClick={handleGenerate}
          disabled={draft.players.length < 4}
          className="w-full py-2.5 bg-accent hover:brightness-110 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-bold text-sm rounded-lg transition-colors"
        >
          {t('wizard.generate.generate')}
        </button>
      )}

      {result && (
        <div className="flex flex-col gap-2">
          <button
            type="button"
            onClick={handleGenerate}
            className="w-full py-2.5 border border-emerald-800 bg-emerald-900/30 hover:bg-emerald-900/50 text-emerald-300 text-sm font-medium rounded-lg transition-colors"
          >
            {t('wizard.generate.regenerate')}
          </button>
          <button
            type="button"
            onClick={() => void handlePublish()}
            disabled={publishing}
            className="w-full py-2.5 bg-accent hover:brightness-110 disabled:opacity-50 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors"
          >
            {publishing ? t('wizard.generate.publishing') : t('wizard.generate.publish')}
          </button>
          <p className="text-xs text-slate-400 text-center">{t('wizard.generate.publishHint')}</p>
          {draft.serverSessionId !== null && (
            <Link
              to={`${base}/sessions/${encodeURIComponent(draft.serverSessionId)}`}
              className="text-xs text-accent hover:brightness-125 underline underline-offset-2 text-center"
            >
              {t('wizard.generate.play')}
            </Link>
          )}
        </div>
      )}
    </div>
  )
}
