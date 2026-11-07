import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { t } from '../i18n'

/** The Google mark, drawn once so the button needs no network request. */
function GoogleMark() {
  return (
    <svg viewBox="0 0 48 48" className="h-[18px] w-[18px]" aria-hidden="true" focusable="false">
      <path
        fill="#EA4335"
        d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"
      />
      <path
        fill="#4285F4"
        d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"
      />
      <path
        fill="#FBBC05"
        d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"
      />
      <path
        fill="#34A853"
        d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"
      />
    </svg>
  )
}

export default function LoginPage() {
  const { login, loggingIn } = useAuth()
  const [failed, setFailed] = useState(false)

  const onLogin = async () => {
    setFailed(false)
    try {
      await login()
    } catch {
      setFailed(true)
    }
  }

  return (
    <main className="min-h-screen bg-ground text-fg">
      <div className="mx-auto flex min-h-screen w-full max-w-sm flex-col justify-center px-5 py-12">
        <img
          src="/majadu-logo.png"
          alt=""
          width={94}
          height={132}
          className="mx-auto h-[132px] w-auto"
        />

        <h1 className="mt-7 text-center text-2xl font-semibold tracking-tight text-fg">
          {t('login.title')}
        </h1>
        <p className="mt-3 text-center text-sm leading-relaxed text-fg-dim">
          {t('login.description')}
        </p>

        <button
          type="button"
          onClick={() => void onLogin()}
          disabled={loggingIn}
          className="mt-8 flex w-full min-h-12 items-center justify-center gap-3 rounded-xl bg-accent px-4 py-3 font-semibold text-ground hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-ground disabled:opacity-40"
        >
          <GoogleMark />
          {loggingIn ? t('login.pending') : t('login.action')}
        </button>

        {failed && (
          <p role="alert" aria-live="polite" className="mt-4 text-center text-sm text-error">
            {t('login.error')}
          </p>
        )}

        <p className="mt-4 text-center text-xs leading-relaxed text-fg-dim">
          {t('login.account')}
        </p>

        <footer
          aria-label={t('login.legalNav')}
          className="mt-10 flex items-center justify-center gap-2 text-xs text-fg-dim"
        >
          <Link
            to="/privacy"
            className="inline-flex min-h-11 items-center rounded-lg px-1 hover:text-fg focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-ground"
          >
            {t('login.privacy')}
          </Link>
          <span aria-hidden="true">·</span>
          <Link
            to="/terms"
            className="inline-flex min-h-11 items-center rounded-lg px-1 hover:text-fg focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-ground"
          >
            {t('login.terms')}
          </Link>
        </footer>
      </div>
    </main>
  )
}