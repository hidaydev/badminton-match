// src/components/AdminLoginModal.tsx — Login modal admin (dipanggil dari header icon).
import { useState, useEffect } from 'react'
import { useAdmin } from '../context/AdminContext'

interface AdminLoginModalProps {
  open: boolean
  onClose: () => void
}

export default function AdminLoginModal({ open, onClose }: AdminLoginModalProps) {
  const { login } = useAdmin()
  const [tokenInput, setTokenInput] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [pending, setPending] = useState(false)

  // Escape key to close
  useEffect(() => {
    if (!open) return
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [open, onClose])

  if (!open) return null

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!tokenInput.trim()) {
      setError('Please enter a password.')
      return
    }
    setPending(true)
    setError(null)
    const ok = await login(tokenInput)
    setPending(false)
    if (ok) {
      setTokenInput('')
      setError(null)
      onClose()
    } else {
      setError('Invalid password.')
    }
  }

  // Reset state via key prop — remounts component when open changes
  return (
    <div
      key={open ? 'open' : 'closed'}
      className="fixed inset-0 z-60 flex items-center justify-center bg-black/60 p-4"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label="Admin login"
    >
      <form
        onClick={(e) => e.stopPropagation()}
        onSubmit={handleSubmit}
        className="w-full max-w-sm bg-surface border border-border rounded-xl p-4 flex flex-col gap-3"
      >
        <p className="text-sm font-bold text-fg">Admin login</p>
        <p className="text-[11px] text-fg-dim">Enter the admin password to access operations.</p>
        <input
          autoFocus
          type="password"
          value={tokenInput}
          disabled={pending}
          onChange={(e) => { setTokenInput(e.target.value); setError(null) }}
          placeholder="Admin password"
          className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm font-sans text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none disabled:opacity-50"
        />
        {error && <p className="text-[11px] text-red-400">{error}</p>}
        <div className="flex gap-2">
          <button type="submit" disabled={pending} className="flex-1 py-2.5 rounded-lg bg-accent text-slate-950 text-sm font-bold disabled:opacity-50 flex items-center justify-center gap-2">
            {pending && <svg className="animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>}
            {pending ? 'Verifying...' : 'Login'}
          </button>
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm text-fg-dim hover:text-fg"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
