import { Link } from 'react-router-dom'
import { t } from '../i18n'

/**
 * Public privacy policy. It sits outside the auth gate and never calls the API:
 * the page describes the data the rest of the application actually stores.
 */
export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-ground text-fg p-4 sm:p-6">
      <article className="mx-auto w-full max-w-3xl pb-12">
        <h1 className="text-2xl font-bold text-fg sm:text-3xl">{t('privacy.title')}</h1>
        <p className="mt-2 text-sm text-fg-dim">{t('privacy.updated')}</p>

        <p className="mt-6 text-sm leading-relaxed text-fg-dim">{t('privacy.intro')}</p>

        <h2 className="mt-8 text-lg font-semibold text-fg">{t('privacy.data.heading')}</h2>
        <ul className="mt-2 list-disc space-y-2 pl-5 text-sm leading-relaxed text-fg-dim">
          <li>{t('privacy.data.account')}</li>
          <li>{t('privacy.data.community')}</li>
          <li>{t('privacy.data.sessions')}</li>
          <li>{t('privacy.data.ratings')}</li>
          <li>{t('privacy.data.audit')}</li>
          <li>{t('privacy.data.logs')}</li>
        </ul>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.why.heading')}</h3>
        <p className="mt-2 text-sm leading-relaxed text-fg-dim">{t('privacy.why.body')}</p>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.where.heading')}</h3>
        <ul className="mt-2 list-disc space-y-2 pl-5 text-sm leading-relaxed text-fg-dim">
          <li>{t('privacy.where.database')}</li>
          <li>{t('privacy.where.web')}</li>
          <li>{t('privacy.where.dns')}</li>
          <li>{t('privacy.where.google')}</li>
          <li>{t('privacy.where.api')}</li>
        </ul>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.cookies.heading')}</h3>
        <ul className="mt-2 list-disc space-y-2 pl-5 text-sm leading-relaxed text-fg-dim">
          <li>{t('privacy.cookies.session')}</li>
          <li>{t('privacy.cookies.flow')}</li>
          <li>{t('privacy.cookies.local')}</li>
          <li>{t('privacy.cookies.offline')}</li>
          <li>{t('privacy.cookies.thirdParty')}</li>
        </ul>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.share.heading')}</h3>
        <p className="mt-2 text-sm leading-relaxed text-fg-dim">{t('privacy.share.body')}</p>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.retention.heading')}</h3>
        <ul className="mt-2 list-disc space-y-2 pl-5 text-sm leading-relaxed text-fg-dim">
          <li>{t('privacy.retention.sessions')}</li>
          <li>{t('privacy.retention.temporary')}</li>
          <li>{t('privacy.retention.audit')}</li>
          <li>{t('privacy.retention.history')}</li>
          <li>{t('privacy.retention.logs')}</li>
        </ul>
        <p className="mt-3 text-sm leading-relaxed text-fg-dim">{t('privacy.deletion.body')}</p>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.contact.heading')}</h3>
        <p className="mt-2 text-sm leading-relaxed text-fg-dim">
          {t('privacy.contact.body')}{' '}
          <a
            href="mailto:hello@qouver.com"
            className="text-accent underline underline-offset-2 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('privacy.contact.email')}
          </a>
          .
        </p>

        <h3 className="mt-8 text-lg font-semibold text-fg">{t('privacy.changes.heading')}</h3>
        <p className="mt-2 text-sm leading-relaxed text-fg-dim">{t('privacy.changes.body')}</p>

        <Link
          to="/"
          className="mt-8 inline-flex min-h-11 items-center rounded-xl text-sm text-accent hover:underline focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('privacy.back')}
        </Link>
      </article>
    </main>
  )
}