import { Link } from 'react-router-dom'
import type { ReactNode } from 'react'
import { t } from '../i18n'

const SECURITY_ADVISORY =
  'https://github.com/hidaydev/badminton-match/security/advisories/new'

function Section({
  id,
  title,
  children,
}: {
  id: string
  title: string
  children: ReactNode
}) {
  return (
    <section aria-labelledby={id}>
      <h2 id={id} className="text-sm font-semibold text-fg">
        {title}
      </h2>
      <div className="mt-2 space-y-2 text-sm leading-relaxed text-fg-dim">
        {children}
      </div>
    </section>
  )
}

/** Public terms of service. Plain language, no legal entity invented. */
export default function TermsPage() {
  return (
    <main className="min-h-screen bg-ground text-fg">
      <article className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
        <Link
          to="/"
          className="inline-flex min-h-11 items-center rounded-lg text-sm text-fg-dim hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('terms.back')}
        </Link>

        <h1 className="mt-2 text-2xl font-bold tracking-tight text-fg">
          {t('terms.title')}
        </h1>
        <p className="mt-1 font-mono text-xs uppercase tracking-wide text-fg-dim">
          {t('terms.updated')}
        </p>

        <p className="mt-6 text-sm leading-relaxed text-fg-dim">
          {t('terms.intro')}
        </p>

        <div className="mt-8 space-y-8">
          <Section id="what-this-is" title={t('terms.service.heading')}>
            <p>{t('terms.service.body1')}</p>
            <p>{t('terms.service.body2')}</p>
          </Section>

          <Section id="your-account" title={t('terms.account.heading')}>
            <p>{t('terms.account.body1')}</p>
            <p>{t('terms.account.body2')}</p>
            <p>{t('terms.account.age')}</p>
          </Section>

          <Section id="acceptable-use" title={t('terms.use.heading')}>
            <p>{t('terms.use.intro')}</p>
            <ul className="list-disc space-y-1 pl-5">
              <li>{t('terms.use.share')}</li>
              <li>{t('terms.use.others')}</li>
              <li>{t('terms.use.abuse')}</li>
              <li>{t('terms.use.boundaries')}</li>
              <li>{t('terms.use.illegal')}</li>
            </ul>
            <p>{t('terms.use.security')}</p>
          </Section>

          <Section id="community-admins" title={t('terms.admins.heading')}>
            <p>{t('terms.admins.body1')}</p>
            <p>{t('terms.admins.body2')}</p>
          </Section>

          <Section id="your-content" title={t('terms.content.heading')}>
            <p>{t('terms.content.body1')}</p>
            <p>{t('terms.content.body2')}</p>
          </Section>

          <Section id="ratings" title={t('terms.ratings.heading')}>
            <p>{t('terms.ratings.body1')}</p>
            <p>{t('terms.ratings.body2')}</p>
          </Section>

          <Section id="availability" title={t('terms.availability.heading')}>
            <p>{t('terms.availability.body1')}</p>
            <p>{t('terms.availability.body2')}</p>
          </Section>

          <Section id="termination" title={t('terms.termination.heading')}>
            <p>{t('terms.termination.body1')}</p>
            <p>{t('terms.termination.body2')}</p>
          </Section>

          <Section id="liability" title={t('terms.liability.heading')}>
            <p>{t('terms.liability.body1')}</p>
            <p>{t('terms.liability.body2')}</p>
          </Section>

          <Section id="changes" title={t('terms.changes.heading')}>
            <p>{t('terms.changes.body')}</p>
            <p>
              {t('terms.changes.contactPrefix')}{' '}
              <a
                href="mailto:hello@qouver.com"
                className="text-accent underline underline-offset-2 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent"
              >
                {t('terms.changes.contactEmail')}
              </a>
              . {t('terms.changes.contactSuffix')}
            </p>
            <p>
              {t('terms.changes.securityPrefix')}{' '}
              <a
                href={SECURITY_ADVISORY}
                target="_blank"
                rel="noreferrer"
                className="text-accent underline underline-offset-2 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent"
              >
                {t('terms.changes.securityLink')}
              </a>
              . {t('terms.changes.securitySuffix')}
            </p>
          </Section>
        </div>
      </article>
    </main>
  )
}