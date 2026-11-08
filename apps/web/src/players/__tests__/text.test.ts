import { describe, expect, it } from 'vitest'
import { ApiError } from '../../auth/api'
import { t } from '../../i18n'
import { describePlayerError, parseAliases } from '../text'

describe('parseAliases', () => {
  it('splits on commas, trims each entry and drops the empty ones', () => {
    expect(parseAliases(' Ani , Budi ,,  , Citra ')).toEqual(['Ani', 'Budi', 'Citra'])
  })

  it('returns no aliases for a value that is only separators and spaces', () => {
    expect(parseAliases(' , , ')).toEqual([])
  })

  it('keeps inner spaces inside one alias', () => {
    expect(parseAliases('Ani  Budi')).toEqual(['Ani  Budi'])
  })
})

describe('describePlayerError', () => {
  it('maps 403 to the role sentence', () => {
    expect(describePlayerError(new ApiError('403 FORBIDDEN', 'FORBIDDEN', 403))).toBe(
      t('players.error.forbidden'),
    )
  })

  it('maps 409 CONFLICT to the owned history sentence', () => {
    expect(describePlayerError(new ApiError('409 CONFLICT', 'CONFLICT', 409))).toBe(
      t('players.error.inUse'),
    )
  })

  it('maps 409 CLAIMANT_OWNS_PLAYER to the member already has a player sentence', () => {
    expect(
      describePlayerError(new ApiError('409 CLAIMANT_OWNS_PLAYER', 'CLAIMANT_OWNS_PLAYER', 409)),
    ).toBe(t('players.error.claimantHasPlayer'))
  })

  it('maps a 409 with any other code to the duplicate name sentence', () => {
    expect(describePlayerError(new ApiError('409 OTHER', 'OTHER', 409))).toBe(
      t('players.error.conflict'),
    )
  })

  it('maps 400 to the rejected values sentence', () => {
    expect(describePlayerError(new ApiError('400 INVALID', 'INVALID', 400))).toBe(
      t('players.error.invalid'),
    )
  })

  it('maps a 404 to the generic save sentence, not a not-found sentence', () => {
    expect(describePlayerError(new ApiError('404 NOT_FOUND', 'NOT_FOUND', 404))).toBe(
      t('players.error.save'),
    )
  })

  it('maps a failure that is not an ApiError to the generic save sentence', () => {
    expect(describePlayerError(new Error('socket closed'))).toBe(t('players.error.save'))
  })

  it('keeps the five mapped sentences distinct from each other', () => {
    const sentences = [
      describePlayerError(new ApiError('403', 'FORBIDDEN', 403)),
      describePlayerError(new ApiError('409', 'CONFLICT', 409)),
      describePlayerError(new ApiError('409', 'CLAIMANT_OWNS_PLAYER', 409)),
      describePlayerError(new ApiError('409', 'OTHER', 409)),
      describePlayerError(new ApiError('400', 'INVALID', 400)),
    ]

    expect(new Set(sentences).size).toBe(5)
  })
})