# Anniversary Banner Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the celebration overlay in App.tsx with a full-screen anniversary "coming soon" banner showing two player groups sliding in from the sides, the MAJADU 1ST ANNIVERSARY logo dropping from the top, and team lineup logos fading in at the center.

**Architecture:** A single `AnnivBannerOverlay` component uses CSS `@keyframes` (no new deps) to animate 4 PNG assets into a dramatic reveal. It mounts via `useState(true)` in `App.tsx` — no localStorage, so it appears on every load. The existing `CelebrationOverlay` import/state in `App.tsx` is replaced with `AnnivBannerOverlay`.

**Tech Stack:** React 19, TypeScript, Tailwind v4, CSS `@keyframes`

---

### Task 1: Copy assets to public

**Files:**
- Create: `apps/web/public/anniv-left.png`
- Create: `apps/web/public/anniv-right.png`
- Create: `apps/web/public/anniv-top.png`
- Create: `apps/web/public/anniv-center.png`

- [ ] **Step 1: Copy all four assets**

```bash
cp "/Users/hidaydev/Downloads/left.png"   apps/web/public/anniv-left.png
cp "/Users/hidaydev/Downloads/right.png"  apps/web/public/anniv-right.png
cp "/Users/hidaydev/Downloads/top.png"    apps/web/public/anniv-top.png
cp "/Users/hidaydev/Downloads/center.png" apps/web/public/anniv-center.png
```

- [ ] **Step 2: Verify all four files exist with non-zero size**

```bash
ls -lh apps/web/public/anniv-*.png
```

Expected: 4 files listed, each with non-zero size.

- [ ] **Step 3: Commit**

```bash
git add apps/web/public/anniv-left.png apps/web/public/anniv-right.png \
        apps/web/public/anniv-top.png apps/web/public/anniv-center.png
git commit -m "feat(assets): add anniversary banner images"
```

---

### Task 2: Add animation keyframes to global CSS

**Files:**
- Modify: `apps/web/src/index.css` (append at end)

- [ ] **Step 1: Append all four keyframes to the end of `apps/web/src/index.css`**

```css
/* Anniversary banner overlay animations */
@keyframes annivSlideInLeft {
  from { transform: translateX(-110%); opacity: 0; }
  to   { transform: translateX(0);     opacity: 1; }
}

@keyframes annivSlideInRight {
  from { transform: translateX(110%); opacity: 0; }
  to   { transform: translateX(0);    opacity: 1; }
}

@keyframes annivSlideInTop {
  from { transform: translateY(-60px); opacity: 0; }
  to   { transform: translateY(0);     opacity: 1; }
}

@keyframes annivFadeInUp {
  from { transform: translateY(30px) scale(0.92); opacity: 0; }
  to   { transform: translateY(0)    scale(1);    opacity: 1; }
}
```

- [ ] **Step 2: Verify dev server compiles without CSS errors**

```bash
cd /Users/hidaydev/Code/badminton-pair && npm run dev &
sleep 5 && kill %1
```

Expected: Vite starts, no parse errors printed.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/index.css
git commit -m "feat(css): add anniversary banner keyframes"
```

---

### Task 3: Build AnnivBannerOverlay component

**Files:**
- Create: `apps/web/src/components/AnnivBannerOverlay.tsx`

- [ ] **Step 1: Create the component**

Create `apps/web/src/components/AnnivBannerOverlay.tsx` with this exact content:

```tsx
import { useRef, useEffect } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface AnnivBannerOverlayProps {
  onDismiss(): void
}

export default function AnnivBannerOverlay({ onDismiss }: AnnivBannerOverlayProps) {
  const overlayRef = useRef<HTMLDivElement>(null)
  useEscapeKey(onDismiss)
  useEffect(() => { overlayRef.current?.focus() }, [])

  return (
    <div
      ref={overlayRef}
      tabIndex={-1}
      className="fixed inset-0 z-50 overflow-hidden bg-black/90 flex flex-col items-center justify-center"
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Majadu 1st Anniversary"
    >
      {/* Anniversary logo — slides down from top */}
      <div
        className="pointer-events-none relative z-20 flex justify-center px-6"
        style={{ animation: 'annivSlideInTop 0.6s 0.3s ease-out both' }}
      >
        <img
          src="/anniv-top.png"
          alt="Majadu 1st Anniversary"
          className="w-full max-w-xs object-contain drop-shadow-2xl"
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>

      {/* Side players row */}
      <div className="pointer-events-none relative z-10 flex w-full items-end justify-between flex-1">
        {/* Left player group */}
        <img
          src="/anniv-left.png"
          alt=""
          aria-hidden="true"
          className="h-[55vh] max-w-[45vw] object-contain object-bottom"
          style={{ animation: 'annivSlideInLeft 0.7s 0s ease-out both' }}
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
        {/* Right player group */}
        <img
          src="/anniv-right.png"
          alt=""
          aria-hidden="true"
          className="h-[55vh] max-w-[45vw] object-contain object-bottom"
          style={{ animation: 'annivSlideInRight 0.7s 0s ease-out both' }}
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>

      {/* Team lineup logos — fades up in center */}
      <div
        className="pointer-events-none absolute z-20 flex justify-center px-8"
        style={{ animation: 'annivFadeInUp 0.7s 0.6s ease-out both' }}
      >
        <img
          src="/anniv-center.png"
          alt="Team lineup"
          className="w-full max-w-sm object-contain drop-shadow-xl"
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/web/src/components/AnnivBannerOverlay.tsx
git commit -m "feat(ui): add AnnivBannerOverlay component"
```

---

### Task 4: Swap CelebrationOverlay for AnnivBannerOverlay in App.tsx

**Files:**
- Modify: `apps/web/src/App.tsx`

The current `App.tsx` has these lines (from the celebration feature):
```tsx
import CelebrationOverlay from './components/CelebrationOverlay'
// ...
const [showCelebration, setShowCelebration] = useState(true)
// ...
{showCelebration && (
  <CelebrationOverlay onDismiss={() => setShowCelebration(false)} />
)}
```

- [ ] **Step 1: Replace the import**

Change:
```tsx
import CelebrationOverlay from './components/CelebrationOverlay'
```
To:
```tsx
import AnnivBannerOverlay from './components/AnnivBannerOverlay'
```

- [ ] **Step 2: Replace the JSX render**

Change:
```tsx
      {showCelebration && (
        <CelebrationOverlay onDismiss={() => setShowCelebration(false)} />
      )}
```
To:
```tsx
      {showCelebration && (
        <AnnivBannerOverlay onDismiss={() => setShowCelebration(false)} />
      )}
```

The `useState(true)` and variable name `showCelebration` can stay as-is — no need to rename them.

- [ ] **Step 3: Run type-check**

```bash
cd /Users/hidaydev/Code/badminton-pair && npm run check:web
```

Expected: 0 TypeScript errors, 0 lint errors, 83 regression tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/web/src/App.tsx
git commit -m "feat(app): swap to anniversary banner overlay"
```

---

### Task 5: Push branch

- [ ] **Step 1: Push anniv-banner to remote**

```bash
git push -u origin anniv-banner
```

Expected: branch pushed, remote tracking set.
