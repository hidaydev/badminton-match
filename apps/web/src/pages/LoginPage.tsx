import { useState } from 'react'
import { useAuth } from '../auth/AuthContext'
import { t } from '../i18n'

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
    <main className="min-h-screen bg-ground text-fg flex items-center justify-center p-4">
      <section className="w-full max-w-sm rounded-2xl bg-surface border border-border-subtle p-6">
        <h1 className="text-xl font-bold text-fg">{t('login.title')}</h1>
        <p className="mt-2 text-sm text-fg-dim">{t('login.description')}</p>
        <button
          type="button"
          onClick={() => void onLogin()}
          disabled={loggingIn}
          className="mt-6 w-full min-h-11 rounded-xl bg-accent text-ground font-semibold px-4 py-3 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
        >
          {loggingIn ? t('login.pending') : t('login.action')}
        </button>
        {failed && (
          <p role="alert" aria-live="polite" className="mt-3 text-sm text-error">
            {t('login.error')}
          </p>
        )}
      </section>
    </main>
  )
}
