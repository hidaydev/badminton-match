// The sheet lives in `@majadu/scoreboard-ui` so the web app and the PWA open
// the same dialog, with the same focus trap, Escape handling and scroll lock.
// Kept at this path for the nine existing call sites.
export { Overlay } from '@majadu/scoreboard-ui'
export type { OverlayProps } from '@majadu/scoreboard-ui'
