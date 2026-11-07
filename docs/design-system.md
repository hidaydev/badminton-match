# Majadu App — Design System

> Formalized and adopted across the codebase. Last updated: 2026-11-07.

## Typography

| Role | Font | Weight | Tailwind | Usage |
|------|------|--------|----------|-------|
| Body | IBM Plex Sans | 400, 500, 600, 700 | `font-sans` | All UI text |
| Monospace | IBM Plex Mono | 400, 500 | `font-mono` | Labels, metadata, timestamps |
| Decorative | Road Rage + Edosz | — | — | Instagram canvas date overlay only |

IBM Plex Sans/Mono dan Road Rage & Edosz semuanya self-hosted lewat `@font-face`
di `apps/web/index.html` (`display=swap`, berkas di `apps/web/public/fonts/` dan
`apps/web/public/`). Body uses `var(--font-sans)`.
Road Rage diterapkan dengan skew −9° agar posturnya menyerupai Granesta v1.
Keduanya berkas pihak ketiga — lihat `THIRD-PARTY-NOTICES.md`.

## Color Tokens (Tailwind v4 `@theme`)

> These are the actual tokens used in components. Defined in the `@theme` block of
> `apps/web/src/index.css`. Contrast ratios dihitung terhadap `--color-ground`.

### Background
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-ground` | `#0b0e13` | `bg-ground` | Page background |
| `--color-surface` | `#14181f` | `bg-surface` | Cards, panels |
| `--color-elevated` | `#1c212b` | `bg-elevated` | Inner cards, inputs |

### Border
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-border` | `#2a313c` | `border-border` | Visible borders |
| `--color-border-subtle` | `#22272f` | `border-border-subtle` | Dividers, card borders |

### Text (WCAG AA on `bg-ground`)
| Token | Hex | Tailwind class | Ratio |
|-------|-----|----------------|-------|
| `--color-fg` | `#eef0f3` | `text-fg` | ~16.9:1 |
| `--color-fg-dim` | `#8b939c` | `text-fg-dim` | ~6.2:1 |

### Accent
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-accent` | `#e3b341` | `text-accent` | Brand, CTA, highlights |
| `--color-accent-alt` | `#e3b341` | `text-accent-alt` | Interactive, links (kini sama dengan `accent`) |

### Status
| Token | Hex | Tailwind class | Usage |
|-------|-----|----------------|-------|
| `--color-success` | `#43a57d` | `text-success` | Positive states |
| `--color-error` | `#d65a5a` | `text-error` | Errors, destructive |
| `--color-warning` | `#e3b341` | `text-warning` | Warnings (sama dengan `accent`) |
| `--color-info` | `#5b8fbd` | `text-info` | Informational |

## Token Usage in Components

Migrasi ke semantic token belum 100%; sebagian komponen masih memakai kelas palet mentah
(`slate-*`, `indigo-*`). Padanan yang dituju:

| Pattern | Raw Tailwind | Semantic Token |
|---------|-------------|----------------|
| Page background | `bg-slate-950` | `bg-ground` |
| Card surface | `bg-slate-900 border border-slate-800` | `bg-surface border border-border-subtle` |
| Elevated surface | `bg-slate-800 border border-slate-700` | `bg-elevated border border-border` |
| Body text | `text-slate-100` | `text-fg` |
| Dimmed text | `text-slate-400` | `text-fg-dim` |
| Brand accent | `text-yellow-400` | `text-accent` |
| Interactive | `text-indigo-400` | `text-accent-alt` |

## Typography Scale

| Level | Classes | Usage |
|-------|---------|-------|
| Page Title | `text-xl sm:text-2xl font-bold text-white` | H2 headings |
| Section Title | `text-sm font-semibold text-white` | Sub-sections |
| Body | `text-sm text-fg-dim` | Descriptions |
| Label | `text-xs text-fg-dim` | Form labels |
| Meta | `text-[10px] font-mono text-fg-dim uppercase` | Timestamps, badges |
| Micro | `text-[8px] text-fg-dim` | Tiebreaker info |

## Spacing & Radius

| Value | Tailwind | Usage |
|-------|----------|-------|
| `1rem` | `rounded-2xl` / `p-4` | Cards |
| `0.75rem` | `rounded-xl` | Buttons |
| `0.5rem` | `rounded-lg` | Chips, inputs |
| `1.5rem` | `gap-6` | Section gaps |

