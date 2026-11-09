import { Component } from 'react'
import type { ErrorInfo, ReactNode } from 'react'

interface ErrorBoundaryProps {
  children: ReactNode
  /** Injectable in tests; the real one reloads the document. */
  onRetry?: () => void
}

interface ErrorBoundaryState {
  failed: boolean
}

// PWA-05: a thrown error inside the tree would otherwise blank the dark page
// mid-match with no way back. The scoreboard owns no routing, so this is the
// whole recovery surface: say it failed and offer a reload.
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { failed: false }

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { failed: true }
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    // Keep the stack in the console; the screen must stay readable.
    console.error('scoreboard crashed', error, info.componentStack)
  }

  private retry = () => {
    if (this.props.onRetry) this.props.onRetry()
    else window.location.reload()
  }

  render() {
    if (!this.state.failed) return this.props.children
    return (
      <main className="flex flex-col items-center justify-center h-dvh gap-4 bg-[#020617] text-white px-6 text-center select-none">
        <h1 className="text-xl font-bold">Scoreboard stopped</h1>
        <p className="text-sm text-white/70">
          The scores stored on this device are safe. Reload to continue.
        </p>
        <button
          type="button"
          onClick={this.retry}
          className="px-5 min-h-11 rounded-lg text-sm font-bold text-slate-900 bg-white cursor-pointer active:opacity-80"
        >
          Reload
        </button>
      </main>
    )
  }
}
