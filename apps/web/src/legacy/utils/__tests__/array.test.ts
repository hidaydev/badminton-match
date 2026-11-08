import { describe, expect, it, vi } from 'vitest'
import { combinations, shuffle } from '../array'

describe('shuffle', () => {
  it('returns a shuffled copy and leaves the input alone', () => {
    const input = [1, 2, 3, 4, 5]

    const result = shuffle(input)

    expect(result).not.toBe(input)
    expect([...result].sort((a, b) => a - b)).toEqual(input)
    expect(input).toEqual([1, 2, 3, 4, 5])
  })

  it('actually moves elements instead of copying the order', () => {
    // Math.random pinned to 0 makes Fisher-Yates move every element once.
    vi.spyOn(Math, 'random').mockReturnValue(0)

    expect(shuffle([1, 2, 3, 4])).not.toEqual([1, 2, 3, 4])
  })

  it('handles empty and single-element arrays', () => {
    expect(shuffle([])).toEqual([])
    expect(shuffle(['only'])).toEqual(['only'])
  })
})

describe('combinations', () => {
  it('yields every subset of the requested size in order', () => {
    expect([...combinations(['a', 'b', 'c'], 2)]).toEqual([
      ['a', 'b'],
      ['a', 'c'],
      ['b', 'c'],
    ])
  })

  it('yields one empty subset for k = 0', () => {
    expect([...combinations(['a', 'b'], 0)]).toEqual([[]])
  })

  it('yields nothing for a size outside the array', () => {
    expect([...combinations(['a', 'b'], 3)]).toEqual([])
    expect([...combinations(['a', 'b'], -1)]).toEqual([])
  })

  it('does not modify the source array', () => {
    const source = ['a', 'b', 'c']

    const result = [...combinations(source, 2)]

    expect(result).toHaveLength(3)
    expect(source).toEqual(['a', 'b', 'c'])
  })
})