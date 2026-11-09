import type { MouseEvent } from 'react'

export interface SideLabels {
  /** Shown when the team has no stored name. */
  displayName: string
  /** Placeholder of the name input. */
  placeholder: string
  teamName: string
  decrease: string
  tapToScore: string
  score: (displayName: string, score: number) => string
}

/**
 * Every string the scoreboard renders. The package owns no translation
 * singleton: each app passes its own labels through this one object.
 */
export interface ScoreboardLabels {
  red: SideLabels
  blue: SideLabels
  reset: string
  swap: string
  exportMatch: string
  fullscreenEnter: string
  fullscreenExit: string
  close: string
  home: string
  save: string
  saving: string
  discardPrompt: string
  discard: string
  keepScoring: string
}

export interface ScoreboardSideProps {
  side: 'red' | 'blue'
  labels: SideLabels
  score: number
  displayName: string
  editValue: string
  isEditing: boolean
  isPop: boolean
  isOverlay: boolean
  onScore: () => void
  onMinus: (e: MouseEvent) => void
  onNameChange: (value: string) => void
  onStartEditing: () => void
  onStopEditing: () => void
}

export interface OverlayFooterState {
  pendingClose: boolean
  isSaving: boolean
  onClose: () => void
  onSave: () => void
  onDiscard: () => void
  onKeepScoring: () => void
}
