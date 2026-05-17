import { Link, Outlet, useLocation, useNavigate } from 'react-router-dom'

export default function HomeLayout() {
  const location = useLocation()
  const navigate = useNavigate()
  const isHome = location.pathname === '/'

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
          {!isHome && (
            <button
              onClick={() => navigate(-1)}
              className="p-1.5 rounded-lg text-slate-400 hover:text-white active:scale-90 transition-all shrink-0"
              aria-label="Back"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          )}
          <Link to="/" className="flex items-center gap-2 flex-1">
            <img src="/logo.png" alt="logo" className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-white tracking-tight">MAJADU APP</h1>
          </Link>
          <button
            onClick={() => window.location.reload()}
            className="p-1.5 rounded-lg text-slate-500 hover:text-slate-300 active:scale-90 transition-all"
            aria-label="Refresh"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
              <path d="M21 3v5h-5"/>
              <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
              <path d="M8 16H3v5"/>
            </svg>
          </button>
        </div>
      </header>
      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4 relative">
        <Outlet />
        <div className="absolute inset-0 flex items-end justify-center pb-4 pointer-events-none">
          <img src="/main-aja-dulu.png" alt="" className="w-28 object-contain opacity-[0.05]" />
        </div>
      </main>
    </div>
  )
}
