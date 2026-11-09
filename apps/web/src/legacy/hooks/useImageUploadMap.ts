// useImageUploadMap: the photo upload pattern behind a hidden <input type="file">.
// openUpload(key) marks the active key and opens the picker; onFileChange reads
// the file, loads it into an HTMLImageElement, revokes the object URL and keeps
// it in the map. The optional onLoad is used when the photo state lives in the
// parent.
import { useRef, useState } from 'react'
import type { ChangeEvent, RefObject } from 'react'

export interface ImageUploadMap {
  images: Record<string, HTMLImageElement>
  fileInputRef: RefObject<HTMLInputElement | null>
  openUpload: (key: string) => void
  onFileChange: (e: ChangeEvent<HTMLInputElement>) => void
}

export function useImageUploadMap(
  onLoad?: (key: string, img: HTMLImageElement) => void,
): ImageUploadMap {
  const [images, setImages] = useState<Record<string, HTMLImageElement>>({})
  const fileInputRef = useRef<HTMLInputElement>(null)
  const activeKey = useRef<string | null>(null)

  const openUpload = (key: string) => {
    activeKey.current = key
    fileInputRef.current?.click()
  }

  const onFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    const key = activeKey.current
    if (!file || !key) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      if (onLoad) onLoad(key, img)
      else setImages((prev) => ({ ...prev, [key]: img }))
    }
    img.onerror = () => URL.revokeObjectURL(url)
    img.src = url
    e.target.value = ''
  }

  return { images, fileInputRef, openUpload, onFileChange }
}
