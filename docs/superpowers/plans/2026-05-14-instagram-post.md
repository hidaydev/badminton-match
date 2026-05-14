# Instagram Post Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Instagram Post" page where users upload a photo, it composites with a branded footer overlay on a canvas, and downloads as a 1080×1350 PNG.

**Architecture:** Fully client-side HTML5 Canvas compositing. A static template config defines canvas dimensions and asset paths (header/footer PNGs). The page holds a single `<canvas>` at full resolution (1080×1350), scaled down via CSS for preview. Photo repositioning is handled via mouse/touch drag events scaled by the canvas/display ratio.

**Tech Stack:** React 19, TypeScript, HTML5 Canvas API, Tailwind v4. No new dependencies.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `public/instagram-footer.png` | **Create** (copy asset) | Footer overlay image served as static asset |
| `src/config/instagramTemplates.ts` | **Create** | Template definitions (dimensions, asset paths) |
| `src/pages/InstagramPostPage.tsx` | **Create** | Full page: canvas preview, upload, drag, download |
| `src/App.tsx` | **Modify** | Add `/instagram-post` route under HomeLayout |
| `src/pages/HomePage.tsx` | **Modify** | Add Instagram Post menu item |

---

## Task 1: Copy footer asset to public/

**Files:**
- Create: `public/instagram-footer.png`

- [ ] **Step 1: Copy the footer image**

```bash
cp /Users/hidaydev/Documents/Design/test.png /Users/hidaydev/Code/badminton-pair/public/instagram-footer.png
```

- [ ] **Step 2: Verify it exists**

```bash
ls -lh public/instagram-footer.png
```

Expected: file listed, non-zero size.

- [ ] **Step 3: Commit**

```bash
git add public/instagram-footer.png
git commit -m "feat: add instagram footer overlay asset"
```

---

## Task 2: Create template config

**Files:**
- Create: `src/config/instagramTemplates.ts`

- [ ] **Step 1: Create the file**

```ts
// src/config/instagramTemplates.ts

export interface PostTemplate {
  id: string
  label: string
  width: number
  height: number
  header?: string  // absolute URL path to PNG asset
  footer?: string  // absolute URL path to PNG asset
}

export const instagramTemplates: PostTemplate[] = [
  {
    id: 'portrait-v1',
    label: 'Portrait 4:5',
    width: 1080,
    height: 1350,
    footer: '/instagram-footer.png',
  },
]
```

- [ ] **Step 2: Commit**

```bash
git add src/config/instagramTemplates.ts
git commit -m "feat: add instagram post template config"
```

---

## Task 3: Create InstagramPostPage

**Files:**
- Create: `src/pages/InstagramPostPage.tsx`

- [ ] **Step 1: Create the page with canvas compositing**

