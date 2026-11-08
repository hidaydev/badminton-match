import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import UpdateBanner from '../UpdateBanner'

describe('UpdateBanner', () => {
  it('announces itself as a status region with a reload and a later action', () => {
    const onReload = vi.fn()
    const onDismiss = vi.fn()
    render(<UpdateBanner onReload={onReload} onDismiss={onDismiss} />)

    expect(screen.getByRole('status', { name: 'Update Available' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Reload Now' }))
    expect(onReload).toHaveBeenCalledTimes(1)
    expect(onDismiss).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Later' }))
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })

  it('dismisses on Escape', () => {
    const onDismiss = vi.fn()
    render(<UpdateBanner onReload={vi.fn()} onDismiss={onDismiss} />)

    fireEvent.keyDown(document, { key: 'Escape' })

    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})