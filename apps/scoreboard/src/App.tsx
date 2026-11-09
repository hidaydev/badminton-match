import { useState } from 'react'
import ScoreboardPage from './pages/ScoreboardPage'
import InstallModal from './components/InstallModal'
import UpdatePrompt from './components/UpdatePrompt'
import { usePwaInstall } from './hooks/usePwaInstall'
import { useAppUpdate } from './hooks/useAppUpdate'
import { readStoredValue, writeStoredValue } from './utils/storage'

export default function App() {
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const { needRefresh, applyUpdate, dismiss } = useAppUpdate()
  const today = new Date().toDateString()
  const [dismissed, setDismissed] = useState(false)
  const showModal = isInstallable && !dismissed && readStoredValue('pwa-install-shown') !== today

  async function handleInstall() {
    await prompt()
    writeStoredValue('pwa-install-shown', today)
    setDismissed(true)
  }

  function handleClose() {
    writeStoredValue('pwa-install-shown', today)
    setDismissed(true)
  }

  return (
    <>
      <ScoreboardPage />
      {needRefresh && <UpdatePrompt onUpdate={applyUpdate} onDismiss={dismiss} />}
      {showModal && (
        <InstallModal isIos={isIos} onInstall={handleInstall} onClose={handleClose} />
      )}
    </>
  )
}
