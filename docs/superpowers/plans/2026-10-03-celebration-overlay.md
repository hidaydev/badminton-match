# Celebration Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a full-screen confetti celebration overlay with the team photo on every load of the home page, dismissible by tapping anywhere.

**Architecture:** A single `CelebrationOverlay` component renders a fixed full-screen backdrop with CSS-animated confetti particles and the team photo centered. It is mounted in `HomePage` via a `useState(true)` flag — no localStorage persistence, so it resets on every page refresh. The PNG asset is copied to `public/` so it's served statically.

**Tech Stack:** React 19, TypeScript, Tailwind v4, CSS `@keyframes` (no new npm dependencies)

---

### Task 1: Copy team photo to public assets

**Files:**
- Create: `apps/web/public/team-winner.png` (copied from source)

- [ ] **Step 1: Copy the PNG**

```bash
cp "/Users/hidaydev/Documents/Design/team example.png" apps/web/public/team-winner.png
```

Expected: file `apps/web/public/team-winner.png` exists.

- [ ] **Step 2: Verify**

```bash
ls -lh apps/web/public/team-winner.png
```

Expected: file listed with non-zero size.

- [ ] **Step 3: Commit**

```bash
git add apps/web/public/team-winner.png
git commit -m "feat(assets): add team winner photo for celebration overlay"
```

---

### Task 2: Add confetti keyframes to global CSS

**Files:**
- Modify: `apps/web/src/index.css` (append at end of file)

- [ ] **Step 1: Append keyframes**

Add this block at the very end of `apps/web/src/index.css`:

```css
/* Celebration overlay — confetti particle fall */
@keyframes confettiFall {
  0%   { transform: translateY(-10vh) rotate(0deg);   opacity: 1; }
  80%  { opacity: 1; }
  100% { transform: translateY(110vh) rotate(720deg); opacity: 0; }
}
```

- [ ] **Step 2: Verify dev server compiles without error**

```bash
npm run dev
```

Expected: Vite starts, no CSS parse errors in terminal.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/index.css
git commit -m "feat(css): add confettiFall keyframes for celebration overlay"
```

---

### Task 3: Build CelebrationOverlay component

**Files:**
- Create: `apps/web/src/components/CelebrationOverlay.tsx`

- [ ] **Step 1: Create the component**

Create `apps/web/src/components/CelebrationOverlay.tsx` with this exact content:

```tsx
interface CelebrationOverlayProps {
  onDismiss(): void
}

const COLORS = [
  '#e3b341', '#ffffff', '#5fb58f', '#d65a5a',
  '#6d9dc8', '#e8cd83', '#82c6a6', '#e08d89',
]

const PARTICLES = Array.from({ length: 60 }, (_, i) => ({
  id: i,
  left: `${(i * 1.7 + Math.sin(i) * 11) % 100}%`,
  color: COLORS[i % COLORS.length],
  width: 6 + (i % 5) * 2,
  height: 10 + (i % 4) * 3,
  delay: `${(i * 0.17) % 3}s`,
  duration: `${2.5 + (i % 5) * 0.4}s`,
  borderRadius: i % 3 === 0 ? '50%' : '2px',
}))

export default function CelebrationOverlay({ onDismiss }: CelebrationOverlayProps) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center overflow-hidden"
      style={{ background: 'rgba(0,0,0,0.82)' }}
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Team celebration"
    >
      {/* Confetti layer — pointer-events none so tap always hits backdrop */}
      <div className="absolute inset-0 pointer-events-none" aria-hidden="true">
        {PARTICLES.map((p) => (
          <div
            key={p.id}
            className="absolute top-0"
            style={{
              left: p.left,
              width: p.width,
              height: p.height,
              background: p.color,
              borderRadius: p.borderRadius,
              animation: `confettiFall ${p.duration} ${p.delay} linear infinite`,
            }}
          />
        ))}
      </div>

      {/* Team photo */}
      <img
        src="/team-winner.png"
        alt="Majadu Badminton Club — Champions"
        className="relative z-10 max-h-[72vh] max-w-[90vw] object-contain drop-shadow-2xl
          animate-[fadeInScale_0.4s_ease-out]"
        draggable={false}
      />
    </div>
  )
}
```

- [ ] **Step 2: Add fadeInScale keyframe to index.css**

Append to `apps/web/src/index.css` (after the confettiFall block):

```css
@keyframes fadeInScale {
  from { opacity: 0; transform: scale(0.88); }
  to   { opacity: 1; transform: scale(1); }
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/components/CelebrationOverlay.tsx apps/web/src/index.css
git commit -m "feat(ui): add CelebrationOverlay component with CSS confetti"
```

---

### Task 4: Wire CelebrationOverlay into HomePage

**Files:**
- Modify: `apps/web/src/pages/HomePage.tsx`

- [ ] **Step 1: Add import and state**

At the top of `apps/web/src/pages/HomePage.tsx`, add the import alongside other imports:

```tsx
import CelebrationOverlay from '../components/CelebrationOverlay'
```

Inside `HomePage()`, add this state declaration right after the existing `useState` calls:

```tsx
const [showCelebration, setShowCelebration] = useState(true)
```

- [ ] **Step 2: Render the overlay**

Inside the returned JSX, just before the closing `</div>`, add:

```tsx
      {showCelebration && (
        <CelebrationOverlay onDismiss={() => setShowCelebration(false)} />
      )}
```

The full return block's closing should look like:

```tsx
      {modalOpen && (
        <InstallModal
          isIos={isIos}
          onInstall={handleInstall}
          onClose={() => {
            localStorage.setItem('pwa-install-shown', today)
            setInstallDismissed(true)
            setManualInstallOpen(false)
          }}
        />
      )}

      {showCelebration && (
        <CelebrationOverlay onDismiss={() => setShowCelebration(false)} />
      )}
    </div>
```

- [ ] **Step 3: Type-check**

```bash
npm run check:web
```

Expected: 0 TypeScript errors, 0 lint errors.

- [ ] **Step 4: Commit**

```bash
git add apps/web/src/pages/HomePage.tsx
git commit -m "feat(home): show celebration overlay on every page load"
```

---

### Task 5: Manual verification in browser

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Open home page**

Navigate to `http://localhost:5173/` — confirm:
- Dark overlay appears immediately
- Confetti particles fall across the entire screen
- Team photo is centered, visible, and has a fade-in scale animation
- Tap anywhere on the backdrop → overlay dismisses
- Home page content is visible underneath after dismiss

- [ ] **Step 3: Refresh test**

Refresh the page (`Cmd+R`) — confirm overlay reappears (no persistence).

- [ ] **Step 4: Route test**

Navigate away (e.g. `/ratings`) then back to `/` — confirm overlay reappears.
