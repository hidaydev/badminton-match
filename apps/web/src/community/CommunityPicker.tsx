import { t } from '../i18n'
import { useCommunity } from './CommunityContext'

/**
 * Small switch in the shell. It renders nothing without a membership, so the
 * signed-out and freshly-invited views stay uncluttered.
 */
export default function CommunityPicker() {
  const { memberships, current, select } = useCommunity()

  if (memberships.length === 0) return null

  return (
    <div className="flex items-center gap-2">
      <label htmlFor="community-picker" className="text-xs text-fg-dim">
        {t('community.label')}
      </label>
      <select
        id="community-picker"
        value={current?.slug ?? ''}
        onChange={(event) => select(event.target.value)}
        className="min-h-11 rounded-xl bg-elevated border border-border px-2 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
      >
        {memberships.map((membership) => (
          <option key={membership.id} value={membership.slug}>
            {membership.name}
          </option>
        ))}
      </select>
    </div>
  )
}