```tsx
// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'

const TEMPLATE = instagramTemplates[0]

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
) {
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight)
  const w = img.naturalWidth * scale
  const h = img.naturalHeight * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function drawCanvas(
  canvas: HTMLCanvasElement,
  template: PostTemplate,
  userPhoto: HTMLImageElement | null,
  photoOffset: { x: number; y: number },
  overlayImages: { header?: HTMLImageElement; footer?: HTMLImageElement },
) {
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, canvas.width, canvas.height, photoOffset.x, photoOffset.y)
  } else {
    ctx.fillStyle = '#1e293b'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
  }

  // Layer 2: header
  if (overlayImages.header) {
    const img = overlayImages.header
    const h = canvas.width * (img.naturalHeight / img.naturalWidth)
    ctx.drawImage(img, 0, 0, canvas.width, h)
  }

  // Layer 3: footer
  if (overlayImages.footer) {
    const img = overlayImages.footer
    const h = canvas.width * (img.naturalHeight / img.naturalWidth)
    ctx.drawImage(img, 0, canvas.height - h, canvas.width, h)
  }
}

export default function InstagramPostPage() {
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [userPhoto, setUserPhoto] = useState<HTMLImageElement | null>(null)
  const [photoOffset, setPhotoOffset] = useState({ x: 0, y: 0 })
  const [overlays, setOverlays] = useState<{ header?: HTMLImageElement; footer?: HTMLImageElement }>({})
  const [isDragging, setIsDragging] = useState(false)
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)

  // Load template overlay images once
  useEffect(() => {
    const loadOverlays = async () => {
      const result: { header?: HTMLImageElement; footer?: HTMLImageElement } = {}
      if (TEMPLATE.header) result.header = await loadImage(TEMPLATE.header)
      if (TEMPLATE.footer) result.footer = await loadImage(TEMPLATE.footer)
      setOverlays(result)
    }
    loadOverlays()
  }, [])

  // Redraw canvas whenever inputs change
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    drawCanvas(canvas, TEMPLATE, userPhoto, photoOffset, overlays)
  }, [userPhoto, photoOffset, overlays])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    const img = await loadImage(url)
    setUserPhoto(img)
    setPhotoOffset({ x: 0, y: 0 })
  }, [])

  // Scale client coords to canvas coords
  const toCanvasCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width / rect.width
    const scaleY = canvas.height / rect.height
    return { x: (clientX - rect.left) * scaleX, y: (clientY - rect.top) * scaleY }
  }, [])

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if (!userPhoto) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    setIsDragging(true)
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onMouseMove = useCallback((e: React.MouseEvent) => {
    if (!dragStart.current) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    const dx = pos.x - dragStart.current.x
    const dy = pos.y - dragStart.current.y
    setPhotoOffset({ x: dragStart.current.ox + dx, y: dragStart.current.oy + dy })
  }, [toCanvasCoords])

  const onMouseUp = useCallback(() => {
    dragStart.current = null
    setIsDragging(false)
  }, [])

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    if (!userPhoto) return
    const t = e.touches[0]
    const pos = toCanvasCoords(t.clientX, t.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onTouchMove = useCallback((e: React.TouchEvent) => {
    e.preventDefault()
    if (!dragStart.current) return
    const t = e.touches[0]
    const pos = toCanvasCoords(t.clientX, t.clientY)
    const dx = pos.x - dragStart.current.x
    const dy = pos.y - dragStart.current.y
    setPhotoOffset({ x: dragStart.current.ox + dx, y: dragStart.current.oy + dy })
  }, [toCanvasCoords])

  const onTouchEnd = useCallback(() => {
    dragStart.current = null
  }, [])

  const handleDownload = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !userPhoto) return
    canvas.toBlob((blob) => {
      if (!blob) return
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = 'majadu-post.png'
      a.click()
      URL.revokeObjectURL(url)
    }, 'image/png')
  }, [userPhoto])

  return (
    <div className="flex flex-col gap-6 pt-4 pb-10">
      {/* Header */}
      <div className="flex items-center gap-3">
        <button
          onClick={() => navigate('/')}
          className="text-slate-500 hover:text-slate-300 transition-colors text-lg leading-none"
        >
          ←
        </button>
        <div>
          <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Create</p>
          <h2 className="text-xl font-bold text-yellow-400 tracking-tight leading-none">Instagram Post</h2>
        </div>
      </div>

      {/* Canvas preview */}
      <div className="w-full">
        <canvas
          ref={canvasRef}
          width={TEMPLATE.width}
          height={TEMPLATE.height}
          className={`w-full rounded-xl border border-slate-800 ${userPhoto ? (isDragging ? 'cursor-grabbing' : 'cursor-grab') : 'cursor-default'}`}
          onMouseDown={onMouseDown}
          onMouseMove={onMouseMove}
          onMouseUp={onMouseUp}
          onMouseLeave={onMouseUp}
          onTouchStart={onTouchStart}
          onTouchMove={onTouchMove}
          onTouchEnd={onTouchEnd}
        />
        {userPhoto && (
          <p className="text-center text-[10px] text-slate-600 mt-1 font-mono">drag to reposition</p>
        )}
      </div>

      {/* Upload */}
      <div className="flex flex-col gap-1.5">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Photo</p>
        <button
          onClick={() => fileInputRef.current?.click()}
          className="w-full bg-slate-900 border border-dashed border-slate-700 rounded-xl p-6 flex flex-col items-center gap-2 hover:border-slate-500 transition-colors"
        >
          <span className="text-2xl">{userPhoto ? '🔄' : '📷'}</span>
          <span className="text-sm text-slate-400">{userPhoto ? 'Change photo' : 'Tap to upload photo'}</span>
          <span className="text-xs text-slate-600">JPG or PNG</span>
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="hidden"
          onChange={handleFileChange}
        />
      </div>

      {/* Download */}
      <button
        onClick={handleDownload}
        disabled={!userPhoto}
        className="w-full bg-yellow-400 text-black font-bold text-sm py-3.5 rounded-xl disabled:opacity-30 disabled:cursor-not-allowed hover:bg-yellow-300 transition-colors"
      >
        ⬇ Download (1080 × 1350)
      </button>
      {!userPhoto && (
        <p className="text-center text-xs text-slate-600 -mt-4">Upload a photo to enable download</p>
      )}
    </div>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add src/pages/InstagramPostPage.tsx
git commit -m "feat: add InstagramPostPage with canvas compositing"
```

---

## Task 4: Wire up route and menu item

**Files:**
- Modify: `src/App.tsx`
- Modify: `src/pages/HomePage.tsx`

- [ ] **Step 1: Add route to App.tsx**

In `src/App.tsx`, add the import at the top with other page imports:

```tsx
import InstagramPostPage from './pages/InstagramPostPage'
```

Inside the `<Route element={<HomeLayout />}>` block, add after the `tournament` route:

```tsx
<Route path="instagram-post" element={<InstagramPostPage />} />
```

- [ ] **Step 2: Add menu item to HomePage.tsx**

In `src/pages/HomePage.tsx`, update the `menu` array to add the new item:

```tsx
const menu = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new', badge: null },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions', badge: null },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history', badge: null },
  { icon: '🏆', label: 'Tournament', description: 'Standings & cup', to: '/tournament', badge: null },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post', badge: null },
] as const
```

- [ ] **Step 3: Commit**

```bash
git add src/App.tsx src/pages/HomePage.tsx
git commit -m "feat: add instagram-post route and home menu item"
```

---

## Task 5: Manual smoke test

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Verify home page**

Open `http://localhost:5173`. Confirm "Instagram Post" card appears in the menu grid.

- [ ] **Step 3: Verify page loads**

Click the Instagram Post card. Confirm:
- Page loads at `/instagram-post`
- Canvas renders (dark background + footer overlay at bottom)
- Back arrow navigates to home

- [ ] **Step 4: Verify photo upload**

Tap "Tap to upload photo", select a JPG. Confirm:
- Photo appears filling the canvas
- Footer PNG overlays on top at the bottom
- "drag to reposition" hint appears below canvas

- [ ] **Step 5: Verify drag**

Drag on the canvas. Confirm photo repositions while footer stays fixed.

- [ ] **Step 6: Verify download**

Click "Download". Confirm a `majadu-post.png` file is saved at 1080×1350px with the photo and footer composited correctly.

- [ ] **Step 7: Type check**

```bash
npm run build
```

Expected: no TypeScript errors, build succeeds.
