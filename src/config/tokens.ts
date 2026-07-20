/**
 * Design Tokens — Majadu App
 *
 * Central source of truth for colors, spacing, radius, and typography.
 * Keep in sync with @theme in index.css.
 *
 * Tailwind v4 utility mapping:
 *   bg-base, bg-surface, bg-elevated
 *   border-border, border-border-subtle
 *   text-text, text-text-dim
 *   text-accent, text-accent-alt
 *   text-success, text-error, text-warning, text-info
 */

export const tokens = {
  colors: {
    ground: '#0f172a',
    surface: '#1e293b',
    elevated: '#334155',
    border: '#475569',
    borderSubtle: '#334155',
    fg: '#f1f5f9',
    fgDim: '#94a3b8',
    accent: '#fbbf24',
    accentAlt: '#818cf8',
    success: '#34d399',
    error: '#f87171',
    warning: '#fbbf24',
    info: '#38bdf8',
  },
  radius: {
    card: '1rem',
    button: '0.75rem',
    chip: '0.5rem',
    badge: '0.375rem',
    full: '9999px',
  },
} as const
