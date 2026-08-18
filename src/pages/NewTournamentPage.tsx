import { useNavigate } from 'react-router-dom'

/** Pemilih format tournament baru → arahkan ke wizard masing-masing. */
export default function NewTournamentPage() {
  const navigate = useNavigate()

  const options = [
    {
      format: 'classic' as const,
      title: 'Classic',
      desc: '16 pairs · 4 groups · knockout bracket',
      to: '/tournaments/new/classic',
    },
    {
      format: 'team' as const,
      title: 'Team',
      desc: '6 teams × 6 players · 3 doubles matches · rally 30/42',
      to: '/tournaments/new/team',
    },
  ]

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h2 className="text-lg font-bold text-fg">New Tournament</h2>
        <p className="text-xs text-fg-dim">Choose tournament format</p>
      </div>

      <div className="flex flex-col gap-2.5">
        {options.map((o) => (
          <button
            key={o.format}
            onClick={() => navigate(o.to)}
            className="flex items-center justify-between gap-3 p-4 rounded-lg bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
          >
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-semibold text-fg">{o.title}</span>
              <span className="text-xs text-fg-dim">{o.desc}</span>
            </div>
            <span className="text-fg-dim text-lg">›</span>
          </button>
        ))}
      </div>
    </div>
  )
}
