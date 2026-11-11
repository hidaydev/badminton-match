import { t } from '../i18n'

/**
 * The first focusable element in a layout. It is hidden until focused, and
 * then appears above the header, so keyboard users reach the page content
 * without walking the header controls on every screen.
 */
export function SkipLink() {
  return (
    <a
      href="#main"
      className="sr-only focus:not-sr-only focus:z-overlay focus:bg-accent focus:px-4 focus:py-3 focus:text-sm focus:font-semibold focus:text-ground"
    >
      {t('shell.skipToContent')}
    </a>
  )
}
