import { Component, type ReactNode, type ErrorInfo } from 'react'
import { isChunkLoadError } from '../utils/safeLazy'

interface Props {
  children: ReactNode
  /** Fallback UI override — default: error card dengan tombol reload. */
  fallback?: ReactNode
  /** Diisi bila boundary hanya mengcover satu route — dipakai untuk label di log. */
  routeName?: string
}

interface State {
  error: Error | null
}

/**
 * ErrorBoundary — catch React render errors agar satu component yang crash
 * tidak membunuh seluruh app. Class component karena hooks belum support
 * getDerivedStateFromError / componentDidCatch.
 *
 * Penggunaan:
 *   <ErrorBoundary>
 *     <SomePage />
 *   </ErrorBoundary>
 */
export default class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props)
    this.state = { error: null }
  }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Log untuk debugging — tidak kirim ke external service (privacy-safe).
    console.error('[ErrorBoundary]', this.props.routeName ?? 'unknown', error, info.componentStack)
  }

  handleReset = () => {
    this.setState({ error: null })
  }

  render() {
    if (this.state.error) {
      if (this.props.fallback) return this.props.fallback

      const isChunkErr = isChunkLoadError(this.state.error)

      return (
        <div className="flex flex-col items-center justify-center min-h-screen px-6 text-center gap-4">
          <div className="text-3xl">{isChunkErr ? '🔄' : '⚠️'}</div>
          <div>
            <p className="text-fg font-semibold text-sm mb-1">
              {isChunkErr ? 'App Version Updated' : 'Something went wrong'}
            </p>
            <p className="text-fg-dim text-xs max-w-xs">
              {isChunkErr
                ? 'A new version of the app is available on the server. Please reload the page to get the latest version.'
                : this.state.error.message || 'Unexpected error — try reloading the page.'}
            </p>
          </div>
          <div className="flex gap-2">
            {!isChunkErr && (
              <button
                onClick={this.handleReset}
                className="text-xs px-3 py-1.5 rounded-lg bg-elevated hover:bg-border text-fg transition-colors"
              >
                Try again
              </button>
            )}
            <button
              onClick={() => window.location.reload()}
              className="text-xs px-3 py-1.5 rounded-lg bg-accent/20 hover:bg-accent/30 text-accent transition-colors font-semibold"
            >
              Reload page
            </button>
          </div>
        </div>
      )
    }

    return this.props.children
  }
}
