import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { AuthContext } from '../../auth/AuthContext'
import type { AuthContextValue } from '../../auth/AuthContext'
import { BUILD } from '../../build'
import { t } from '../../i18n'
import LoginPage from '../LoginPage'

const auth: AuthContextValue = {
  user: null,
  memberships: [],
  loading: false,
  loggingIn: false,
  login: async () => undefined,
  logout: async () => undefined,
  refreshMemberships: async () => [],
}

function renderLogin() {
  return render(
    <MemoryRouter>
      <AuthContext.Provider value={auth}>
        <LoginPage />
      </AuthContext.Provider>
    </MemoryRouter>,
  )
}

describe('login page build stamp', () => {
  it('names the version and the commit the bundle was built from', () => {
    // Built from the imported constant, so a new commit cannot rot this test.
    renderLogin()

    expect(screen.getByText(`${BUILD.version} · ${BUILD.commit}`)).toBeInTheDocument()
  })

  it('gives the stamp a readable screen-reader name instead of a bare hash', () => {
    renderLogin()

    expect(screen.getByText(t('login.build', { version: BUILD.version, commit: BUILD.commit }))).toBeInTheDocument()
  })
})
