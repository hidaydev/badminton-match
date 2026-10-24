// src/pages/NewTournamentPage.tsx: choose tournament format.
import { useNavigate } from 'react-router-dom'
import Icon from '../components/Icon'

export default function NewTournamentPage() {
  const navigate = useNavigate()

  const options = [
    {
      format: 'classic' as const,
      title: 'Classic Tournament',
      tag: 'Individual Pairs',
      desc: '16 pairs · 4 groups round robin · knockout bracket to finals',
      icon: 'tournament' as const,
      tone: 'sky',
      to: '/tournaments/new/classic',
    },
    {
      format: 'team' as const,
      title: 'Team Cup',
      tag: 'Team Format',
      desc: '6 teams × 6 players · 3 doubles matches per tie · rally 30/42',
      icon: 'players' as const,
      tone: 'accent',
      to: '/tournaments/new/team',
    },
  ]

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h2 className="text-lg font-bold text-fg">New Tournament</h2>
        <p className="text-xs text-fg-dim">Select the tournament format you want to run</p>
      </div>

      <div className="flex flex-col gap-3">
        {options.map((o) => {
          const isAccent = o.tone === 'accent'
          return (
            <button
              key={o.format}
              onClick={() => navigate(o.to)}
              className="w-full flex items-center gap-3.5 p-4 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.99] transition-all text-left shadow-sm group"
            >
              <div
                className={`w-12 h-12 rounded-xl flex items-center justify-center shrink-0 border ${
                  isAccent
                    ? 'bg-accent/15 border-accent/30 text-accent'
                    : 'bg-sky-500/15 border-sky-500/30 text-sky-400'
                }`}
              >
                <Icon name={o.icon} size={22} />
              </div>

              <div className="flex flex-col gap-1 flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-base font-bold text-fg leading-tight">
                    {o.title}
                  </span>
                  <span
                    className={`text-[10px] font-mono font-semibold px-1.5 py-0.5 rounded border leading-none ${
                      isAccent
                        ? 'text-accent bg-accent/10 border-accent/25'
                        : 'text-sky-400 bg-sky-500/10 border-sky-500/25'
                    }`}
                  >
                    {o.tag}
                  </span>
                </div>
                <span className="text-xs text-fg-dim leading-snug">{o.desc}</span>
              </div>

              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="18"
                height="18"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="text-fg-dim/40 group-hover:text-fg transition-colors shrink-0"
              >
                <path d="M9 18l6-6-6-6" />
              </svg>
            </button>
          )
        })}
      </div>
    </div>
  )
}
