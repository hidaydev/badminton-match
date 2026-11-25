import { useState } from 'react'
import { Link } from 'react-router-dom'
import { t } from '../i18n'
import { PageHeader } from '../components/PageHeader'
import { PAGE_COLUMN } from '../components/Page'
import { useCommunity } from './CommunityContext'
import { DirectoryList } from './DirectoryList'
import { JoinRequestCard } from './JoinRequestCard'

/**
 * The public directory reached from the account menu. It exists for every
 * signed-in account, including one that already belongs to a community: the
 * empty-state screen only shows it to an account with no membership yet.
 *
 * The list is opt-in at the community level, so no entries is a normal answer,
 * not an error; the slug form stays usable either way.
 */
export default function DirectoryPage() {
  const { current } = useCommunity()
  const [slug, setSlug] = useState('')

  return (
    <main className={`${PAGE_COLUMN} py-4 pb-[calc(1rem+env(safe-area-inset-bottom))]`}>
      <PageHeader title={t('directory.page.title')} subtitle={t('directory.page.subtitle')} />

      <DirectoryList onPick={setSlug} />
      <JoinRequestCard slug={slug} onSlugChange={setSlug} />

      {current !== null && (
        <p className="mt-6 text-sm">
          <Link
            to={`/c/${encodeURIComponent(current.slug)}`}
            className="inline-flex min-h-11 items-center text-accent hover:underline focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('directory.page.back', { name: current.name })}
          </Link>
        </p>
      )}
    </main>
  )
}
