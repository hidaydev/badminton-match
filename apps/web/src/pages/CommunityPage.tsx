import { useParams } from 'react-router-dom'
import { useCommunity } from '../community/CommunityContext'
import type { CommunityConfigEntry } from '../community/api'
import { useCommunityConfig } from '../community/useCommunityConfig'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'

/** Community-scoped registry keys, in the order members read them. */
const SETTING_KEYS = [
  'community.default_timezone',
  'community.directory_enabled',
  'community.invite_ttl_days',
  'community.join_requests_enabled',
] as const

type SettingKey = (typeof SETTING_KEYS)[number]

const SETTING_LABELS: Record<SettingKey, MessageKey> = {
  'community.default_timezone': 'community.setting.timezone',
  'community.directory_enabled': 'community.setting.directory',
  'community.invite_ttl_days': 'community.setting.inviteTtl',
  'community.join_requests_enabled': 'community.setting.joinRequests',
}

function formatValue(value: unknown): string {
  if (typeof value === 'boolean') {
    return value ? t('community.value.enabled') : t('community.value.disabled')
  }
  if (typeof value === 'string' || typeof value === 'number') return String(value)
  return JSON.stringify(value) ?? ''
}

function sourceLabel(source: CommunityConfigEntry['source']): MessageKey {
  return source === 'community'
    ? 'community.source.community'
    : 'community.source.platform'
}

export default function CommunityPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null
  const { config, loading, error } = useCommunityConfig(slug === '' ? null : slug)

  const rows = SETTING_KEYS.flatMap((key) => {
    const entry = config?.[key]
    return entry ? [{ key, entry }] : []
  })

  return (
    <section className="mx-auto max-w-2xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{membership?.name ?? slug}</h1>
      {membership && (
        <p className="mt-1 text-sm text-fg-dim">
          {t('community.role', { role: t(`role.${membership.role}`) })}
        </p>
      )}
      <p className="mt-2 text-sm text-fg-dim">{t('community.subtitle')}</p>

      <h2 className="mt-6 text-sm font-semibold text-fg">{t('community.settings')}</h2>

      {loading && <p className="mt-3 text-sm text-fg-dim">{t('app.loading')}</p>}

      {error === 'notFound' && (
        <p role="alert" aria-live="polite" className="mt-3 text-sm text-error">
          {t('community.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" aria-live="polite" className="mt-3 text-sm text-error">
          {t('community.error.load')}
        </p>
      )}

      {config && rows.length === 0 && (
        <p className="mt-3 text-sm text-fg-dim">{t('community.settingsEmpty')}</p>
      )}

      {config && rows.length > 0 && (
        <dl className="mt-3 divide-y divide-border-subtle rounded-2xl border border-border-subtle bg-surface px-4">
          {rows.map(({ key, entry }) => (
            <div key={key} className="flex flex-wrap items-baseline justify-between gap-2 py-3">
              <dt className="text-sm text-fg">{t(SETTING_LABELS[key])}</dt>
              <dd className="flex items-center gap-2 text-sm text-fg-dim">
                <span className="font-mono">{formatValue(entry.value)}</span>
                <span className="rounded-lg border border-border bg-elevated px-2 py-0.5 text-xs">
                  {t(sourceLabel(entry.source))}
                </span>
              </dd>
            </div>
          ))}
        </dl>
      )}
    </section>
  )
}
