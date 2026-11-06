import { useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useStore } from '../store'
import { useEscapeKey } from '../hooks/useEscapeKey'
import { useFocusTrap } from '../hooks/useFocusTrap'
import { communityQueryKey } from '../queries/keys'
import {
  activeCommunitySlug,
  createSession,
  ensureSessionShareLink,
  getSession,
  getSessionShareCode,
  publishSession,
  listPlayers,
  registerPlayer,
} from '../queries/endpoints'
import type { CloudSnapshot, PlayerSummary } from '../queries'
import { getSaveErrorMessage } from '../queries/errors'
import { buildPublishableSessionSnapshot } from '../utils/sessionSnapshot'
import { communityHref } from '../../routes.manifest'
import { t } from '../../i18n'
import ResolvePlayersModal from './ResolvePlayersModal'
import { findUnresolvedPlayers } from '../utils/resolvePlayers'

export default function ShareButton() {
  const session = useStore((s) => s.session)
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const schedule = useStore((s) => s.schedule)
  const playedGames = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const cloudSessionId = useStore((s) => s.cloudSessionId)
  const setCloudSessionId = useStore((s) => s.setCloudSessionId)
  const setCloudVersion = useStore((s) => s.setCloudVersion)
  const updatePlayer = useStore((s) => s.updatePlayer)

  const queryClient = useQueryClient()
  const [confirming, setConfirming] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [publishedId, setPublishedId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [resolveOpen, setResolveOpen] = useState(false)
  const [knownPlayers, setKnownPlayers] = useState<PlayerSummary[]>([])
  const confirmRef = useRef<HTMLDivElement>(null)

  useEscapeKey(() => setConfirming(false), confirming)
  useFocusTrap(confirmRef, confirming)

  // One cache entry for the live code, shared with the summary panel: rotating
  // or revoking there must not leave this pill handing out the old link.
  const shareKey = communityQueryKey('session-share', cloudSessionId ?? '')
  const { data: shareCode = null } = useQuery({
    queryKey: shareKey,
    queryFn: () => getSessionShareCode(cloudSessionId as string),
    enabled: cloudSessionId !== null && cloudSessionId !== undefined,
  })
  const shareUrl = shareCode === null ? null : `${window.location.origin}/s/${shareCode}`

  // A session published earlier already has a live link; show it again. The
  // cached code is the signal, so this is derived instead of synced in an
  // effect. `publishedId` still covers the flow that just published: the way
  // back must not depend on the share link call succeeding.
  const publishedSessionId =
    publishedId ?? (shareCode !== null ? cloudSessionId ?? null : null)

  async function handleConfirm() {
    setConfirming(false)
    setPublishing(true)
    setError(null)
    try {
      let id = cloudSessionId
      if (!id) {
        const created = await createSession({
          title: session.title,
          date: session.date,
          startTime: session.sessionStart,
          slotMinutes: session.slotMinutes,
          ...(session.scoringPreset ? { scoringPreset: session.scoringPreset } : {}),
        })
        id = created.id
        setCloudSessionId(id)
      }
      const existingSnapshot = await getSession(id)
      const snapshot: CloudSnapshot = buildPublishableSessionSnapshot({
        version: existingSnapshot?.version,
        existingAbsentPlayers: existingSnapshot?.absentPlayers,
        session,
        players,
        fixMatches,
        schedule,
        playedGames,
        gameScores,
      })
      // Don't lock on publish — host needs to input scores after publishing
      snapshot.session = { ...snapshot.session, locked: false }
      const published = await publishSession(id, snapshot)
      setCloudVersion(published.version ?? null)
      // The session is live now, so the way back to it must not depend on the
      // share link succeeding.
      setPublishedId(id)
      const code = await ensureSessionShareLink(id)
      queryClient.setQueryData(communityQueryKey('session-share', id), code)
    } catch (err) {
      setError(getSaveErrorMessage(err))
    } finally {
      setPublishing(false)
    }
  }

  async function handleShareClick() {
    setConfirming(false)
    setError(null)
    setPublishing(true)
    try {
      const known = await listPlayers()
      setKnownPlayers(known)
      const unresolved = findUnresolvedPlayers(players, known)
      if (unresolved.length > 0) {
        setResolveOpen(true)
        setPublishing(false)
        return
      }
      await handleConfirm()
    } catch (err) {
      setError(getSaveErrorMessage(err))
      setPublishing(false)
    }
  }

  async function handleResolve(result: {
    registerNew: { name: string }[]
    registerAlias: { alias: string; canonical: string }[]
    renameMap: Map<string, string>
  }) {
    setResolveOpen(false)
    setPublishing(true)
    setError(null)
    try {
      for (const { name } of result.registerNew) {
        await registerPlayer(name)
      }
      for (const { alias, canonical } of result.registerAlias) {
        await registerPlayer(alias, canonical)
      }
      for (const [playerId, newName] of result.renameMap) {
        updatePlayer(playerId, { name: newName })
      }
      await handleConfirm()
    } catch (err) {
      setError(getSaveErrorMessage(err))
    } finally {
      setPublishing(false)
    }
  }

  async function handleCopy() {
    if (!shareUrl) return
    try {
      await navigator.clipboard.writeText(shareUrl)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch (err) {
      console.error('Clipboard write failed', err)
      setError('Failed to copy link. Please copy it manually.')
    }
  }

  // Native share sheet (WhatsApp, Messages, …) where the browser offers it.
  async function handleNativeShare() {
    if (!shareUrl) return
    try {
      await navigator.share({ title: session.title || 'Majadu session', url: shareUrl })
    } catch {
      // Dismissing the sheet is not an error.
    }
  }

  const canNativeShare = typeof navigator !== 'undefined' && typeof navigator.share === 'function'

  return (
    <>
      {error && (
        <div className="max-w-sm rounded-xl border border-red-700 bg-red-950/80 px-3 py-2 text-xs text-red-200">
          {error}
        </div>
      )}
      <ResolvePlayersModal
        open={resolveOpen}
        localPlayers={players}
        knownPlayers={knownPlayers}
        onResolve={handleResolve}
        onCancel={() => { setResolveOpen(false); setPublishing(false) }}
      />
      {/* Confirmation modal */}
      {confirming && (
        <div ref={confirmRef} tabIndex={-1} className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4" role="dialog" aria-modal="true" aria-label={t('session.publishConfirm')}>
          <div className="bg-slate-900 border border-slate-700 rounded-lg p-6 max-w-sm w-full flex flex-col gap-4 shadow-2xl">
            <div className="flex flex-col gap-1">
              <h2 className="text-white font-bold text-lg">Publish this session?</h2>
              <p className="text-slate-400 text-sm">Share this session with players. You can still input scores and manage the live session after publishing.</p>
            </div>
            <div className="flex flex-col gap-2 text-sm">
              <div className="flex items-center gap-2 text-slate-400">
                <span className="text-emerald-400">✓</span> Mark games as played
              </div>
              <div className="flex items-center gap-2 text-slate-400">
                <span className="text-emerald-400">✓</span> Enter and update scores
              </div>
              <div className="flex items-center gap-2 text-slate-400">
                <span className="text-red-400">✕</span> Regenerate the schedule
              </div>
            </div>
            <div className="flex gap-2 pt-1">
              <button
                onClick={() => setConfirming(false)}
                className="flex-1 py-2 rounded-xl text-sm font-medium bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleShareClick}
                className="flex-1 py-2 rounded-xl text-sm font-bold bg-indigo-400 hover:bg-indigo-300 text-slate-950 transition-colors"
              >
                Publish & Share
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Inline share URL (after publish) */}
      {shareUrl ? (
        <div className="flex items-center gap-2 px-3 py-2 rounded-xl bg-elevated border border-border">
          <span className="text-xs text-slate-400 truncate max-w-50">{shareUrl}</span>
          {canNativeShare && (
            <button
              onClick={handleNativeShare}
              className="text-xs font-semibold shrink-0 text-indigo-400 hover:text-white transition-colors"
            >
              Share…
            </button>
          )}
          <button
            onClick={handleCopy}
            className={`text-xs font-semibold shrink-0 transition-colors ${copied ? 'text-emerald-400' : 'text-indigo-400 hover:text-white'}`}
          >
            {copied ? '✓ Copied!' : 'Copy'}
          </button>
        </div>
      ) : (
        <button
          onClick={() => setConfirming(true)}
          disabled={publishing}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-indigo-900/50 hover:bg-indigo-800 border border-indigo-700 text-indigo-300 hover:text-white transition-colors disabled:opacity-50"
        >
          {publishing ? 'Publishing…' : error ? '✕ Save conflict — retry?' : (
            <>
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>
                <line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/>
              </svg>
              Share
            </>
          )}
        </button>
      )}
      {publishedSessionId && (
        <a
          href={communityHref(
            activeCommunitySlug(),
            `/s/${encodeURIComponent(publishedSessionId)}`,
          )}
          className="inline-flex items-center text-xs font-bold shrink-0 rounded-lg bg-emerald-400 hover:bg-emerald-300 px-2.5 py-1.5 text-slate-950 transition-colors"
        >
          {t('wizard.generate.play')}
        </a>
      )}
    </>
  )
}
