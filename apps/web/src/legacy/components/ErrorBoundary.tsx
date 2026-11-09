import { Component, Fragment, type ReactNode, type ErrorInfo } from 'react'
import { isChunkLoadError } from '../utils/safeLazy'
import { t } from '../../i18n'

interface Props {
  children: ReactNode
  /** Fallback UI override — default: error card dengan tombol reload. */
  fallback?: ReactNode
  /** Diisi bila boundary hanya mengcover satu route — dipakai untuk label di log. */
  routeName?: string
}

interface State {
  error: Error | null
  /** Bumped on retry so the subtree remounts instead of re-throwing the same error. */
  attempt: number
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
    this.state = { error: null, attempt: 0 }
  }

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Log for debugging; never sent to an external service (privacy-safe).
    console.error('[ErrorBoundary]', this.props.routeName ?? 'unknown', error, info.componentStack)
  }

  handleReset = () => {
    this.setState((prev) => ({ error: null, attempt: prev.attempt + 1 }))
  }

  render() {
    if (this.state.error) {
      if (this.props.fallback) return this.props.fallback

      const isChunkErr = isChunkLoadError(this.state.error)
      const message = this.state.error.message.trim()

      return (
        <div className="flex flex-col items-center justify-center min-h-screen px-6 text-center gap-4">
          <div className="text-3xl" aria-hidden="true">{isChunkErr ? '🔄' : '⚠️'}</div>
          <div>
            {/* The heading names what happened; the thrown message can carry
                internals (a stack line, an id) and stays folded away. */}
            <h1 className="text-fg font-semibold text-sm mb-1">
              {t(isChunkErr ? 'errorBoundary.chunk.title' : 'errorBoundary.title')}
            </h1>
            <p className="text-fg-dim text-xs max-w-xs">
              {t(isChunkErr ? 'errorBoundary.chunk.body' : 'errorBoundary.body')}
            </p>
            {!isChunkErr && message !== '' && (
              <details className="mt-3 max-w-xs">
                <summary className="cursor-pointer text-xs text-fg-dim">
                  {t('errorBoundary.details')}
                </summary>
                <p className="mt-1 break-words font-mono text-xs text-fg-dim">{message}</p>
              </details>
            )}
          </div>
          <div className="flex gap-2">
            {!isChunkErr && (
              <button
                onClick={this.handleReset}
                className="text-xs px-3 py-1.5 rounded-lg bg-elevated hover:bg-border text-fg transition-colors hit44"
              >
                {t('errorBoundary.retry')}
              </button>
            )}
            <button
              onClick={() => window.location.reload()}
              className="text-xs px-3 py-1.5 rounded-lg bg-accent/20 hover:bg-accent/30 text-accent transition-colors font-semibold hit44"
            >
              {t('errorBoundary.reload')}
            </button>
          </div>
        </div>
      )
    }

    return <Fragment key={this.state.attempt}>{this.props.children}</Fragment>
  }
}
