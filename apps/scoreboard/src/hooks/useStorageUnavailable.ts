import { useSyncExternalStore } from 'react'
import { isStorageUnavailable, subscribeStorageStatus } from '../utils/storage'

export function useStorageUnavailable(): boolean {
  return useSyncExternalStore(subscribeStorageStatus, isStorageUnavailable, isStorageUnavailable)
}
