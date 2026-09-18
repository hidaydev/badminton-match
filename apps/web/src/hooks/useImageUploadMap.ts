// useImageUploadMap — pola upload foto lewat <input type="file"> tersembunyi.
// openUpload(key) menandai key aktif lalu membuka picker; onFileChange membaca
// file, memuatnya ke HTMLImageElement, revoke object URL, lalu menyimpannya di
// map. onLoad (opsional) dipakai kalau state foto tinggal di parent.
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
