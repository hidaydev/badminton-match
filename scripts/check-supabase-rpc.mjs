const tournamentId = 'tournament-2026-05-23-majadu'

function getEnv(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Missing required env: ${name}`)
  }
  return value
}

// Skema backend per environment: default "bm" (prod), override via env
// mis. VITE_SUPABASE_PROFILE=bm_dev untuk tes ke VPS.
const backendProfile = process.env.VITE_SUPABASE_PROFILE ?? 'bm'

function rpcUrl(baseUrl, name) {
  return `${baseUrl}/rest/v1/rpc/${name}`
}

function rpcHeaders(key) {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'Accept-Profile': backendProfile,
    'Content-Profile': backendProfile,
  }
}

async function callRpc(baseUrl, key, name, body) {
  const res = await fetch(rpcUrl(baseUrl, name), {
    method: 'POST',
    headers: rpcHeaders(key),
    body: JSON.stringify(body),
  })

  if (!res.ok) {
    const text = await res.text()
    throw new Error(`${name} failed: ${res.status} ${res.statusText} ${text}`.trim())
  }

  if (res.status === 204) return null
  return await res.json()
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

async function main() {
  const baseUrl = getEnv('VITE_SUPABASE_URL')
  const key = getEnv('VITE_SUPABASE_KEY')

  const sessions = await callRpc(baseUrl, key, 'list_sessions', {})
  assert(Array.isArray(sessions), 'list_sessions must return an array')

  const players = await callRpc(baseUrl, key, 'list_players', {})
  assert(Array.isArray(players), 'list_players must return an array')

  const tournament = await callRpc(baseUrl, key, 'get_tournament', { p_id: tournamentId })
  assert(tournament && typeof tournament === 'object', 'get_tournament must return an object')
  assert(typeof tournament.version === 'number', 'tournament snapshot must include numeric version')

  if (sessions.length > 0) {
    const session = await callRpc(baseUrl, key, 'get_session', { p_id: sessions[0].id })
    assert(session && typeof session === 'object', 'get_session must return an object')
    assert(typeof session.version === 'number', 'session snapshot must include numeric version')
    assert(Array.isArray(session.players), 'session snapshot must include players array')
    assert(Array.isArray(session.schedule), 'session snapshot must include schedule array')
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        sessions: sessions.length,
        players: players.length,
        tournament: tournamentId,
      },
      null,
      2,
    ),
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
})
