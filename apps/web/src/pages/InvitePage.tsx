import { settled } from '../api/settled'
import { useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useAuth } from '../auth/AuthContext'
import { acceptInvite } from '../community/api'
import { matchMembershipById } from '../community/membership'
import { Button, ButtonLink } from '../components/Button'
import { Card } from '../components/Card'
import { ErrorText } from '../components/ErrorText'
import { LoadingState } from '../components/LoadingState'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'

const ROLE_LABEL: Record<CommunityRole, MessageKey> = {
  admin: 'role.admin',
  host: 'role.host',
  member: 'role.member',
}

/** The server distinguishes the four ways an invitation cannot be accepted. */
function describe(error: unknown): MessageKey {
  if (error instanceof ApiError) {
    // Match the code first: a 403 here can also be CSRF, and that is not the
    // "wrong account" sentence.
    if (error.code === 'INVITE_EMAIL_MISMATCH') {
      return 'invite.error.emailMismatch'
    }
    if (error.code === 'INVITE_USED') return 'invite.error.used'
    if (error.code === 'INVITE_EXPIRED') return 'invite.error.expired'
    if (error.status === 404 || error.code === 'INVITE_NOT_FOUND') {
      return 'invite.error.notFound'
    }
  }
  return 'invite.error.failed'
}

/**
 * The one screen that turns an invitation token into a membership. It sits
 * outside the community shell on purpose: the account joins here, so it cannot
 * already require membership. Sign-in is the normal OIDC flow, and its
 * `returnTo` is this URL, so the person lands back on the same invitation.
 */
export default function InvitePage() {
  const { token = '' } = useParams<{ token: string }>()
  const { user, loading, loggingIn, login, refreshMemberships } = useAuth()
  const [accepting, setAccepting] = useState(false)
  const [accepted, setAccepted] = useState<CommunityRole | null>(null)
  const [slug, setSlug] = useState<string | null>(null)
  const [error, setError] = useState<MessageKey | null>(null)

  const accept = async () => {
    setAccepting(true)
    setError(null)
    try {
      const result = await acceptInvite(token)
      setAccepted(result.role)
      // The response identifies the community by id only; the refreshed
      // membership list is what turns it into a path the shell accepts.
      try {
        const memberships = await refreshMemberships()
        setSlug(matchMembershipById(memberships, result.communityId)?.slug ?? null)
      } catch {
        setSlug(null)
      }
    } catch (failure) {
      setError(describe(failure))
    } finally {
      setAccepting(false)
    }
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-ground text-fg flex items-center justify-center p-4">
        <div className="w-full max-w-sm">
          <LoadingState label={t('app.loading')} />
        </div>
      </main>
    )
  }

  if (user === null) {
    return (
      <main className="min-h-screen bg-ground text-fg flex items-center justify-center p-4">
        <Card className="w-full max-w-sm p-6">
          <h1 className="text-xl font-bold text-fg">{t('invite.title')}</h1>
          <p className="mt-2 text-sm text-fg-dim">{t('invite.signedOutHint')}</p>
          <Button
            className="mt-6 w-full py-3"
            onClick={() => {
              // Starting the sign-in redirect can fail before the browser leaves.
              settled(login(), 'sign-in failed to start')
            }}
            disabled={loggingIn}
          >
            {loggingIn ? t('login.pending') : t('invite.signIn')}
          </Button>
        </Card>
      </main>
    )
  }

  return (
    <main className="min-h-screen bg-ground text-fg flex items-center justify-center p-4">
      <Card className="w-full max-w-sm p-6">
        <h1 className="text-xl font-bold text-fg">{t('invite.title')}</h1>
        <p className="mt-2 text-sm text-fg-dim">{t('invite.signedInHint')}</p>
        <p className="mt-2 text-xs text-fg-dim">
          {t('invite.signedInAs', { name: user.displayName })}
        </p>

        {accepted === null ? (
          <Button className="mt-6 w-full py-3" onClick={() => accept()} disabled={accepting}>
            {accepting ? t('invite.accepting') : t('invite.accept')}
          </Button>
        ) : (
          <div className="mt-6">
            <p role="status" className="text-sm text-fg">
              {t('invite.accepted', { role: t(ROLE_LABEL[accepted]) })}
            </p>
            <ButtonLink
              to={slug === null ? '/' : `/c/${encodeURIComponent(slug)}`}
              className="mt-4 inline-flex items-center"
            >
              {slug === null ? t('nav.home') : t('invite.open')}
            </ButtonLink>
          </div>
        )}

        {error !== null && (
          <ErrorText className="mt-3">{t(error)}</ErrorText>
        )}
      </Card>
    </main>
  )
}