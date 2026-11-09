import { t } from '../i18n'
import type { ScoreboardLabels } from '@majadu/scoreboard-ui'

/**
 * The web scoreboard's labels, resolved from the dictionary once per render.
 * The shared components receive them as props, so they never import `t`.
 */
export function scoreboardLabels(): ScoreboardLabels {
  return {
    red: {
      displayName: t('scoreboard.side.red'),
      placeholder: 'RED',
      teamName: t('scoreboard.teamName', { side: t('scoreboard.side.red') }),
      decrease: t('scoreboard.decrease', { side: t('scoreboard.side.red') }),
      tapToScore: t('scoreboard.tapToScore'),
      // The side name, not the team name: the label names which half of the
      // board the button belongs to, matching the pre-extraction behaviour.
      score: (_displayName, score) =>
        t('scoreboard.score', { side: t('scoreboard.side.red'), score }),
    },
    blue: {
      displayName: t('scoreboard.side.blue'),
      placeholder: 'BLUE',
      teamName: t('scoreboard.teamName', { side: t('scoreboard.side.blue') }),
      decrease: t('scoreboard.decrease', { side: t('scoreboard.side.blue') }),
      tapToScore: t('scoreboard.tapToScore'),
      // The side name, not the team name: the label names which half of the
      // board the button belongs to, matching the pre-extraction behaviour.
      score: (_displayName, score) =>
        t('scoreboard.score', { side: t('scoreboard.side.blue'), score }),
    },
    reset: t('scoreboard.reset'),
    swap: t('scoreboard.swap'),
    exportMatch: 'Export match',
    fullscreenEnter: t('scoreboard.fullscreenEnter'),
    fullscreenExit: t('scoreboard.fullscreenExit'),
    close: t('scoreboard.close'),
    home: t('scoreboard.home'),
    save: 'Save Score',
    saving: 'Saving…',
    discardPrompt: 'Discard score?',
    discard: 'Discard',
    keepScoring: 'Keep scoring',
  }
}
