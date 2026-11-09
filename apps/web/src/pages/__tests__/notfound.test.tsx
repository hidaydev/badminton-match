import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { t } from '../../i18n'
import NotFoundPage from '../NotFoundPage'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/c/:slug/*" element={<NotFoundPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('NotFoundPage', () => {
  it('names the path it could not resolve', () => {
    renderAt('/c/acme/no-such-screen')

    expect(screen.getByRole('heading', { name: t('notFound.title') })).toBeInTheDocument()
    expect(
      screen.getByText(t('notFound.body', { path: '/c/acme/no-such-screen' })),
    ).toBeInTheDocument()
  })

  it('links back to the community it was opened inside', () => {
    renderAt('/c/acme/no-such-screen')

    expect(
      screen.getByRole('link', { name: t('notFound.communityHome') }),
    ).toHaveAttribute('href', '/c/acme')
  })

  it('offers only the home link outside a community', () => {
    renderAt('/no-such-page')

    expect(screen.queryByRole('link', { name: t('notFound.communityHome') })).toBeNull()
    expect(screen.getByRole('link', { name: t('nav.home') })).toHaveAttribute('href', '/')
  })
})
