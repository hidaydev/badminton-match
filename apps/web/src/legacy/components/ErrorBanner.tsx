/**
 * Toast error yang dipakai di beberapa halaman. `role="alert"` sudah membawa
 * `aria-live="assertive"` implisit; menambahkan aria-live lain membuat
 * pembacaan kontradiktif di beberapa screen reader.
 */
export default function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg" role="alert">
      {message}
    </div>
  )
}