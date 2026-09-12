// src/config/canvas.ts
// Named constants for canvas drawing — shared across canvasPost.ts and page components.

/** Instagram post width (1080px) */
export const POST_WIDTH = 1080

/** Instagram post height (1080×1350 = 4:5 ratio) */
export const POST_HEIGHT = 1350

/** Header gradient band height */
export const HEADER_H = 90

/** Logo display height */
export const LOGO_H = 28

/** Canvas color palette — single source of truth for canvas drawing */
export const CANVAS_COLORS = {
  /** Primary accent (yellow) */
  accent: '#facc15',
  /** Brand yellow (slightly different from accent) */
  brand: '#F5B400',
  /** Dark background */
  bgDark: '#1e293b',
  /** Muted text / secondary */
  muted: '#64748b',
  /** Border / subtle elements */
  border: '#475569',
  /** Primary text on dark */
  textPrimary: '#e2e8f0',
  /** Dimmed text */
  textDim: '#94a3b8',
  /** Success / positive */
  success: '#4ade80',
  /** Error / negative */
  error: '#f87171',
  /** Warning / bronze */
  warning: '#fb923c',
  /** Silver / 2nd place */
  silver: '#cbd5e1',
  /** White */
  white: '#ffffff',
  /** Black */
  black: '#000000',
  /** Dark text on light */
  darkText: '#111111',
} as const

