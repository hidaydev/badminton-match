// Geometry primitives shared by every export layout.
//
// Pure arithmetic only: no canvas, no DOM, no rounding to device pixels. A
// layout is a tree of these boxes, so an assertion on a box is an assertion on
// what gets painted.

export type Point = { x: number; y: number }

/** Axis-aligned box in canvas units (1 unit = 1 exported pixel). */
export type Rect = { x: number; y: number; width: number; height: number }

export type CanvasSize = { width: number; height: number }

export function box(x: number, y: number, width: number, height: number): Rect {
  return { x, y, width, height }
}

export function boxCenter(rect: Rect): Point {
  return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
}

export type Transform = {
  /** Radians. Positive turns clockwise because the canvas y axis points down. */
  rotation?: number
  /** Horizontal shear in radians, the CSS `skewX` posture. */
  skewX?: number
  /** Origin of the transform; defaults to the box centre. */
  pivot?: Point
}

function transformPoint(point: Point, rect: Rect, transform: Transform): Point {
  const rotation = transform.rotation ?? 0
  const skewX = transform.skewX ?? 0
  if (rotation === 0 && skewX === 0) return { x: point.x, y: point.y }
  const pivot = transform.pivot ?? boxCenter(rect)
  const dx = point.x - pivot.x
  const dy = point.y - pivot.y
  // The canvas applies the last matrix first, so the shear runs before the
  // rotation: p' = pivot + R(S(p - pivot)).
  const shearedX = dx + Math.tan(skewX) * dy
  const cos = Math.cos(rotation)
  const sin = Math.sin(rotation)
  return {
    x: pivot.x + shearedX * cos - dy * sin,
    y: pivot.y + shearedX * sin + dy * cos,
  }
}

/**
 * The axis-aligned box the transformed rectangle covers. Layouts carry it so a
 * test can prove a rotated plate still sits inside the canvas.
 */
export function transformedBounds(rect: Rect, transform: Transform): Rect {
  const corners: Point[] = [
    { x: rect.x, y: rect.y },
    { x: rect.x + rect.width, y: rect.y },
    { x: rect.x + rect.width, y: rect.y + rect.height },
    { x: rect.x, y: rect.y + rect.height },
  ]
  const moved = corners.map((corner) => transformPoint(corner, rect, transform))
  return unionBounds(
    moved.map((corner) => box(corner.x, corner.y, 0, 0)),
  )
}

/** Smallest box that contains every input box. Empty input is a zero box. */
export function unionBounds(boxes: readonly Rect[]): Rect {
  if (boxes.length === 0) return box(0, 0, 0, 0)
  let left = Infinity
  let top = Infinity
  let right = -Infinity
  let bottom = -Infinity
  for (const rect of boxes) {
    left = Math.min(left, rect.x)
    top = Math.min(top, rect.y)
    right = Math.max(right, rect.x + rect.width)
    bottom = Math.max(bottom, rect.y + rect.height)
  }
  return box(left, top, right - left, bottom - top)
}

/** True when the box is inside the canvas, allowing `epsilon` of slack. */
export function insideCanvas(
  rect: Rect,
  canvas: CanvasSize,
  epsilon = 0.01,
): boolean {
  return (
    rect.x >= -epsilon &&
    rect.y >= -epsilon &&
    rect.x + rect.width <= canvas.width + epsilon &&
    rect.y + rect.height <= canvas.height + epsilon
  )
}

/** The v1 composition grid. Offsets are written in these units and scaled to
 * the configured canvas, so a config change moves the geometry. */
export const DESIGN = { width: 1080, height: 1350 } as const
