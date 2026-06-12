import { neon } from '@neondatabase/serverless'
import { readFileSync } from 'fs'

// Load env from .env.local
const envFile = readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
for (const line of envFile.split('\n')) {
  const [key, ...rest] = line.split('=')
  if (key && rest.length) process.env[key.trim()] = rest.join('=').trim()
}

const APPS_SCRIPT_URL = process.env.VITE_APPS_SCRIPT_URL
const sql = neon(process.env.DATABASE_URL)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function fetchJson(url, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(url)
      const text = await res.text()
      if (!text.startsWith('{') && !text.startsWith('[')) {
        console.log(`  Non-JSON response (attempt ${i + 1}), retrying in 3s...`)
        await sleep(3000)
        continue
      }
      return JSON.parse(text)
    } catch (e) {
      if (i === retries - 1) throw e
      console.log(`  Fetch error (attempt ${i + 1}), retrying in 3s...`)
      await sleep(3000)
    }
  }
}

async function migrateSession(id) {
  console.log(`  Migrating session ${id}...`)
  const { ok, data } = await fetchJson(`${APPS_SCRIPT_URL}?id=${encodeURIComponent(id)}`)
  if (!ok || !data) { console.log(`  SKIP ${id} — not found`); return }

  const s = data.session
  const now = new Date().toISOString()

  await sql`
    INSERT INTO sessions (id, title, date, session_start, slot_minutes, slots_per_court, court_names, court_times, tier_count, created_at, updated_at)
    VALUES (${id}, ${s.title}, ${s.date}, ${s.sessionStart}, ${s.slotMinutes},
      ${s.slotsPerCourt}, ${s.courtNames ?? []}, ${JSON.stringify(s.courtTimes)},
      ${s.tierCount ?? 4}, ${now}, ${now})
    ON CONFLICT (id) DO NOTHING
  `

  for (const p of data.players ?? []) {
    await sql`
      INSERT INTO session_players (id, session_id, name, gender, tier)
      VALUES (${p.id}, ${id}, ${p.name}, ${p.gender}, ${p.tier})
      ON CONFLICT (id) DO NOTHING
    `
  }

  const playedSet = new Set(data.playedGames ?? [])
  for (const g of data.schedule ?? []) {
    const gid = `${id}-${g.slot}-${g.court}`
    const key = `${g.slot}-${g.court}`
    const score = data.gameScores?.[key]
    const played = playedSet.has(key)
    await sql`
      INSERT INTO games (id, session_id, slot, court, team_a_p1, team_a_p2, team_b_p1, team_b_p2, played, score_a, score_b)
      VALUES (${gid}, ${id}, ${g.slot}, ${g.court}, ${g.teamA[0]}, ${g.teamA[1]}, ${g.teamB[0]}, ${g.teamB[1]},
        ${played}, ${score?.a ?? null}, ${score?.b ?? null})
      ON CONFLICT (id) DO NOTHING
    `
  }

  for (const fm of data.fixMatches ?? []) {
    await sql`
      INSERT INTO fix_matches (id, session_id, slots) VALUES (${fm.id}, ${id}, ${fm.slots})
      ON CONFLICT (id) DO NOTHING
    `
  }

  for (const playerId of data.absentPlayers ?? []) {
    await sql`
      INSERT INTO absent_players (session_id, player_id) VALUES (${id}, ${playerId})
      ON CONFLICT DO NOTHING
    `
  }

  console.log(`  ✓ ${id} — ${data.schedule?.length ?? 0} games, ${data.players?.length ?? 0} players`)
}

async function main() {
  console.log('Fetching session list from Apps Script...')
  const { ok, data: sessions } = await fetchJson(`${APPS_SCRIPT_URL}?action=list`)
  if (!ok) throw new Error('Failed to list sessions')
  console.log(`Found ${sessions.length} sessions`)

  for (const meta of sessions) {
    await migrateSession(meta.id)
    await sleep(1500)
  }

  // Migrate tournament
  const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'
  console.log(`\nMigrating tournament ${TOURNAMENT_ID}...`)
  const { ok: tok, data: tdata } = await fetchJson(
    `${APPS_SCRIPT_URL}?action=getTournament&id=${encodeURIComponent(TOURNAMENT_ID)}`
  )
  if (tok && tdata) {
    const now = new Date().toISOString()
    await sql`
      INSERT INTO tournaments (id, data, created_at, updated_at)
      VALUES (${TOURNAMENT_ID}, ${JSON.stringify(tdata)}, ${now}, ${now})
      ON CONFLICT (id) DO NOTHING
    `
    console.log('✓ Tournament migrated')
  } else {
    console.log('No tournament data found, skipping')
  }

  console.log('\nMigration complete!')
}

main().catch((e) => { console.error(e); process.exit(1) })