## Component Patterns

Components follow the semantic token system. Key patterns:

- **Cards** use `bg-surface border border-border-subtle rounded-2xl p-4`
- **Chips** use `bg-elevated border border-border rounded-lg` with variant colors
- **Badges** use inline styling with status colors (`success`, `error`, `warning`, `info`)
- **Empty states** use centered layout with icon + title + description

## Button Variants (inline)

| Variant | Classes |
|---------|---------|
| Primary | `bg-accent text-ground font-semibold rounded-xl min-h-11 px-4` |
| Secondary | `border border-border text-fg hover:bg-elevated rounded-xl min-h-11 px-4` |
| Danger | `border border-border text-error hover:bg-elevated rounded-xl min-h-11 px-4` |
| Icon-only | `min-h-11 min-w-11 inline-flex items-center justify-center rounded-lg text-fg-dim` |

Legacy screens still spell the primary CTA as `bg-indigo-400 text-slate-950`. The
palette remap in `index.css` renders that as `accent`, so the difference is
naming, not colour; migration is cosmetic and can wait.

Dense rows (the played toggle, tournament camera buttons) keep a 24-32px visual
box and expand the hit area with `hit44` from
`apps/web/src/legacy/components/hitTarget.ts`.

## Form Patterns

```tsx
// Input and Select share one recipe; components/Field.tsx owns it.
className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3
  text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent
  disabled:opacity-60"

// The control is the child of a <label>. That is what gives it an accessible
// name, so there is no id/htmlFor plumbing.
```

## Overlay (bottom sheet)

Satu primitive, satu varian. `apps/web/src/components/Overlay.tsx` adalah satu-satunya
shell untuk dialog modal; pemakaian baru mengimpor komponen ini, bukan menyalin
`fixed inset-0` lagi. Test-nya di `Overlay.test.tsx`.

### Props

| Prop | Tipe | Default | Keterangan |
|------|------|---------|------------|
| `onClose` | `() => void` | wajib | Dipanggil oleh Escape, tap scrim, dan tombol ✕ |
| `title` | `ReactNode` | wajib | Dirender sebagai `<h2 id>`, jadi nama dialog datang dari judul |
| `description` | `ReactNode` | - | `<p>` di bawah judul |
| `children` | `ReactNode` | wajib | Isi sheet; satu-satunya area yang scroll |
| `footer` | `ReactNode` | - | Aksi di bawah, di dalam area aman |
| `dismissible` | `boolean` | `true` | `false` saat saving: Escape dan scrim diabaikan, ✕ tidak dirender |
| `labelledBy` | `string` | - | Escape hatch bila heading kustom dirender di dalam `children`; `<h2>` bawaan tidak dirender |

### Class recipe

```tsx
scrim  : fixed inset-0 z-50 flex items-end justify-center bg-black/60
sheet  : relative flex w-full max-w-lg max-h-dvh flex-col overflow-hidden
         rounded-t-3xl border-t border-border-subtle bg-surface pb-[max(0.75rem,env(safe-area-inset-bottom))]
         shadow-2xl
handle : mx-auto mt-3 mb-1 h-1 w-10 shrink-0 rounded-full bg-border
header : shrink-0 px-5 pt-3 pb-2            (h2 text-base font-bold text-fg)
body   : min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pb-4
footer : shrink-0 border-t border-border-subtle px-5 pt-3   (tanpa padding bawah)
close  : absolute right-2 top-2 inline-flex min-h-11 min-w-11 items-center justify-center
         rounded-lg text-fg-dim hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent
```

Root tanpa padding supaya sheet setinggi layar tetap mulai di y=0. `max-h-dvh` +
`min-h-0` + `flex-1 overflow-y-auto` adalah satu-satunya pola yang membatasi tinggi di HP
sekaligus menyisakan area scroll. Semua nilai adalah utility stok; satu-satunya arbitrary
value adalah `pb-[max(0.75rem,env(safe-area-inset-bottom))]` yang diizinkan
`scripts/check-tailwind-arbitrary.mjs`.

### Satu varian

