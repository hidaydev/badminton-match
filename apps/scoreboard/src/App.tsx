import { useState } from 'react'
import ScoreboardPage from './pages/ScoreboardPage'
import InstallModal from './components/InstallModal'
import { usePwaInstall } from './hooks/usePwaInstall'

export default function App() {
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const today = new Date().toDateString()
  const [dismissed, setDismissed] = useState(false)
  const showModal = isInstallable && !dismissed && localStorage.getItem('pwa-install-shown') !== today

  async function handleInstall() {
    await prompt()
    localStorage.setItem('pwa-install-shown', today)
    setDismissed(true)
  }

  function handleClose() {
    localStorage.setItem('pwa-install-shown', today)
    setDismissed(true)
  }

  return (
    <>
      <ScoreboardPage />
      {showModal && (
        <InstallModal isIos={isIos} onInstall={handleInstall} onClose={handleClose} />
      )}
    </>
  )
}
