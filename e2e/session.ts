import type { Page } from 'playwright/test'
import { t } from '../apps/web/src/i18n'

/**
 * Signs in through the OIDC stub. The API is booted with the stub's default
 * identity as `MAJADU_BOOTSTRAP_OWNER_EMAIL`, so this lands on the platform
 * owner without a real Google account (TECH-SPEC §9).
 */
export async function signIn(page: Page): Promise<void> {
  await page.goto('/')
  await page.getByRole('button', { name: t('login.action') }).click()
  // The header is the shell; the nav inside it is collapsed on a phone until
  // the menu is opened, so this waits for the shell rather than the links.
  await page.getByRole('banner').waitFor()
}
