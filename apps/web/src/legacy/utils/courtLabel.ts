// courtLabel: the display label for a court index.
//
// One source for every court label. A name from the config wins; when it is
// empty the fallback is a letter (A, B, ...), the canonical scheme the schedule
// grid uses. An index above 25 falls back to the number.
export function courtLabel(courtNames: string[] | undefined, courtIndex: number): string {
  const name = courtNames?.[courtIndex]
  if (name) return name
  return courtIndex <= 25 ? String.fromCharCode(65 + courtIndex) : String(courtIndex + 1)
}
