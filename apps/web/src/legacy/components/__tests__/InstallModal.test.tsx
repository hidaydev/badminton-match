import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { t } from '../../../i18n'
import InstallModal from '../InstallModal'

describe('InstallModal', () => {
  it('closes on Escape and on the sheet close control', () => {
    const onClose = vi.fn()
    render(<InstallModal isIos={false} onInstall={vi.fn()} onClose={onClose} />)

    // Both routes are the Overlay contract, so the sheet is a labelled dialog.
    const dialog = screen.getByRole('dialog', { name: 'Install MAJADU App' })
    fireEvent.keyDown(dialog, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: t('common.close') }))
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('offers the native install action only where the browser has one', () => {
    const onInstall = vi.fn()
    const { unmount } = render(<InstallModal isIos={false} onInstall={onInstall} onClose={vi.fn()} />)

    fireEvent.click(screen.getByRole('button', { name: 'Install App' }))
    expect(onInstall).toHaveBeenCalledTimes(1)
    unmount()

    render(<InstallModal isIos onInstall={onInstall} onClose={vi.fn()} />)

    // iOS has no prompt event: the sheet can only explain the share sheet.
    expect(screen.queryByRole('button', { name: 'Install App' })).not.toBeInTheDocument()
    expect(screen.getByText('Tap the Share button')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Got it' })).toBeInTheDocument()
  })
})