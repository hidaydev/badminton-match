import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import InstallModal from './InstallModal'

function renderModal(isIos = false) {
  const onInstall = vi.fn()
  const onClose = vi.fn()
  render(<InstallModal isIos={isIos} onInstall={onInstall} onClose={onClose} />)
  return { onInstall, onClose }
}

describe('InstallModal', () => {
  it('is a labelled dialog with the logo', () => {
    renderModal()

    const dialog = screen.getByRole('dialog', { name: 'Install app' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByAltText('MAJADU Score')).toBeInTheDocument()
  })

  it('offers the install action on a non-iOS browser', () => {
    const { onInstall } = renderModal(false)

    fireEvent.click(screen.getByRole('button', { name: 'Install App' }))
    expect(onInstall).toHaveBeenCalledTimes(1)
  })

  it('shows the home screen steps and no install action on iOS', () => {
    renderModal(true)

    expect(screen.getByText('Tap the Share button')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Got it' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Install App' })).not.toBeInTheDocument()
  })

  it('closes from the secondary button', () => {
    const { onClose } = renderModal(false)

    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('closes on Escape', () => {
    const { onClose } = renderModal(false)

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('closes from the backdrop and not from the panel itself', () => {
    const { onClose } = renderModal(false)
    const dialog = screen.getByRole('dialog', { name: 'Install app' })

    fireEvent.click(screen.getByText('Install MAJADU Score'))
    expect(onClose).not.toHaveBeenCalled()

    fireEvent.click(dialog)
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('says what the app gives you instead of an app store', () => {
    renderModal(false)
    expect(screen.getByText('One tap to install')).toBeInTheDocument()
    expect(screen.getByText(/No app store needed/)).toBeInTheDocument()
  })
})