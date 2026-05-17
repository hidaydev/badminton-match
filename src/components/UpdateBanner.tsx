interface Props {
  onReload(): void
}

export default function UpdateBanner({ onReload }: Props) {
  return (
    <div className="fixed top-0 left-0 right-0 z-50 flex items-center justify-between gap-3 px-4 py-2.5 bg-amber-400 text-slate-950">
      <span className="text-sm font-medium">New version available</span>
      <button
        onClick={onReload}
        className="text-sm font-bold underline underline-offset-2 shrink-0"
      >
        Reload
      </button>
    </div>
  )
}
