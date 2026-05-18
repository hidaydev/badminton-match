import { useNavigate } from 'react-router-dom'

export default function VideoPostPage() {
  const navigate = useNavigate()
  return (
    <div className="flex flex-col">
      <div className="flex items-center gap-3 px-1 pt-4 pb-3">
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 flex items-center justify-center rounded-full bg-slate-800 text-slate-300 active:bg-slate-700 transition-colors"
        >
          ←
        </button>
        <div>
          <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Create</p>
          <h2 className="text-lg font-bold text-yellow-400 tracking-tight leading-none">Video Post</h2>
        </div>
      </div>
      <p className="text-slate-500 text-sm px-1">Coming soon…</p>
    </div>
  )
}
