// Image helpers shared by the export drawings.

import type { Rect } from './geometry'

/** Decode an image for a canvas export. */
export function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image()
    image.onload = () => resolve(image)
    image.onerror = () => reject(new Error(`could not load image: ${src}`))
    image.src = src
  })
}

/** v1 `drawCoverFill`: scale until the image covers the canvas, then centre it. */
export function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasWidth: number,
  canvasHeight: number,
  offsetX = 0,
  offsetY = 0,
  zoom = 1,
): void {
  if (!img.naturalWidth || !img.naturalHeight) return
  const scale =
    Math.max(canvasWidth / img.naturalWidth, canvasHeight / img.naturalHeight) * zoom
  const width = img.naturalWidth * scale
  const height = img.naturalHeight * scale
  ctx.drawImage(
    img,
    (canvasWidth - width) / 2 + offsetX,
    (canvasHeight - height) / 2 + offsetY,
    width,
    height,
  )
}

/** Stretch an image over the whole canvas. */
export function drawCoverImage(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasWidth: number,
  canvasHeight: number,
): void {
  if (!img.naturalWidth || !img.naturalHeight) return
  ctx.drawImage(img, 0, 0, canvasWidth, canvasHeight)
}

/**
 * Draw into a layout box, halving the source until it is close to the target
 * so a large logo does not turn to mush (v1 did the same in the posts).
 */
export function drawImageIn(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  rect: Rect,
): void {
  if (!img.naturalWidth || !img.naturalHeight) return
  let source: CanvasImageSource = img
  let sourceWidth = img.naturalWidth
  let sourceHeight = img.naturalHeight
  if (rect.width <= 0 || rect.height <= 0) return
  while (sourceWidth / 2 > rect.width * 1.5) {
    const mid = document.createElement('canvas')
    mid.width = Math.round(sourceWidth / 2)
    mid.height = Math.round(sourceHeight / 2)
    const midCtx = mid.getContext('2d')
    if (midCtx === null) break
    midCtx.imageSmoothingEnabled = true
    midCtx.imageSmoothingQuality = 'high'
    midCtx.drawImage(source, 0, 0, mid.width, mid.height)
    source = mid
    sourceWidth = mid.width
    sourceHeight = mid.height
  }
  ctx.save()
  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(source, rect.x, rect.y, rect.width, rect.height)
  ctx.restore()
}
