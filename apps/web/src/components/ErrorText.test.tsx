import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ErrorText } from './ErrorText'

describe('ErrorText', () => {
  it('announces as an alert without a second live region', () => {
    render(<ErrorText>Something failed</ErrorText>)

    const alert = screen.getByRole('alert')
    expect(alert).toHaveTextContent('Something failed')
    expect(alert).not.toHaveAttribute('aria-live')
    expect(alert).toHaveClass('text-error')
  })

  it('appends the placement class', () => {
    render(<ErrorText className="mt-2">Something failed</ErrorText>)

    expect(screen.getByRole('alert')).toHaveClass('mt-2')
  })
})
