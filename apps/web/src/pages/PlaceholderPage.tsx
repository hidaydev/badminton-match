import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'

export default function PlaceholderPage({ labelKey }: { labelKey: MessageKey }) {
  return (
    <section className="mx-auto max-w-2xl p-4">
      <h1 className="text-xl sm:text-2xl font-bold text-fg">{t(labelKey)}</h1>
      <p className="mt-2 text-sm text-fg-dim">
        {t('placeholder.description', { feature: t(labelKey) })}
      </p>
    </section>
  )
}
