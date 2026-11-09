// src/config/canvas.ts
// Named constants for canvas drawing — shared across canvasPost.ts and page components.
import { PALETTE } from '../../theme/palette'

/** Instagram post width (1080px) */
export const POST_WIDTH = 1080

/** Instagram post height (1080×1350 = 4:5 ratio) */
export const POST_HEIGHT = 1350

/** Instagram story width (1080px) */
export const STORY_WIDTH = 1080

/** Instagram story height (1080×1920 = 9:16 ratio) */
export const STORY_HEIGHT = 1920

/** Header gradient band height */
export const HEADER_H = 90

/** Logo display height */
export const LOGO_H = 28

/** Canvas color palette, imported from the app palette so an export matches the app */
export const CANVAS_COLORS = {
  /** Primary accent */
  accent: PALETTE.accent,
  /** Brand colour */
  brand: PALETTE.accent,
  /** Dark background */
  bgDark: PALETTE.surface,
  /** Muted text / secondary */
  muted: PALETTE.fgDim,
  /** Border / subtle elements */
  border: PALETTE.border,
  /** Primary text on dark */
  textPrimary: PALETTE.fg,
  /** Dimmed text */
  textDim: PALETTE.fgDim,
  /** Success / positive */
  success: PALETTE.success,
  /** Error / negative */
  error: PALETTE.error,
  /** Warning / bronze */
  warning: PALETTE.warning,
  /** Silver / 2nd place */
  silver: PALETTE.silver,
  /** White */
  white: PALETTE.white,
  /** Black */
  black: PALETTE.black,
  /** Dark text on light */
  darkText: PALETTE.darkText,
} as const

