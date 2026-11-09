import type { Project } from 'playwright/test'

/**
 * Phones this app is used on, each with the engine that phone actually runs.
 * Numbers are the CSS viewport, not the panel:
 *
 * - iPhone 17 (2025): 402 x 874 points, DPR 3, 1206 x 2622 panel. Safari, so
 *   WebKit. https://useyourloaf.com/blog/iphone-17-screen-sizes/
 * - POCO F5: 1080 x 2400 panel at ~395 ppi, DPR 2.75, so 393 x 873 CSS pixels.
 *   Chrome for Android, so Chromium. Its 20:9 panel is wider than the iPhone's
 *   19.5:9, which is the point of having both: a layout that only fits one
 *   aspect ratio fails here.
 *
 * `deps.lock` pins the Playwright build and every browser revision.
 */

export const projects: Project[] = [
  {
    name: 'iphone-17',
    // The API spec drives a socket, not a screen, so it runs once in its own
    // project instead of twice on two phones.
    testIgnore: /api\.spec\.ts$/,
    use: {
      browserName: 'webkit',
      viewport: { width: 402, height: 874 },
      deviceScaleFactor: 3,
      isMobile: true,
      hasTouch: true,
    },
  },
  {
    name: 'poco-f5',
    testIgnore: /api\.spec\.ts$/,
    use: {
      browserName: 'chromium',
      viewport: { width: 393, height: 873 },
      deviceScaleFactor: 2.75,
      isMobile: true,
      hasTouch: true,
    },
  },
  {
    // The width a host actually uses the admin screens at. It runs the a11y
    // walk only: a screenshot baseline at 1440 x 900 would have to be recorded
    // on both platforms before the comparison meant anything, and the desktop
    // branches are what this project is here for (the settings table, the
    // summary grid).
    name: 'desktop',
    testMatch: /a11y\.spec\.ts$/,
    use: {
      browserName: 'chromium',
      viewport: { width: 1440, height: 900 },
    },
  },
  {
    // QAE-02, QAE-03, QAE-04, QAE-06: the audit findings live on the API's own
    // socket, so this project uses Playwright's request context against the API
    // the harness started and never opens a page. `testIgnore` on the phone
    // projects keeps the spec to one run.
    name: 'api',
    testMatch: /api\.spec\.ts$/,
    use: {
      browserName: 'chromium',
    },
  },
]