Tidak ada varian `center` dan tidak ada varian full-screen. Di 402x874 dialog center
membuat footer masuk ke area home indicator, dan begitu keyboard iOS terbuka tombol
konfirmasi tertutup tanpa container scroll untuk menyelamatkannya. Full-screen adalah
halaman, bukan dialog (lihat daftar di bawah).

### Perilaku

| Perilaku | Implementasi |
|---|---|
| Focus trap + restore | `useFocusTrap(sheetRef)` dari `legacy/hooks/` |
| Escape | `useEscapeKey(onClose, dismissible)`; stack global di hook memastikan hanya overlay teratas yang menang, dan `dismissible: false` melepas listener |
| Tap scrim | `pointerdown` mencatat apakah gestur dimulai di scrim; klik hanya menutup bila mulai dan berakhir di scrim, jadi drag-select dari body tidak menutup sheet |
| Body scroll lock | Counter modul: overlay pertama menyetel `body` ke `position: fixed`, `top: -scrollY`, `width: 100%`, `overflow: hidden`; overlay terakhir mengembalikan style sebelumnya dan `scrollTo` posisi lama. `overflow: hidden` saja tidak dihormati iOS |
| Safe area | `pb-[max(0.75rem,env(safe-area-inset-bottom))]` dipasang sekali di sheet, bukan di footer. Footerless sheet (#4, #11, #15) ikut berhenti di atas home indicator; footer tidak boleh mengulang padding itu |
| Keyboard clamp | `useEffect` membaca `window.visualViewport` (feature-detected) dan menulis inline `maxHeight = viewport.height - 16` saat resize/scroll, lalu menghapusnya saat unmount |
| Semantik | `role="dialog"`, `aria-modal="true"`, `aria-labelledby` dari `<h2 id>` (atau `labelledBy`); ✕ adalah target 44px dengan label dari `common.close` |
| Non-dismissible | Saat `dismissible` false, ✕ tidak dirender sama sekali, bukan dirender disabled |

### Yang tetap di luar primitive

| Permukaan | Alasan |
|---|---|
| ActionsMenu (#14), menu akun HomeLayout (#16) | `role="menu"`, non-modal, tidak boleh scroll-lock atau trap (Tab keluar menu itu sah), dan harus tetap dekat trigger |
| ConfirmBars (#13), discard confirm scoreboard (#20) | Bukan dialog: tidak punya siklus buka/tutup, sengaja tidak menutupi layar, dan tingginya dikompensasi konten di belakangnya. Yang perlu ditambah hanya Esc dan `aria-live` |
| Tooltip `AnnotatedPlayerName` (#17) | Tidak punya dismissal, `pointer-events-none` |
| Toast `ErrorBanner` (#18) | `role="alert"`, tidak punya lifecycle buka/tutup |
| Scoreboard surface (#19) | Bukan dialog: permukaan landscape yang dirotasi, tap-zone skor, tanpa judul, tanpa scrim, tanpa scroll lock |
| SummaryModal mode `standalone` (#10) | Halaman, bukan overlay; hanya jalur non-standalone yang memakai primitive |

Catatan koreksi: resep audit menaruh padding safe-area di footer. Mockup menunjukkan
sheet tanpa footer (#4, #11, #15) juga harus berhenti di atas home indicator, jadi
primitive yang memiliki padding itu sekali di container sheet. Itu sebabnya footer tidak
lagi memuat `pb-[max(...)]`.

## Accessibility (Mobile PWA)

| Rule | Implementation |
|------|---------------|
| Focus rings | `focus-visible:ring-2` (NOT `focus:ring`) — no tap flash |
| Touch targets | ≥44px for interactive elements |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` |
| Screen readers | `aria-label` on icon buttons, `role="dialog"` on modals |
| Error text | `role="alert"` only. Adding `aria-live` on top is redundant and is documented as wrong in `legacy/components/ErrorBanner.tsx` |
| Keyboard nav | `role="button" tabIndex={0}` on score tap zones |
| Menu | `role="menu"` / `role="menuitem"` on ActionsMenu |

## File Locations

Paths relatif terhadap `apps/web/`:

| Resource | Path |
|----------|------|
| CSS tokens (`@theme`) | `src/index.css` |
| Tier config | `src/config/tiers.ts` |
| Canvas config | `src/config/canvas.ts` |
| Generator config | `src/config/generator.ts` |
| Achievement config | `src/config/achievements.ts` |
