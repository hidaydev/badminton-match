import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { t } from '../i18n'
import Icon from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { PAGE_COLUMN } from '../components/Page'
import { SkipLink } from '../components/SkipLink'
import { usePageTitle } from '../hooks/usePageTitle'
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
 *
 * It stays outside `HomeLayout` because it has to work before the account has a
 * membership, so this file owns the three things that layout provides: the skip
 * link, the sticky header with a way back, and the top safe-area inset.
 */
export default function DirectoryPage() {
  const { current } = useCommunity()
  const [slug, setSlug] = useState('')
  const navigate = useNavigate()
  usePageTitle('directory.page.title')

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <SkipLink />
      <header className="sticky top-0 z-10 border-b border-border-subtle bg-surface pt-[env(safe-area-inset-top)]">
        <div className={`flex ${PAGE_COLUMN} items-center gap-2 py-2.5`}>
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="-ml-1.5 -my-1.5 h-11 w-11 shrink-0 flex items-center justify-center rounded-lg text-fg-dim transition-[color,transform] hover:text-fg active:scale-90"
            aria-label={t('shell.back')}
          >
            <Icon name="chevron-left" size={18} />
          </button>
          <Link to="/" className="flex items-center gap-2">
            <img src="/logo-192.png" alt="" className="h-6 w-6 shrink-0 object-contain" />
            <span className="text-sm font-bold tracking-tight text-fg">{t('shell.brand')}</span>
          </Link>
        </div>
      </header>
      <main
        id="main"
        className={`flex-1 ${PAGE_COLUMN} py-4 pb-[calc(1rem+env(safe-area-inset-bottom))]`}
      >
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
    </div>
  )
}
