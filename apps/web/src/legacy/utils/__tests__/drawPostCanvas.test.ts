import { describe, expect, it } from 'vitest'
import { drawPostCanvas } from '../canvas-templates/template2/drawPostCanvas'
import { fakeImage, imageLabelOf, installRecordingContext } from '@/test/recordingContext'

function newCanvas() {
  const canvas = document.createElement('canvas')
  canvas.width = 1080
  canvas.height = 1350
  return canvas
}

describe('drawPostCanvas (template 2)', () => {
  it('records the photo, the frame, the date characters, the slider and the badge in that order', () => {
    const rec = installRecordingContext()
    const photo = fakeImage(2160, 2700, 'photo')
    const frame = fakeImage(1080, 1350, 'frame')
    const badge = fakeImage(300, 100, 'badge')

    drawPostCanvas({
      canvas: newCanvas(),
      userPhoto: photo,
      photoOffset: { x: 0, y: 0 },
      photoZoom: 1,
      overlays: { footer: frame, badge },
      date: { day: '12', month: 'JUL', year: '2026' },
    })

    expect(rec.callsOf('clearRect')[0]).toMatchObject({ args: [0, 0, 1080, 1350] })

    const images = rec.callsOf('drawImage')
    expect(imageLabelOf(images[0].args[0])).toBe('photo')
    expect(images[0].args.slice(1)).toEqual([0, 0, 1080, 1350])
    expect(imageLabelOf(images[1].args[0])).toBe('frame')
    expect(images[1].args.slice(1)).toEqual([0, 0, 1080, 1350])

    const dayFont = '400 190px "Anton", Impact, sans-serif'
    const monthFont = '400 76px "Anton", Impact, sans-serif'
    const chars = rec
      .fillTexts()
      .filter((t) => t.font === dayFont || t.font === monthFont)
      .map((t) => t.text)
    expect(chars).toEqual(['1', '2', 'J', 'U', 'L', '2', '0', '2', '6'])

    const dayChars = rec.fillTexts().filter((t) => t.font === dayFont)
    expect(dayChars.every((t) => t.fillStyle === '#FFFFFF' && t.textAlign === 'left')).toBe(true)

    const slash = rec.callsOf('stroke')
    expect(slash).toHaveLength(1)
    expect(slash[0].state.strokeStyle).toBe('#FFC700')
    expect(slash[0].state.lineWidth).toBe(12)
    expect(slash[0].state.lineCap).toBe('square')

    const badgeCall = images[images.length - 1]
    expect(imageLabelOf(badgeCall.args[0])).toBe('badge')
    expect(badgeCall.args.slice(1)).toEqual([330, 1190, 420, 140])
    expect(badgeCall.state.shadowColor).toBe('rgba(0,0,0,0.30)')

    const frameIndex = images[1].index
    const lastCharIndex = rec.fillTexts()[rec.fillTexts().length - 1].index
    expect(frameIndex).toBeLessThan(lastCharIndex)
    expect(slash[0].index).toBeGreaterThan(lastCharIndex)
    expect(badgeCall.index).toBeGreaterThan(slash[0].index)
  })

  it('records the navy background and no date text when there is no photo and no date', () => {
    const rec = installRecordingContext()

    drawPostCanvas({
      canvas: newCanvas(),
      userPhoto: null,
      photoOffset: { x: 0, y: 0 },
      photoZoom: 1,
      overlays: { footer: fakeImage(1080, 1350, 'frame') },
      date: null,
    })

    const background = rec.callsOf('fillRect')[0]
    expect(background.args).toEqual([0, 0, 1080, 1350])
    expect(background.state.fillStyle).toBe('#09264D')

    expect(rec.images()).toEqual(['frame'])
    expect(rec.texts()).toHaveLength(0)
    expect(rec.callsOf('stroke')).toHaveLength(0)
  })
})