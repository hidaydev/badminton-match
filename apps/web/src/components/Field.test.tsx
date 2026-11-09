import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Field, Input, Select } from './Field'

describe('Field', () => {
  it('links the label to the control by id', () => {
    render(
      <Field label="Player name">
        <Input />
      </Field>,
    )

    const input = screen.getByLabelText('Player name')
    expect(input.tagName).toBe('INPUT')
    expect(input.id).not.toBe('')
  })

  it('references the hint from the control with aria-describedby', () => {
    render(
      <Field label="Aliases" hint="Comma separated">
        <Input />
      </Field>,
    )

    const input = screen.getByLabelText('Aliases')
    const hint = screen.getByText('Comma separated')
    expect(input).toHaveAttribute('aria-describedby', hint.id)
  })

  it('keeps an existing describedby and appends the hint id', () => {
    render(
      <Field label="Aliases" hint="Comma separated">
        <Input aria-describedby="other" />
      </Field>,
    )

    const input = screen.getByLabelText('Aliases')
    expect(input.getAttribute('aria-describedby')).toBe(`other ${screen.getByText('Comma separated').id}`)
  })

  it('honours an explicit id and uses it for the hint', () => {
    render(
      <Field label="Score preset" hint="Defaults to 21" id="preset">
        <Select>
          <option value="21">21</option>
        </Select>
      </Field>,
    )

    const select = screen.getByLabelText('Score preset')
    expect(select).toHaveAttribute('id', 'preset')
    expect(screen.getByText('Defaults to 21')).toHaveAttribute('id', 'preset-hint')
  })
})
