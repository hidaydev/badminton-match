import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ConfirmButton } from './ConfirmButton'

describe('ConfirmButton', () => {
  it('arms on the first click and runs on the second', () => {
    const onConfirm = vi.fn()
    render(
      <ConfirmButton confirmLabel="Really merge?" onConfirm={onConfirm}>
        Merge
      </ConfirmButton>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Merge' }))
    expect(onConfirm).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Really merge?' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('disarms when focus leaves the button', () => {
    const onConfirm = vi.fn()
    render(
      <ConfirmButton confirmLabel="Really delete?" onConfirm={onConfirm}>
        Delete
      </ConfirmButton>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    fireEvent.blur(screen.getByRole('button', { name: 'Really delete?' }))

    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('stays disabled while the caller says so', () => {
    const onConfirm = vi.fn()
    render(
      <ConfirmButton confirmLabel="Really?" onConfirm={onConfirm} disabled>
        Go
      </ConfirmButton>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Go' }))
    expect(onConfirm).not.toHaveBeenCalled()
  })
})
