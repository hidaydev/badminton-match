import { useLocation, useParams } from 'react-router-dom'
import { ButtonLink } from '../components/Button'
import { PageHeader } from '../components/PageHeader'
import { t } from '../i18n'

/**
 * The last route in each branch. It keeps the URL the caller typed: a stale or
 * mistyped deep link is reported instead of being replaced with the community
 * home, which would erase the history entry that produced it.
 */
export default function NotFoundPage() {
  const { pathname } = useLocation()
  const { slug } = useParams<{ slug?: string }>()

  return (
    <section className="mx-auto w-full max-w-3xl px-4 py-4">
      <PageHeader title={t('notFound.title')} subtitle={t('notFound.body', { path: pathname })} />
      <div className="mt-4 flex flex-wrap gap-2">
        {slug !== undefined && (
          <ButtonLink to={`/c/${encodeURIComponent(slug)}`}>
            {t('notFound.communityHome')}
          </ButtonLink>
        )}
        <ButtonLink to="/" variant="secondary">
          {t('nav.home')}
        </ButtonLink>
      </div>
    </section>
  )
}
