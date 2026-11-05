// src/utils/share.ts
// Shared iOS share / fallback download utility.

/** Detect if running on iOS. */
function isIOS(): boolean {
  return /iPad|iPhone|iPod/.test(navigator.userAgent)
}

/** Convert a canvas to a JPEG Blob. */
export function canvasToBlob(canvas: HTMLCanvasElement, quality = 0.92): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality))
}

/**
 * Share files on iOS (via Web Share API) or trigger download as fallback.
 * Single file: tries iOS share first, falls back to <a> download.
 * Multiple files: tries iOS share with all files, falls back to individual downloads.
 */
export async function shareOrDownload(
  files: File[],
  title: string,
): Promise<void> {
  if (files.length === 0) return

  if (isIOS() && navigator.canShare?.({ files })) {
    await navigator.share({ files, title })
  } else {
    for (const file of files) {
      const url = URL.createObjectURL(file)
      const a = document.createElement('a')
      a.href = url
      a.download = file.name
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      setTimeout(() => URL.revokeObjectURL(url), 300)
    }
  }
}
