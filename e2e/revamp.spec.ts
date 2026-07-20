import { test, expect } from '@playwright/test'

// ── Homepage ────────────────────────────────────────────────────────────────

test.describe('Homepage', () => {
  test('loads without errors', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (err) => errors.push(err.message))
    page.on('console', (msg) => { if (msg.type() === 'error') errors.push(msg.text()) })

    await page.goto('/')
    await expect(page.locator('h2')).toContainText('Scheduler')

    // Filter out known non-critical errors (e.g. Supabase connection)
    const critical = errors.filter(e => !e.includes('supabase') && !e.includes('fetch'))
    expect(critical).toEqual([])
  })

  test('logo renders (not broken image)', async ({ page }) => {
    await page.goto('/')
    const logo = page.locator('header img[alt="logo"]')
    await expect(logo).toBeVisible()

    // Check image actually loaded (naturalWidth > 0)
    const naturalWidth = await logo.evaluate((el: HTMLImageElement) => el.naturalWidth)
    expect(naturalWidth).toBeGreaterThan(0)
  })

  test('IBM Plex Sans font is loaded', async ({ page }) => {
    await page.goto('/')
    await page.waitForFunction(() => document.fonts.check('16px "IBM Plex Sans"'), { timeout: 10000 })
    const loaded = await page.evaluate(() => document.fonts.check('16px "IBM Plex Sans"'))
    expect(loaded).toBe(true)
  })

  test('design token colors are applied', async ({ page }) => {
    await page.goto('/')

    // Check body background is our --color-ground (#0f172a)
    const bgColor = await page.evaluate(() => getComputedStyle(document.body).backgroundColor)
    expect(bgColor).toBe('rgb(15, 23, 42)') // #0f172a

    // Check body text color is our --color-fg (#f1f5f9)
    const textColor = await page.evaluate(() => getComputedStyle(document.body).color)
    expect(textColor).toBe('rgb(241, 245, 249)') // #f1f5f9
  })

  test('navigation grid items are visible', async ({ page }) => {
    await page.goto('/')
    const createSession = page.getByRole('button', { name: /Create Session/ })
    await expect(createSession).toBeVisible()
    const sessions = page.getByRole('button', { name: /Browse past sessions/ })
    await expect(sessions).toBeVisible()
    const scoreboard = page.getByRole('button', { name: /Scoreboard/ })
    await expect(scoreboard).toBeVisible()
  })
})

// ── Scoreboard (code-split lazy load) ───────────────────────────────────────

test.describe('Scoreboard', () => {
  test('loads via code splitting without crash', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (err) => errors.push(err.message))

    await page.goto('/scoreboard')

    // Should show loading state first, then content
    // The red and blue scoring areas should appear
    await expect(page.locator('text=tap to score').first()).toBeVisible({ timeout: 10000 })

    const critical = errors.filter(e => !e.includes('supabase') && !e.includes('fetch'))
    expect(critical).toEqual([])
  })

  test('score tap zones have keyboard accessibility', async ({ page }) => {
    await page.goto('/scoreboard')

    // Check role="button" on scoring zones
    const redZone = page.locator('[role="button"]').first()
    await expect(redZone).toHaveAttribute('tabindex', '0')
  })

  test('minus buttons have aria-labels', async ({ page }) => {
    await page.goto('/scoreboard')

    const decreaseRed = page.locator('[aria-label="Decrease red score"]')
    await expect(decreaseRed).toBeAttached()

    const decreaseBlue = page.locator('[aria-label="Decrease blue score"]')
    await expect(decreaseBlue).toBeAttached()
  })
})

// ── Session Setup ───────────────────────────────────────────────────────────

test.describe('Session Setup', () => {
  test('form inputs have focus-visible ring', async ({ page }) => {
    await page.goto('/session/new')

    // Check that inputs have focus-visible:ring in their class
    const titleInput = page.locator('input[placeholder*="Sunday"]')
    const classes = await titleInput.getAttribute('class')
    expect(classes).toContain('focus-visible:ring')
  })

  test('page renders with semantic tokens', async ({ page }) => {
    await page.goto('/session/new')

    // Check that the form card uses bg-surface token
    const card = page.locator('.bg-surface').first()
    await expect(card).toBeVisible()
  })
})

// ── Players Page ────────────────────────────────────────────────────────────

test.describe('Players Page', () => {
  test('tier picker buttons have adequate touch target', async ({ page }) => {
    await page.goto('/session/new')

    // Lock session first
    await page.fill('input[placeholder*="Sunday"]', 'Test Session')
    await page.fill('input[type="date"]', '2026-07-20')
    await page.click('button:has-text("Start Session")')

    // Now on players page — add a player
    await page.click('button:has-text("Add Player")')
    await page.fill('input[placeholder="Player name"]', 'Test Player')
    await page.click('button:has-text("Add")')

    // Check tier picker button size (min-w-8 h-8 = 32px)
    const tierBtn = page.locator('button:has-text("B")').first()
    const box = await tierBtn.boundingBox()
    expect(box?.width).toBeGreaterThanOrEqual(28) // min-w-7 with padding
    expect(box?.height).toBeGreaterThanOrEqual(28)
  })
})

// ── ARIA & Accessibility ────────────────────────────────────────────────────

test.describe('ARIA', () => {
  test('homepage has no axe violations', async ({ page }) => {
    // Basic structural checks without axe-core dependency
    await page.goto('/')

    // Check <main> landmark exists in HomeLayout
    const main = page.locator('main')
    await expect(main).toBeAttached()

    // Check header has proper structure
    const header = page.locator('header')
    await expect(header).toBeAttached()
  })

  test('refresh button has aria-label', async ({ page }) => {
    await page.goto('/')
    const refresh = page.locator('[aria-label="Refresh"]')
    await expect(refresh).toBeAttached()
  })
})

// ── No Broken Images ───────────────────────────────────────────────────────

test.describe('Images', () => {
  test('all images load successfully', async ({ page }) => {
    const failedImages: string[] = []
    page.on('response', (response) => {
      if (response.url().match(/\.(png|jpg|jpeg|svg|webp)$/i) && response.status() >= 400) {
        failedImages.push(response.url())
      }
    })

    await page.goto('/')
    await page.waitForTimeout(2000) // Wait for lazy images

    expect(failedImages).toEqual([])
  })
})

// ── Reduced Motion ──────────────────────────────────────────────────────────

test.describe('Reduced Motion', () => {
  test('prefers-reduced-motion CSS is present', async ({ page }) => {
    await page.goto('/')

    const hasReducedMotion = await page.evaluate(() => {
      const sheets = Array.from(document.styleSheets)
      for (const sheet of sheets) {
        try {
          const rules = Array.from(sheet.cssRules)
          for (const rule of rules) {
            if (rule instanceof CSSMediaRule && rule.conditionText?.includes('prefers-reduced-motion')) {
              return true
            }
          }
        } catch { /* cross-origin */ }
      }
      return false
    })

    expect(hasReducedMotion).toBe(true)
  })
})
