import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ErrorBoundary from '../ErrorBoundary'
import { t } from '../../../i18n'

function Boom(): never {
  throw new Error('boom: stack line 42 at render')
}

describe('ErrorBoundary', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('names the failure in the heading and folds the raw message away', () => {
    // React and the boundary both log the caught render error.
    vi.spyOn(console, 'error').mockImplementation(() => {})

    render(
      <ErrorBoundary routeName="test">
        <Boom />
      </ErrorBoundary>,
    )

    const heading = screen.getByRole('heading', { level: 1 })
    expect(heading).toHaveTextContent(t('errorBoundary.title'))
    expect(heading).not.toHaveTextContent('boom')

    // The message still reaches the user, but only behind the disclosure.
    const detail = screen.getByText('boom: stack line 42 at render')
    expect(detail.closest('details')).not.toBeNull()
    expect(screen.getByText(t('errorBoundary.details')).tagName).toBe('SUMMARY')
  })
})
