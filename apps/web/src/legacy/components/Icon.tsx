// The icon set moved to `src/components/Icon.tsx` so one file holds every glyph.
// This path stays as a re-export because the restored v1 screens import it here;
// the type re-export is what fast-refresh objects to, so it lives inline.
export { default } from '../../components/Icon'
export type { IconName } from '../../components/Icon'
