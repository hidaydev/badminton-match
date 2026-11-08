import { describe, expect, it } from 'vitest'
import { ordinal } from '../ordinal'

describe('ordinal', () => {
  it.each([
    [1, '1st'],
    [2, '2nd'],
    [3, '3rd'],
    [4, '4th'],
    [11, '11th'],
    [12, '12th'],
    [13, '13th'],
    [21, '21st'],
    [22, '22nd'],
    [23, '23rd'],
    [100, '100th'],
    [101, '101st'],
    [111, '111th'],
  ])('formats %i as %s', (n, expected) => {
    expect(ordinal(n)).toBe(expected)
  })
})