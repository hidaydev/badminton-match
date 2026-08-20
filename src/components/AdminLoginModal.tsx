// src/components/AdminLoginModal.tsx — Login modal admin (dipanggil dari header icon).
import { useState } from 'react'
import { useAdmin } from '../context/AdminContext'

interface AdminLoginModalProps {
  open: boolean
  onClose: () => void
}

export default function AdminLoginModal({ open, onClose }: AdminLoginModalProps) {
  const { login } = useAdmin()
  const [tokenInput, setTokenInput] = useState('')

  if (!open) return null

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (login(tokenInput)) {
      setTokenInput('')
      onClose()
    }
  }

  return (
    <div className="fixed inset-0 z-60 flex items-center justify-center bg-black/60 p-4" onClick={onClose}>
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
          onChange={(e) => setTokenInput(e.target.value)}
          placeholder="Admin password"
          className="bg-elevated border border-border rounded-lg px-3 py-2.5 text-sm font-mono text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
        />
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
