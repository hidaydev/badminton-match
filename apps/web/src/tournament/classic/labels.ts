// Labels shared by the classic editor. Every visible word comes from `t()`;
// only ids, names and scores are interpolated.

import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'
import type { ClassicMatch, ClassicPhase } from '../types'

const PHASE_KEYS: Record<ClassicPhase, MessageKey> = {
  group: 'classic.phase.group',
  qf: 'classic.phase.qf',
  sf: 'classic.phase.sf',
  '3rd': 'classic.phase.3rd',
  final: 'classic.phase.final',
}

/** group-A-0 -> 1, qf-3 -> 3, final-1 -> 1. */
function matchNumber(id: string): number {
  const suffix = /-(\d+)$/.exec(id)
  if (suffix === null) return 1
  return Number(suffix[1]) + (id.startsWith('group-') ? 1 : 0)
}

/** "Group A · Match 1" / "Quarterfinal 2" / "Final 1". */
export function matchLabel(match: ClassicMatch): string {
  const number = matchNumber(match.id)
  if (match.phase === 'group' && match.groupId !== null) {
    return `${t('classic.group', { group: match.groupId })} · ${t('classic.match')} ${number}`
  }
  return `${t(PHASE_KEYS[match.phase])} ${number}`
}

export function phaseLabel(phase: ClassicPhase): string {
  return t(PHASE_KEYS[phase])
}
