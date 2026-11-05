/**
 * Toast error yang dipakai di beberapa halaman. `ariaLive` opsional supaya
 * halaman yang sebelumnya tanpa aria-live tetap identik.
 */
export default function ErrorBanner({ message, ariaLive }: { message: string; ariaLive?: 'polite' | 'assertive' | 'off' }) {
  return (
    <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg" role="alert" aria-live={ariaLive}>
      {message}
    </div>
  )
}
