import { t } from '../i18n'
import { Select } from '../components/Field'
import { useCommunity } from './CommunityContext'

/**
 * Small switch in the shell. It renders nothing without a membership, so the
 * signed-out and freshly-invited views stay uncluttered.
 */
export function CommunityPicker() {
  const { memberships, current, select } = useCommunity()

  if (memberships.length === 0) return null

  return (
    <div className="flex items-center gap-2">
      <label htmlFor="community-picker" className="text-xs text-fg-dim">
        {t('community.label')}
      </label>
      <Select
        id="community-picker"
        value={current?.slug ?? ''}
        onChange={(event) => select(event.target.value)}
        className="w-auto"
      >
        {memberships.map((membership) => (
          <option key={membership.id} value={membership.slug}>
            {membership.name}
          </option>
        ))}
      </Select>
    </div>
  )
}
