import { Link, Outlet } from 'react-router-dom'
import { useRegisterSW } from 'virtual:pwa-register/react'
import UpdateBanner from './UpdateBanner'

export default function HomeLayout() {
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW()

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      {needRefresh && (
        <UpdateBanner
          onReload={() => updateServiceWorker(true)}
          onDismiss={() => setNeedRefresh(false)}
        />
      )}
      <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
          <Link to="/" className="flex items-center gap-2">
            <img src="/logo.png" alt="logo" className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-white tracking-tight">MAJADU APP</h1>
          </Link>
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
