const tournamentId = 'tournament-2026-05-23-majadu'

function getEnv(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Missing required env: ${name}`)
  }
  return value
}

function rpcUrl(baseUrl, name) {
  return `${baseUrl}/rest/v1/rpc/${name}`
}

function rpcHeaders(key) {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'Accept-Profile': 'bm',
    'Content-Profile': 'bm',
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

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function gameKeyOf(entry) {
  return `${entry.slot}-${entry.court}`
}

function withVersion(snapshot, version) {
  return { ...clone(snapshot), version }
}

async function publishSession(baseUrl, key, id, snapshot) {
  return await callRpc(baseUrl, key, 'publish_session', { p_id: id, p_snapshot: snapshot })
}

async function getSession(baseUrl, key, id) {
  return await callRpc(baseUrl, key, 'get_session', { p_id: id })
}

async function publishTournament(baseUrl, key, id, snapshot) {
  return await callRpc(baseUrl, key, 'publish_tournament', { p_id: id, p_snapshot: snapshot })
}

async function getTournament(baseUrl, key, id) {
  return await callRpc(baseUrl, key, 'get_tournament', { p_id: id })
}

function chooseSessionId(sessions) {
  const preferred = process.env.SMOKE_SESSION_ID
  if (preferred) return preferred

  const richSession = sessions.find((session) => session.total_games > 0 && session.player_count >= 4)
  return richSession?.id ?? sessions[0]?.id ?? null
}

function buildAbsentMutation(snapshot) {
  const next = clone(snapshot)
  const firstPlayerId = next.players[0]?.id
  assert(firstPlayerId, 'session must have at least one player for absent mutation')

  const absent = new Set(next.absentPlayers ?? [])
  if (absent.has(firstPlayerId)) absent.delete(firstPlayerId)
  else absent.add(firstPlayerId)

  next.absentPlayers = Array.from(absent)
  return next
}

function buildSwapMutation(snapshot) {
  const next = clone(snapshot)
  const firstGame = next.schedule[0]
  assert(firstGame, 'session must have at least one scheduled game for swap mutation')
  const a0 = firstGame.teamA[0]
  const b0 = firstGame.teamB[0]
  firstGame.teamA[0] = b0
  firstGame.teamB[0] = a0
  return next
}

function buildScoreMutation(snapshot) {
  const next = clone(snapshot)
  const firstGame = next.schedule[0]
  assert(firstGame, 'session must have at least one scheduled game for score mutation')
  const key = gameKeyOf(firstGame)

  const played = new Set(next.playedGames ?? [])
  played.add(key)
  next.playedGames = Array.from(played)

  next.gameScores = {
    ...(next.gameScores ?? {}),
    [key]: { a: 30, b: 27 },
  }

  return next
}

function buildTournamentMutation(snapshot) {
  const next = clone(snapshot)
  assert(Array.isArray(next.matches) && next.matches.length > 0, 'tournament must have matches to mutate')

  const target = next.matches.find((match) => match.phase === 'group') ?? next.matches[0]
  assert(target, 'tournament must have a mutable match')

  const currentA = typeof target.scoreA === 'number' ? target.scoreA : 0
  const currentB = typeof target.scoreB === 'number' ? target.scoreB : 0

  target.scoreA = currentA === 30 && currentB === 27 ? 30 : 30
  target.scoreB = currentA === 30 && currentB === 27 ? 26 : 27

  return next
}

async function runSessionWriteflows(baseUrl, key, sessionId) {
  const original = await getSession(baseUrl, key, sessionId)
  assert(original && typeof original === 'object', 'session snapshot must load for writeflow test')
  assert(typeof original.version === 'number', 'session snapshot must include version')

  let current = original

  try {
    current = await publishSession(baseUrl, key, sessionId, withVersion(current, current.version))
    assert(current.version === original.version + 1, 'session republish must increment version')

    current = await publishSession(baseUrl, key, sessionId, withVersion(buildAbsentMutation(current), current.version))
    current = await publishSession(baseUrl, key, sessionId, withVersion(buildSwapMutation(current), current.version))
    current = await publishSession(baseUrl, key, sessionId, withVersion(buildScoreMutation(current), current.version))

    const statsName = current.players[0]?.name
    assert(statsName, 'session must have player for stats lookup')
    const stats = await callRpc(baseUrl, key, 'get_player_stats', { p_name: statsName })
    assert(stats && typeof stats === 'object', 'get_player_stats must return an object')
    assert(Array.isArray(stats.sessions), 'player stats must include sessions')

    const reloaded = await getSession(baseUrl, key, sessionId)
    assert(reloaded.version === current.version, 'reloaded session must match latest published version')

    return {
      sessionId,
      initialVersion: original.version,
      finalVersion: current.version,
    }
  } finally {
    const latest = await getSession(baseUrl, key, sessionId)
    await publishSession(baseUrl, key, sessionId, withVersion(original, latest.version))
  }
}

async function runTournamentWriteflows(baseUrl, key) {
  const original = await getTournament(baseUrl, key, tournamentId)
  assert(original && typeof original === 'object', 'tournament snapshot must load for writeflow test')
  assert(typeof original.version === 'number', 'tournament snapshot must include version')

  let current = original

  try {
    current = await publishTournament(baseUrl, key, tournamentId, withVersion(current, current.version))
    assert(current.version === original.version + 1, 'tournament republish must increment version')

    current = await publishTournament(
      baseUrl,
      key,
      tournamentId,
      withVersion(buildTournamentMutation(current), current.version),
    )

    const reloaded = await getTournament(baseUrl, key, tournamentId)
    assert(reloaded.version === current.version, 'reloaded tournament must match latest published version')

    return {
      tournamentId,
      initialVersion: original.version,
      finalVersion: current.version,
    }
  } finally {
    const latest = await getTournament(baseUrl, key, tournamentId)
    await publishTournament(baseUrl, key, tournamentId, withVersion(original, latest.version))
  }
}

async function main() {
  const baseUrl = getEnv('VITE_SUPABASE_URL')
  const key = getEnv('VITE_SUPABASE_KEY')

  const sessions = await callRpc(baseUrl, key, 'list_sessions', {})
  assert(Array.isArray(sessions) && sessions.length > 0, 'list_sessions must return at least one session')

  const sessionId = chooseSessionId(sessions)
  assert(sessionId, 'could not choose session id for writeflow smoke')

  const sessionResult = await runSessionWriteflows(baseUrl, key, sessionId)
  const tournamentResult = await runTournamentWriteflows(baseUrl, key)

  console.log(
    JSON.stringify(
      {
        ok: true,
        session: sessionResult,
        tournament: tournamentResult,
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
