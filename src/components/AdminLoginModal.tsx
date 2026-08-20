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

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!tokenInput.trim()) {
      setError('Please enter a password.')
      return
    }
    if (login(tokenInput)) {
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
          onChange={(e) => { setTokenInput(e.target.value); setError(null) }}
          placeholder="Admin password"
          className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm font-mono text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
        />
        {error && <p className="text-[11px] text-red-400">{error}</p>}
        <div className="flex gap-2">
          <button type="submit" className="flex-1 py-2.5 rounded-lg bg-accent text-slate-950 text-sm font-bold">
            Login
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
