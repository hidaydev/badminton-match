// src/test/recordingContext.ts
// A recording CanvasRenderingContext2D for the canvas drawing functions.
//
// Every drawing call is stored together with the style state in force at the
// moment of the call, so a test can assert the text, order, coordinates and
// colours a drawing function emits without any native canvas package, and
// without comparing pixels.
//
// Any member the fixture does not implement throws. A missing member is a
// fixture bug, and it must be loud rather than a silent no-op.
import { vi } from 'vitest'

/** Average advance width per character, as a fraction of the font size. */
const CHAR_WIDTH_RATIO = 0.6

const STATE_KEYS = [
  'fillStyle',
  'strokeStyle',
  'font',
  'textAlign',
  'textBaseline',
  'letterSpacing',
  'globalAlpha',
  'lineWidth',
  'lineJoin',
  'lineCap',
  'filter',
  'shadowColor',
  'shadowBlur',
  'shadowOffsetX',
  'shadowOffsetY',
  'imageSmoothingEnabled',
  'imageSmoothingQuality',
] as const

const STATE_KEY_SET: ReadonlySet<string> = new Set<string>(STATE_KEYS)

const DEFAULT_STATE: Record<string, unknown> = {
  fillStyle: '#000000',
  strokeStyle: '#000000',
  font: '10px sans-serif',
  textAlign: 'start',
  textBaseline: 'alphabetic',
  letterSpacing: '0px',
  globalAlpha: 1,
  lineWidth: 1,
  lineJoin: 'miter',
  lineCap: 'butt',
  filter: 'none',
  shadowColor: 'rgba(0, 0, 0, 0)',
  shadowBlur: 0,
  shadowOffsetX: 0,
  shadowOffsetY: 0,
  imageSmoothingEnabled: true,
  imageSmoothingQuality: 'low',
}

/** Names a proxy must answer normally; assertion libraries probe them. */
const PASS_THROUGH = new Set<string>(['then', 'toJSON', 'constructor', 'asymmetricMatch', 'nodeType', '$$typeof'])

export interface RecordedCall {
  /** Position in the call buffer, so a test can assert drawing order. */
  index: number
  op: string
  args: readonly unknown[]
  /** Style state at the moment of the call. */
  state: Record<string, unknown>
}

export interface RecordedText {
  index: number
  op: 'fillText' | 'strokeText'
  text: string
  x: number
  y: number
  font: string
  textAlign: CanvasTextAlign
  letterSpacing: string
  fillStyle: unknown
  strokeStyle: unknown
  lineWidth: number
  lineJoin: CanvasLineJoin
}

export interface Recorder {
  ctx: CanvasRenderingContext2D
  /** Live call buffer, in drawing order. */
  calls: RecordedCall[]
  callsOf(op: string): RecordedCall[]
  /** fillText and strokeText calls, in drawing order. */
  texts(): RecordedText[]
  fillTexts(): RecordedText[]
  /** Buffer index of the first text call with this exact string, or -1. */
  indexOfText(text: string): number
  /** Labels of the images handed to drawImage, in drawing order. */
  images(): string[]
}

function fontSizeOf(font: string): number {
  const match = /(\d+(?:\.\d+)?)px/.exec(font)
  return match ? Number(match[1]) : 10
}

class RecordingContext2D {
  readonly calls: RecordedCall[] = []
  state: Record<string, unknown> = { ...DEFAULT_STATE }
  private readonly stack: Record<string, unknown>[] = []

  private record(op: string, ...args: unknown[]): void {
    this.calls.push({ index: this.calls.length, op, args, state: { ...this.state } })
  }

  private gradient(op: string, args: readonly unknown[]): CanvasGradient {
    this.record(op, ...args)
    return {
      addColorStop: (offset: number, color: string) => {
        this.record('addColorStop', offset, color)
      },
    } as unknown as CanvasGradient
  }

  save(): void {
    this.stack.push({ ...this.state })
    this.record('save')
  }

  restore(): void {
    const previous = this.stack.pop()
    if (previous) this.state = previous
    this.record('restore')
  }

  beginPath(): void {
    this.record('beginPath')
  }

  moveTo(x: number, y: number): void {
    this.record('moveTo', x, y)
  }

  lineTo(x: number, y: number): void {
    this.record('lineTo', x, y)
  }

  rect(x: number, y: number, w: number, h: number): void {
    this.record('rect', x, y, w, h)
  }

  roundRect(x: number, y: number, w: number, h: number, radii?: number | number[]): void {
    this.record('roundRect', x, y, w, h, radii)
  }

  arc(x: number, y: number, radius: number, startAngle: number, endAngle: number): void {
    this.record('arc', x, y, radius, startAngle, endAngle)
  }

