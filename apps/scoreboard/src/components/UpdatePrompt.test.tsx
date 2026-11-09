import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import UpdatePrompt from './UpdatePrompt'

describe('UpdatePrompt', () => {
  it('announces the update and reloads when asked', () => {
    const onUpdate = vi.fn()
    render(<UpdatePrompt onUpdate={onUpdate} onDismiss={vi.fn()} />)

    expect(screen.getByRole('status')).toHaveTextContent('A new version is available')
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }))

    expect(onUpdate).toHaveBeenCalledTimes(1)
  })

  it('can be dismissed without reloading', () => {
    const onDismiss = vi.fn()
    render(<UpdatePrompt onUpdate={vi.fn()} onDismiss={onDismiss} />)

    fireEvent.click(screen.getByRole('button', { name: 'Later' }))

    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})
