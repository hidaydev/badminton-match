# PWA Install Modal + Update Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add vite-plugin-pwa, a custom install-to-homescreen modal (iOS/Android), an "Install App" homepage card, and a top update-notification banner.

**Architecture:** `vite-plugin-pwa` generates a service worker and manifest on each build. A `usePwaInstall` hook detects install state and captures the Android prompt. `HomeLayout` renders a persistent `UpdateBanner` and hosts `InstallModal` state. `HomePage` auto-shows the modal after 1.5s and adds an "Install App" card.

**Tech Stack:** vite-plugin-pwa, Workbox (via plugin), React hooks, Tailwind v4

**Worktree:** `.worktrees/pwa-install` on branch `feature/pwa-install`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `package.json` | Add `vite-plugin-pwa` dev dependency |
| Modify | `vite.config.ts` | Register PWA plugin with manifest + SW config |
| Create | `src/hooks/usePwaInstall.ts` | Detect install state, capture Android prompt |
| Create | `src/components/InstallModal.tsx` | iOS/Android install bottom-sheet |
| Create | `src/components/UpdateBanner.tsx` | Top-bar update notification |
| Modify | `src/components/HomeLayout.tsx` | Render UpdateBanner + pass install modal controls |
| Modify | `src/pages/HomePage.tsx` | Add Install App card + auto-show modal after 1.5s |

---

## Task 1: Install vite-plugin-pwa

**Files:**
- Modify: `package.json`
- Modify: `vite.config.ts`

- [ ] **Step 1: Install the package**

Run in `.worktrees/pwa-install/`:
```bash
npm install -D vite-plugin-pwa
```
Expected: package added, `package.json` devDependencies updated.

- [ ] **Step 2: Update vite.config.ts**

Replace the full file:
```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'prompt',
      manifest: {
        name: 'Majadu App',
        short_name: 'Majadu',
        description: 'Badminton scheduler & tournament manager',
        theme_color: '#020617',
        background_color: '#020617',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: '/logo.png', sizes: '192x192', type: 'image/png' },
          { src: '/logo.png', sizes: '512x512', type: 'image/png' },
        ],
      },
    }),
  ],
})
```

- [ ] **Step 3: Verify dev server starts without errors**

```bash
npm run dev
```
Expected: server starts, no TypeScript or plugin errors in console. Stop with Ctrl+C.

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json vite.config.ts
git commit -m "feat: add vite-plugin-pwa with manifest config"
```

---

## Task 2: Create usePwaInstall hook

**Files:**
- Create: `src/hooks/usePwaInstall.ts`

- [ ] **Step 1: Create the hook**

```ts
import { useState, useEffect } from 'react'

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

export function usePwaInstall() {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null)
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches
  const isIos = /iphone|ipad|ipod/i.test(navigator.userAgent)

  useEffect(() => {
    const handler = (e: Event) => {
      e.preventDefault()
      setDeferredPrompt(e as BeforeInstallPromptEvent)
    }
    window.addEventListener('beforeinstallprompt', handler)
    return () => window.removeEventListener('beforeinstallprompt', handler)
  }, [])

  const isInstallable = !isStandalone && (isIos || deferredPrompt !== null)

  async function prompt() {
    if (!deferredPrompt) return
    await deferredPrompt.prompt()
    const { outcome } = await deferredPrompt.userChoice
    if (outcome === 'accepted') setDeferredPrompt(null)
  }

  return { isInstallable, isIos, prompt }
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|Error" | head -20
```
Expected: no errors mentioning `usePwaInstall.ts`.

- [ ] **Step 3: Commit**

```bash
git add src/hooks/usePwaInstall.ts
git commit -m "feat: add usePwaInstall hook for install state detection"
```

---

## Task 3: Create InstallModal component

**Files:**
- Create: `src/components/InstallModal.tsx`

- [ ] **Step 1: Create the component**

```tsx
interface Props {
  isIos: boolean
  onInstall(): void
  onClose(): void
}