  clip(): void {
    this.record('clip')
  }

  translate(x: number, y: number): void {
    this.record('translate', x, y)
  }

  rotate(angle: number): void {
    this.record('rotate', angle)
  }

  transform(a: number, b: number, c: number, d: number, e: number, f: number): void {
    this.record('transform', a, b, c, d, e, f)
  }

  fill(): void {
    this.record('fill')
  }

  stroke(): void {
    this.record('stroke')
  }

  clearRect(x: number, y: number, w: number, h: number): void {
    this.record('clearRect', x, y, w, h)
  }

  fillRect(x: number, y: number, w: number, h: number): void {
    this.record('fillRect', x, y, w, h)
  }

  drawImage(image: unknown, ...rest: number[]): void {
    this.record('drawImage', image, ...rest)
  }

  fillText(text: string, x: number, y: number): void {
    this.record('fillText', text, x, y)
  }

  strokeText(text: string, x: number, y: number): void {
    this.record('strokeText', text, x, y)
  }

  measureText(text: string): TextMetrics {
    this.record('measureText', text)
    const width = text.length * fontSizeOf(String(this.state.font)) * CHAR_WIDTH_RATIO
    return { width } as TextMetrics
  }

  createLinearGradient(x0: number, y0: number, x1: number, y1: number): CanvasGradient {
    return this.gradient('createLinearGradient', [x0, y0, x1, y1])
  }

  createRadialGradient(x0: number, y0: number, r0: number, x1: number, y1: number, r1: number): CanvasGradient {
    return this.gradient('createRadialGradient', [x0, y0, r0, x1, y1, r1])
  }
}

function guard(target: RecordingContext2D): CanvasRenderingContext2D {
  return new Proxy(target, {
    get(obj, prop) {
      if (typeof prop === 'symbol' || PASS_THROUGH.has(prop)) return Reflect.get(obj, prop)
      if (STATE_KEY_SET.has(prop)) return obj.state[prop]
      if (prop in obj) return Reflect.get(obj, prop)
      throw new Error(`recordingContext: "${prop}" is not implemented by the fixture`)
    },
    set(obj, prop, value) {
      if (typeof prop === 'string' && STATE_KEY_SET.has(prop)) {
        obj.state[prop] = value
        return true
      }
      if (typeof prop === 'symbol' || prop in obj) return Reflect.set(obj, prop, value)
      throw new Error(`recordingContext: cannot set "${String(prop)}" on the fixture`)
    },
  }) as unknown as CanvasRenderingContext2D
}

function toRecordedText(call: RecordedCall): RecordedText {
  return {
    index: call.index,
    op: call.op as 'fillText' | 'strokeText',
    text: String(call.args[0]),
    x: Number(call.args[1]),
    y: Number(call.args[2]),
    font: String(call.state.font),
    textAlign: call.state.textAlign as CanvasTextAlign,
    letterSpacing: String(call.state.letterSpacing),
    fillStyle: call.state.fillStyle,
    strokeStyle: call.state.strokeStyle,
    lineWidth: Number(call.state.lineWidth),
    lineJoin: call.state.lineJoin as CanvasLineJoin,
  }
}

export function createRecordingContext(): Recorder {
  const target = new RecordingContext2D()
  const calls = target.calls
  const texts = () => calls.filter((c) => c.op === 'fillText' || c.op === 'strokeText').map(toRecordedText)

  return {
    ctx: guard(target),
    calls,
    callsOf: (op: string) => calls.filter((c) => c.op === op),
    texts,
    fillTexts: () => texts().filter((t) => t.op === 'fillText'),
    indexOfText: (text: string) =>
      calls.find((c) => (c.op === 'fillText' || c.op === 'strokeText') && String(c.args[0]) === text)?.index ?? -1,
    images: () => calls.filter((c) => c.op === 'drawImage').map((c) => imageLabelOf(c.args[0]) ?? ''),
  }
}

/** Install a fresh recorder on every canvas element for the current test. */
export function installRecordingContext(): Recorder {
  const recorder = createRecordingContext()
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(recorder.ctx)
  return recorder
}

/** Stand-in for an HTMLImageElement; only the size and the label are read. */
export function fakeImage(width: number, height: number, label: string): HTMLImageElement {
  return { naturalWidth: width, naturalHeight: height, width, height, label } as unknown as HTMLImageElement
}

/** Label of a fakeImage, or undefined for a real canvas or an image without one. */
export function imageLabelOf(value: unknown): string | undefined {
  if (typeof value !== 'object' || value === null || !('label' in value)) return undefined
  return String((value as { label: unknown }).label)
}