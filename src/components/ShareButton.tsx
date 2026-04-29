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

  const [confirming, setConfirming] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [shareUrl, setShareUrl] = useState<string | null>(cloudSessionId ? `${window.location.origin}/s/${cloudSessionId}` : null)
  const [error, setError] = useState(false)
  const [copied, setCopied] = useState(false)

  async function handleConfirm() {
    setConfirming(false)
    setPublishing(true)
    setError(false)
    const id = cloudSessionId ?? nanoid6()
    const snapshot: CloudSnapshot = { session, players, fixMatches, schedule, playedGames, gameScores }
    try {
      await publishSession(id, snapshot)
      setCloudSessionId(id)
      setShareUrl(`${window.location.origin}/s/${id}`)
    } catch {
      setError(true)
    } finally {
      setPublishing(false)
    }
  }

  async function handleCopy() {
    if (!shareUrl) return
    await navigator.clipboard.writeText(shareUrl)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <>
      {/* Confirmation modal */}
      {confirming && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4">
          <div className="bg-slate-900 border border-slate-700 rounded-2xl p-6 max-w-sm w-full flex flex-col gap-4 shadow-2xl">
            <div className="flex flex-col gap-1">
              <h2 className="text-white font-bold text-lg">Publish this session?</h2>
              <p className="text-slate-400 text-sm">Once published, the match schedule will be <span className="text-white font-medium">locked</span> — you won't be able to regenerate it.</p>
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
                onClick={handleConfirm}
                className="flex-1 py-2 rounded-xl text-sm font-bold bg-indigo-600 hover:bg-indigo-500 text-white transition-colors"
              >
                Publish & Share
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Inline share URL (after publish) */}
      {shareUrl ? (
        <div className="flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-800 border border-slate-700">
          <span className="text-xs text-slate-400 truncate max-w-[200px]">{shareUrl}</span>
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
          {publishing ? 'Publishing…' : error ? '✕ Failed — retry?' : (
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
    </>
  )
}