export default function InstallModal({ isIos, onInstall, onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-full max-w-lg bg-slate-900 border border-slate-700 rounded-t-3xl p-6 pb-10 flex flex-col gap-5">
        <div className="w-10 h-1 bg-slate-700 rounded-full mx-auto" />

        <div className="flex flex-col gap-1">
          <h2 className="text-lg font-bold text-white">Install Majadu App</h2>
          <p className="text-sm text-slate-400">
            {isIos
              ? 'Follow these steps to add to your home screen:'
              : 'Add to your home screen for quick access — works offline too.'}
          </p>
        </div>

        {isIos ? (
          <ol className="flex flex-col gap-3">
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">1.</span>
              <span className="text-sm text-slate-300">
                Tap the <span className="font-semibold text-white">Share</span> button{' '}
                <span className="inline-block text-base">⬆️</span> in Safari's toolbar at the bottom of the screen.
              </span>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">2.</span>
              <span className="text-sm text-slate-300">
                Scroll down and tap{' '}
                <span className="font-semibold text-white">"Add to Home Screen"</span>.
              </span>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">3.</span>
              <span className="text-sm text-slate-300">
                Tap <span className="font-semibold text-white">"Add"</span> to confirm.
              </span>
            </li>
          </ol>
        ) : null}

        <div className="flex flex-col gap-2 pt-1">
          {!isIos && (
            <button
              onClick={onInstall}
              className="w-full py-3 rounded-xl bg-yellow-400 text-slate-950 font-bold text-sm active:scale-[0.98] transition-transform"
            >
              Install
            </button>
          )}
          <button
            onClick={onClose}
            className="w-full py-3 rounded-xl bg-slate-800 text-slate-300 font-medium text-sm active:scale-[0.98] transition-transform"
          >
            {isIos ? 'Got it' : 'Not now'}
          </button>
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|Error" | head -20
```
Expected: no errors mentioning `InstallModal.tsx`.

- [ ] **Step 3: Commit**

```bash
git add src/components/InstallModal.tsx
git commit -m "feat: add InstallModal component (iOS/Android variants)"
```

---

## Task 4: Create UpdateBanner component

**Files:**
- Create: `src/components/UpdateBanner.tsx`

- [ ] **Step 1: Create the component**

```tsx
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
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|Error" | head -20
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/components/UpdateBanner.tsx
git commit -m "feat: add UpdateBanner component for SW update notifications"
```

---

## Task 5: Wire UpdateBanner into HomeLayout

**Files:**
- Modify: `src/components/HomeLayout.tsx`

- [ ] **Step 1: Update HomeLayout to include UpdateBanner**

Replace the full file:
```tsx
import { Link, Outlet } from 'react-router-dom'
import { useRegisterSW } from 'virtual:pwa-register/react'
import UpdateBanner from './UpdateBanner'

export default function HomeLayout() {
  const { needRefresh: [needRefresh], updateServiceWorker } = useRegisterSW()

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      {needRefresh && (
        <UpdateBanner onReload={() => updateServiceWorker(true)} />
      )}
      <header
        className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10"
        style={{ marginTop: needRefresh ? '40px' : undefined }}
      >
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
```

- [ ] **Step 2: Add TypeScript type declaration for virtual:pwa-register/react**

Create `src/vite-pwa.d.ts`:
```ts
declare module 'virtual:pwa-register/react' {
  import type { Dispatch, SetStateAction } from 'react'
  export interface RegisterSWOptions {
    immediate?: boolean
    onNeedRefresh?(): void
    onOfflineReady?(): void
    onRegistered?(registration: ServiceWorkerRegistration | undefined): void
    onRegisteredSW?(swUrl: string, registration: ServiceWorkerRegistration | undefined): void
    onRegisterError?(error: unknown): void
  }
  export function useRegisterSW(options?: RegisterSWOptions): {
    needRefresh: [boolean, Dispatch<SetStateAction<boolean>>]
    offlineReady: [boolean, Dispatch<SetStateAction<boolean>>]
    updateServiceWorker(reloadPage?: boolean): Promise<void>
  }
}
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|Error" | head -20
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/components/HomeLayout.tsx src/vite-pwa.d.ts
git commit -m "feat: wire UpdateBanner into HomeLayout, expose install modal event"
```

---

## Task 6: Update HomePage with install modal + auto-show

**Files:**
- Modify: `src/pages/HomePage.tsx`

- [ ] **Step 1: Replace HomePage with install-aware version**

```tsx
import { useNavigate } from 'react-router-dom'
import { useState, useEffect } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import InstallModal from '../components/InstallModal'


const grid = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new' },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: '🎯', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post' },
] as const

async function openScoreboard(navigate: (path: string) => void) {
  try { await document.documentElement.requestFullscreen() } catch {}
  try { await screen.orientation.lock('landscape') } catch {}
  navigate('/scoreboard')
}

export default function HomePage() {
  const navigate = useNavigate()
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const [modalOpen, setModalOpen] = useState(false)

  // Auto-show after 1.5s if installable
  useEffect(() => {
    if (!isInstallable) return
    const t = setTimeout(() => setModalOpen(true), 1500)
    return () => clearTimeout(t)
  }, [isInstallable])

  async function handleInstall() {
    await prompt()
    setModalOpen(false)
  }

  return (
    <div className="flex flex-col gap-6 pt-6">
      <div className="flex flex-col gap-1">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Badminton</p>
        <h2 className="text-3xl font-bold text-yellow-400 tracking-tight leading-none">Scheduler</h2>
        <p className="text-slate-500 text-xs mt-2 font-mono">Select an option to get started</p>
      </div>

      {/* Tournament hero */}
      <button
        onClick={() => navigate('/tournament')}
        className="relative overflow-hidden flex items-center gap-4 p-5 rounded-2xl text-left
          bg-gradient-to-br from-amber-900 via-amber-700 to-amber-600
          border border-amber-600/40 hover:brightness-110 active:scale-[0.98] transition-all duration-200"
      >
        <img
          src="/tournament-badge.png"
          alt=""
          className="absolute right-[-10px] top-1/2 -translate-y-1/2 w-24 h-24 object-contain opacity-20 pointer-events-none"
        />
        <span className="text-3xl relative z-10">🏆</span>
        <div className="relative z-10">
          <span className="text-base font-bold text-white leading-tight block">Tournament</span>
          <span className="text-xs text-amber-200/70">Leaderboard & cup</span>
        </div>
      </button>

      {/* 2×N grid */}
      <div className="grid grid-cols-2 gap-2.5">
        {grid.map((item) => (
          <button
            key={item.to}
            onClick={() => item.to === '/scoreboard' ? openScoreboard(navigate) : navigate(item.to)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-[0.98]"
          >
            <span className="text-2xl">{item.icon}</span>
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-semibold text-white leading-tight">{item.label}</span>
              <span className="text-[11px] text-slate-500">{item.description}</span>
            </div>
            <span className="absolute bottom-4 right-4 text-slate-700 group-hover:text-slate-500 transition-colors text-sm font-mono">→</span>
          </button>
        ))}

        {isInstallable && (
          <button
            onClick={() => setModalOpen(true)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-[0.98]"
          >
            <span className="text-2xl">📲</span>
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-semibold text-white leading-tight">Install App</span>
              <span className="text-[11px] text-slate-500">Add to your home screen</span>
            </div>
            <span className="absolute bottom-4 right-4 text-slate-700 group-hover:text-slate-500 transition-colors text-sm font-mono">→</span>
          </button>
        )}
      </div>

      {modalOpen && (
        <InstallModal
          isIos={isIos}
          onInstall={handleInstall}
          onClose={() => setModalOpen(false)}
        />
      )}
    </div>
  )
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | grep -E "error|Error" | head -20
```
Expected: no errors.

- [ ] **Step 3: Verify build output includes sw.js**

```bash
ls dist/ | grep sw
```
Expected: `sw.js` and `workbox-*.js` in `dist/`.

- [ ] **Step 4: Commit**

```bash
git add src/pages/HomePage.tsx
git commit -m "feat: add Install App card and auto-show install modal on homepage"
```

---

## Task 7: Smoke test in browser

**Files:** none (verification only)

- [ ] **Step 1: Preview the production build**

```bash
npm run preview
```
Open `http://localhost:4173` in Chrome (desktop or Android emulator).

- [ ] **Step 2: Verify UpdateBanner**

Open DevTools → Application → Service Workers → click "Update" on the registered SW. The amber banner should appear at the top with a "Reload" button.

- [ ] **Step 3: Verify Install Modal (Android/Chrome)**

In Chrome DevTools → Application → Manifest → check "Add to homescreen". On a real Android device, the modal should auto-appear after 1.5s and show the Install button.

- [ ] **Step 4: Verify Install Modal (iOS)**

Open on iOS Safari (or use `navigator.userAgent` override in DevTools). Modal should appear with step-by-step instructions and "Got it" button.

- [ ] **Step 5: Verify Install App card hidden in standalone mode**

Run the app installed (or use DevTools → Rendering → "Display mode: standalone"). The Install App card should not appear.

- [ ] **Step 6: Commit any fixes found during smoke test**

```bash
git add -p
git commit -m "fix: <describe any issue found>"
```
