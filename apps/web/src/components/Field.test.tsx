import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Field, Input, Select } from './Field'

/**
 * DS-23: an error must be the field's accessible description, and the field
 * must be marked invalid.
 */

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

  it('exposes a validation error as the field description and marks the field invalid', () => {
    render(
      <Field label="Player name" error="Name is required">
        <Input />
      </Field>,
    )

    const input = screen.getByRole('textbox', { description: 'Name is required' })
    expect(input).toHaveAttribute('aria-invalid', 'true')
  })

  it('marks the control invalid and describes it with the error', () => {
    render(
      <Field label="Player name" error="Name is required">
        <Input />
      </Field>,
    )

    const input = screen.getByLabelText('Player name')
    const error = screen.getByRole('alert')
    expect(error).toHaveTextContent('Name is required')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toHaveAttribute('aria-describedby', error.id)
    expect(error.id).toBe(`${input.id}-error`)
  })

  it('leaves the control valid when there is no error', () => {
    render(
      <Field label="Player name">
        <Input />
      </Field>,
    )

    expect(screen.getByLabelText('Player name')).not.toHaveAttribute('aria-invalid')
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('describes the control with the hint and the error together', () => {
    render(
      <Field label="Aliases" hint="Comma separated" error="Too long">
        <Input aria-describedby="other" />
      </Field>,
    )

    const input = screen.getByLabelText('Aliases')
    expect(input.getAttribute('aria-describedby')).toBe(
      `other ${screen.getByText('Comma separated').id} ${screen.getByRole('alert').id}`,
    )
  })

  it('keeps an aria-invalid the caller already set while there is no error', () => {
    render(
      <Field label="Player name">
        <Input aria-invalid={true} />
      </Field>,
    )

    expect(screen.getByLabelText('Player name')).toHaveAttribute('aria-invalid', 'true')
  })
})
