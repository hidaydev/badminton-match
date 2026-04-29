import { useState } from 'react'
import { useStore } from '../store'
import { publishSession, type CloudSnapshot } from '../utils/cloudSync'

function nanoid6(): string {
  return Math.random().toString(36).slice(2, 8)
}

export default function ShareButton() {
  const session = useStore((s) => s.session)
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const schedule = useStore((s) => s.schedule)
  const playedGames = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const cloudSessionId = useStore((s) => s.cloudSessionId)
  const setCloudSessionId = useStore((s) => s.setCloudSessionId)

  const [state, setState] = useState<'idle' | 'loading' | 'done' | 'error'>(cloudSessionId ? 'done' : 'idle')
  const [shareUrl, setShareUrl] = useState<string | null>(cloudSessionId ? `${window.location.origin}/s/${cloudSessionId}` : null)
  const [copied, setCopied] = useState(false)

  async function handleShare() {
    setState('loading')
    const id = cloudSessionId ?? nanoid6()
    const snapshot: CloudSnapshot = { session, players, fixMatches, schedule, playedGames, gameScores }
    try {
      await publishSession(id, snapshot)
      setCloudSessionId(id)
      const url = `${window.location.origin}/s/${id}`
      setShareUrl(url)
      setState('done')
    } catch {
      setState('error')
    }
  }

  async function handleCopy() {
    if (!shareUrl) return
    await navigator.clipboard.writeText(shareUrl)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (state === 'done' && shareUrl) {
    return (
      <div className="flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-800 border border-slate-700">
        <span className="text-xs text-slate-400 truncate max-w-[200px]">{shareUrl}</span>
        <button
          onClick={handleCopy}
          className={`text-xs font-semibold shrink-0 transition-colors ${copied ? 'text-emerald-400' : 'text-indigo-400 hover:text-white'}`}
        >
          {copied ? '✓ Copied!' : 'Copy'}
        </button>
        <button
          onClick={() => { setState('idle'); setShareUrl(null) }}
          className="text-slate-600 hover:text-slate-400 text-xs shrink-0"
        >
          ✕
        </button>
      </div>
    )
  }

  return (
    <button
      onClick={handleShare}
      disabled={state === 'loading'}
      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-indigo-900/50 hover:bg-indigo-800 border border-indigo-700 text-indigo-300 hover:text-white transition-colors disabled:opacity-50"
    >
      {state === 'loading' ? (
        'Publishing…'
      ) : state === 'error' ? (
        '✕ Failed — retry?'
      ) : cloudSessionId ? (
        '↑ Re-publish'
      ) : (
        <>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>
            <line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/>
          </svg>
          Share
        </>
      )}
    </button>
  )
}
