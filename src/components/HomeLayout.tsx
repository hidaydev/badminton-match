import { Link, Outlet } from 'react-router-dom'

export default function HomeLayout() {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
          <Link to="/" className="flex items-center gap-2">
            <span className="text-xl shrink-0">🏸</span>
            <h1 className="text-sm font-bold text-white tracking-tight">MAJADU APP</h1>
          </Link>
        </div>
      </header>
      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4">
        <Outlet />
      </main>
    </div>
  )
}
