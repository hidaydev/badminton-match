import type { ScoreboardLabels } from '@majadu/scoreboard-ui'

// The scoreboard has no i18n layer of its own, so every string it renders
// comes from here and reaches the components as props.
export const SCOREBOARD_LABELS: ScoreboardLabels = {
  red: {
    displayName: 'RED',
    placeholder: 'RED',
    teamName: 'Red team name',
    decrease: 'Decrease red score',
    tapToScore: 'tap to score',
    score: (displayName, score) => `${displayName}, ${score}, tap to score`,
  },
  blue: {
    displayName: 'BLUE',
    placeholder: 'BLUE',
    teamName: 'Blue team name',
    decrease: 'Decrease blue score',
    tapToScore: 'tap to score',
    score: (displayName, score) => `${displayName}, ${score}, tap to score`,
  },
  reset: 'Reset scores',
  swap: 'Swap sides',
  exportMatch: 'Export match',
  fullscreenEnter: 'Enter fullscreen',
  fullscreenExit: 'Exit fullscreen',
  close: 'Close',
  home: 'Back to home',
  save: 'Save score',
  saving: 'Saving',
  discardPrompt: 'Discard score?',
  discard: 'Discard',
  keepScoring: 'Keep scoring',
}
