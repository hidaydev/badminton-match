import { createContext, useContext } from 'react'
import type { SharedSnapshot } from './utils/shareUrl'

interface SharedViewContextType {
  snapshot: SharedSnapshot | null
  isSharedView: boolean
  exitSharedView: () => void
}

export const SharedViewContext = createContext<SharedViewContextType>({
  snapshot: null,
  isSharedView: false,
  exitSharedView: () => {},
})

export function useSharedView() {
  return useContext(SharedViewContext)
}
