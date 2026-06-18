// scripts/post-instagram.mjs
// Automates uploading post.jpg for each date folder to Instagram feed.
//
// First run: opens a visible browser so you can log in manually,
//            then saves the session to scripts/.instagram-session.json
// Later runs: loads saved session and posts automatically.
//
// Usage:
//   node scripts/post-instagram.mjs              # post all folders that haven't been posted
//   node scripts/post-instagram.mjs --login      # force re-login
//   node scripts/post-instagram.mjs 2025-09-05   # post a single folder by date

import { chromium } from 'playwright'
import { readdir, readFile, writeFile, access } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync } from 'node:fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const BEST_DIR = '/Users/hidaydev/Downloads/Majadu/Best'
const SESSION_FILE = join(__dirname, '.instagram-session.json')
const POSTED_FILE = join(__dirname, '.instagram-posted.json')

const args = process.argv.slice(2)
const forceLogin = args.includes('--login')
const singleDate = args.find(a => /^\d{4}-\d{2}-\d{2}$/.test(a))

async function loadPosted() {
  try {
    return JSON.parse(await readFile(POSTED_FILE, 'utf8'))
  } catch {
    return {}
  }
}

async function savePosted(posted) {
  await writeFile(POSTED_FILE, JSON.stringify(posted, null, 2))
}

async function login(page) {
  console.log('\n🔑 Opening Instagram login...')
  await page.goto('https://www.instagram.com/accounts/login/', { waitUntil: 'networkidle' })

  console.log('   Please log in to Instagram in the browser window.')
  console.log('   Press Enter here once you are fully logged in...')
  await new Promise(resolve => process.stdin.once('data', resolve))

  // Confirm we're logged in by checking for home feed
  const isLoggedIn = await page.locator('svg[aria-label="Home"]').isVisible().catch(() => false)
  if (!isLoggedIn) {
    console.log('   Could not confirm login — continuing anyway.')
  } else {
    console.log('   ✓ Logged in!')
  }
}

async function uploadPost(page, imagePath, caption) {
  // Click the "New post" (+) button
  await page.goto('https://www.instagram.com/', { waitUntil: 'networkidle' })
  await page.waitForTimeout(2000)

  // Click the new-post button (the + icon in the nav)
  const newPostBtn = page.locator('svg[aria-label="New post"]').first()
  await newPostBtn.waitFor({ timeout: 15000 })
  await newPostBtn.click()
  await page.waitForTimeout(1000)

  // File input for image upload
  const fileInput = page.locator('input[type="file"]').first()
  await fileInput.waitFor({ timeout: 10000 })
  await fileInput.setInputFiles(imagePath)
  await page.waitForTimeout(2000)

  // Crop step — click "Next" (may say "Next" or show an arrow)
  const nextBtn = page.getByRole('button', { name: 'Next' })
  await nextBtn.first().waitFor({ timeout: 10000 })
  await nextBtn.first().click()
  await page.waitForTimeout(1500)

  // Filter/edit step — click "Next" again
  await nextBtn.first().waitFor({ timeout: 10000 })
  await nextBtn.first().click()
  await page.waitForTimeout(1500)

  // Caption step
  if (caption) {
    const captionBox = page.locator('div[aria-label="Write a caption..."], div[role="textbox"]').first()
    await captionBox.waitFor({ timeout: 8000 })
    await captionBox.click()
    await captionBox.fill(caption)
    await page.waitForTimeout(500)
  }

  // Share button
  const shareBtn = page.getByRole('button', { name: 'Share' })
  await shareBtn.waitFor({ timeout: 10000 })
  await shareBtn.click()

  // Wait for "Your post has been shared." or redirect
  await page.waitForURL('https://www.instagram.com/', { timeout: 30000 }).catch(() => {})
  await page.waitForTimeout(2000)
}

async function main() {
  const hasSession = !forceLogin && existsSync(SESSION_FILE)

  const browser = await chromium.launch({ headless: false, slowMo: 100 })
  const context = hasSession
    ? await browser.newContext({ storageState: SESSION_FILE })
    : await browser.newContext({ viewport: { width: 1280, height: 900 } })

  const page = await context.newPage()

  // Login if needed
  if (!hasSession || forceLogin) {
    await login(page)
    await context.storageState({ path: SESSION_FILE })
    console.log(`   Session saved to ${SESSION_FILE}`)
  }

  // Get folders to process
  let folders
  if (singleDate) {
    folders = [singleDate]
  } else {
    const all = (await readdir(BEST_DIR)).filter(f => /^\d{4}-\d{2}-\d{2}$/.test(f)).sort()
    const posted = await loadPosted()
    folders = all.filter(f => !posted[f])
    console.log(`\nFolders to post: ${folders.length} (${all.length - folders.length} already posted)`)
  }

  if (folders.length === 0) {
    console.log('Nothing to post!')
    await browser.close()
    return
  }

  const posted = await loadPosted()

  for (const folder of folders) {
    const postPath = join(BEST_DIR, folder, 'post.jpg')
    if (!existsSync(postPath)) {
      console.log(`  ✗ ${folder}: post.jpg not found, skipping`)
      continue
    }

    // Parse date for caption
    const [year, mm, dd] = folder.split('-')
    const months = ['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember']
    const monthName = months[parseInt(mm) - 1]
    const caption = `Sesi badminton ${parseInt(dd)} ${monthName} ${year} 🏸\n\n#MajaduBadminton #MajaduFun #Badminton`

    console.log(`\n  → Posting ${folder}...`)
    try {
      await uploadPost(page, postPath, caption)
      posted[folder] = new Date().toISOString()
      await savePosted(posted)
      console.log(`  ✓ ${folder} posted!`)

      // Pause between posts to avoid rate limits
      if (folders.indexOf(folder) < folders.length - 1) {
        console.log('     Waiting 30s before next post...')
        await page.waitForTimeout(30000)
      }
    } catch (err) {
      console.error(`  ✗ ${folder}: ${err.message}`)
      // Save screenshot for debugging
      await page.screenshot({ path: join(__dirname, `error-${folder}.png`) })
      console.log(`     Screenshot saved: scripts/error-${folder}.png`)
    }
  }

  await browser.close()
  console.log('\nAll done!')
}

main().catch(console.error)
