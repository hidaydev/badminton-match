import { render } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Spinner } from './Spinner'

describe('Spinner', () => {
  it('is decorative when the surrounding UI already announces progress', () => {
    const { container } = render(<Spinner />)
    const wrapper = container.firstElementChild as HTMLElement
    expect(wrapper.getAttribute('aria-hidden')).toBe('true')
    expect(wrapper.getAttribute('role')).toBeNull()
    expect(wrapper.querySelector('svg')?.getAttribute('width')).toBe('16')
  })

  it('becomes a busy status region when given a label', () => {
    const { getByRole, getByText } = render(<Spinner label="Loading sessions" size={12} />)
    const status = getByRole('status')
    expect(status.getAttribute('aria-busy')).toBe('true')
    expect(status.getAttribute('aria-hidden')).toBeNull()
    expect(getByText('Loading sessions')).toBeInTheDocument()
    expect(status.querySelector('svg')?.getAttribute('width')).toBe('12')
  })

  it('keeps the caller classes on the wrapper', () => {
    const { container } = render(<Spinner className="mr-2 text-accent" />)
    const wrapper = container.firstElementChild as HTMLElement
    expect(wrapper.className).toContain('mr-2')
    expect(wrapper.className).toContain('text-accent')
  })
})
