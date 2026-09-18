// courtLabel — label tampilan untuk court index.
//
// Satu sumber untuk semua tampilan court. Nama dari config menang; kalau kosong
// fallback ke huruf (A, B, ...) — skema kanonik yang dipakai grid jadwal.
// Index > 25 jatuh ke angka.
export function courtLabel(courtNames: string[] | undefined, courtIndex: number): string {
  const name = courtNames?.[courtIndex]
  if (name) return name
  return courtIndex <= 25 ? String.fromCharCode(65 + courtIndex) : String(courtIndex + 1)
}
