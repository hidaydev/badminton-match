## Group draw, bracket propagation and standings for the classic format.
##
## Ported from the deleted v1 web client recovered from git history
## (00e2150^:apps/web/src/utils/): `generateGroupMatches`, `initKnockoutMatches`,
## `propagateBracket` and `computeGroupStandings` live in tournament.ts, while
## `tallyMatch` and `standardStandingSort` live in tally.ts.
##
## Seeding note: v1 never seeded its shuffle. The wizard drew groups with
## `shuffle` from array.ts — a plain Fisher-Yates (`i` from `length - 1` down to
## 1, `j = floor(Math.random() * (i + 1))`) driven by the browser's
## `Math.random()`, so the same pairs could land differently on every draw.
## `drawGroups` keeps the algorithm and makes it reproducible by taking an
## explicit seed and using std/random's Mersenne Twister, whose `shuffle` runs
## the same descending loop with `j` uniform in `0..i`. Identical input and seed
## therefore always produce an identical draw; the seed itself is the caller's
## (the v1 equivalent is `Math.random()`, which has no seed to recover).

import std/[options, random, tables]
import ./classic

type
  ClassicStanding* = object
    ## Mirror of the v1 `TallyRow` plus the pair id.
    pairId*: string
    wins*: int
    losses*: int
    pointsFor*: int
    pointsAgainst*: int
    diff*: int

proc tallyMatch(row: var ClassicStanding, scoreFor, scoreAgainst: int) =
  ## v1 scores every non-win as a loss; a tie is impossible after validation.
  if scoreFor > scoreAgainst:
    row.wins.inc
  else:
    row.losses.inc
  row.pointsFor += scoreFor
  row.pointsAgainst += scoreAgainst

proc compareRows(a, b: ClassicStanding): int =
  ## `standardStandingSort`: wins, then point difference, then points for.
  result = cmp(b.wins, a.wins)
  if result != 0:
    return
  result = cmp(b.diff, a.diff)
  if result != 0:
    return
  result = cmp(b.pointsFor, a.pointsFor)

proc headToHead(a, b: ClassicStanding, groupMatches: seq[ClassicMatch]): int =
  ## v1 walks the group matches in order and uses the first meeting between the
  ## two rows; an unscored meeting leaves the order untouched.
  for match in groupMatches:
    if match.pairAId.isNone or match.pairBId.isNone:
      continue
    let pairA = match.pairAId.get
    let pairB = match.pairBId.get
    let between = (pairA == a.pairId and pairB == b.pairId) or
      (pairA == b.pairId and pairB == a.pairId)
    if not between:
      continue
    if match.scoreA.isNone or match.scoreB.isNone:
      return 0
    let aWon = if pairA == a.pairId:
      match.scoreA.get > match.scoreB.get
    else:
      match.scoreB.get > match.scoreA.get
    return if aWon: -1 else: 1
  0

proc compareRowsWith(a, b: ClassicStanding,
                     groupMatches: seq[ClassicMatch]): int =
  ## `standardStandingSort`, then v1's head-to-head fallback.
  result = compareRows(a, b)
  if result != 0:
    return
  result = headToHead(a, b, groupMatches)

proc sortStandings(rows: var seq[ClassicStanding],
                   groupMatches: seq[ClassicMatch]) =
  ## Insertion sort over at most four rows: it is stable, so a full tie keeps
  ## the group input order the way v1's `Array.sort` did.
  for index in 1 ..< rows.len:
    var cursor = index
    while cursor > 0 and
          compareRowsWith(rows[cursor - 1], rows[cursor], groupMatches) > 0:
      swap(rows[cursor - 1], rows[cursor])
      cursor.dec

proc computeGroupStandings*(groupId: GroupId, pairIds: seq[string],
                            matches: seq[ClassicMatch]): seq[ClassicStanding] =
  ## Standings for one group. Unplayed matches count for nothing, and a match
  ## whose pair is not in `pairIds` is ignored, exactly like the v1 client.
  var groupMatches: seq[ClassicMatch] = @[]
  for match in matches:
    if match.phase == cpGroup and match.groupId == some(groupId):
      groupMatches.add(match)
  var rows = initTable[string, ClassicStanding]()
  var order: seq[string] = @[]
  for pairId in pairIds:
    if rows.hasKey(pairId):
      continue
    rows[pairId] = ClassicStanding(pairId: pairId)
    order.add(pairId)
  for match in groupMatches:
    if match.scoreA.isNone or match.scoreB.isNone:
      continue
    if match.pairAId.isNone or match.pairBId.isNone:
      continue
    let aId = match.pairAId.get
    let bId = match.pairBId.get
    if not rows.hasKey(aId) or not rows.hasKey(bId):
      continue
    var a = rows[aId]
    var b = rows[bId]
    tallyMatch(a, match.scoreA.get, match.scoreB.get)
    tallyMatch(b, match.scoreB.get, match.scoreA.get)
    rows[aId] = a
    rows[bId] = b
  for pairId in order:
    var row = rows[pairId]
    row.diff = row.pointsFor - row.pointsAgainst
    result.add(row)
  sortStandings(result, groupMatches)

proc computeStandings*(tournament: ClassicTournament,
                       groupId: GroupId): seq[ClassicStanding] =
  ## Convenience wrapper over the tournament snapshot's own group membership.
  computeGroupStandings(groupId, tournament.groups[ord(groupId)],
    tournament.matches)

proc generateGroupMatches*(groupId: GroupId,
                           pairIds: seq[string]): seq[ClassicMatch] =
  ## The six-match round robin for one group, ids fixed by slot order.
  if pairIds.len != GroupSize:
    raise newException(ValueError, "a classic group needs exactly 4 pairs")
  for index, slot in RoundRobin:
    result.add(ClassicMatch(id: groupMatchId(groupId, index), phase: cpGroup,
      groupId: some(groupId), pairAId: some(pairIds[slot[0]]),
      pairBId: some(pairIds[slot[1]])))

proc initKnockoutMatches*(): seq[ClassicMatch] =
  ## The eight knockout slots with no pair references and no scores yet.
  for id in QfIds:
    result.add(ClassicMatch(id: id, phase: cpQf))
  for id in SfIds:
    result.add(ClassicMatch(id: id, phase: cpSf))
  result.add(ClassicMatch(id: ThirdPlaceId, phase: cpThird))
  result.add(ClassicMatch(id: FinalId, phase: cpFinal))

proc drawGroups*(pairIds: seq[string], seed: int64): array[4, seq[string]] =
  ## v1 `drawGroups`: shuffle the 16 pair ids, then cut the result into four
  ## consecutive chunks of four (A, B, C, D).
  if pairIds.len != PairCount:
    raise newException(ValueError, "a classic draw needs exactly 16 pairs")
  var shuffled = pairIds
  var rng = initRand(seed)
  shuffle(rng, shuffled)
  for index, pairId in shuffled:
    result[index div GroupSize].add(pairId)

proc matchById(matches: seq[ClassicMatch], id: string): Option[ClassicMatch] =
  for match in matches:
    if match.id == id:
      return some(match)
  none(ClassicMatch)

proc winnerOf(matches: seq[ClassicMatch], id: string): Option[string] =
  let match = matchById(matches, id)
  if match.isNone:
    return none(string)
  matchWinner(match.get)

proc loserOf(matches: seq[ClassicMatch], id: string): Option[string] =
  let match = matchById(matches, id)
  if match.isNone:
    return none(string)
  matchLoser(match.get)

proc updateMatch(matches: var seq[ClassicMatch], id: string,
                 pairA, pairB: Option[string]) =
  ## v1 `update`: changing either side clears the score; an unchanged pairing
  ## keeps it.
  for match in matches.mitems:
    if match.id != id:
      continue
    if match.pairAId != pairA or match.pairBId != pairB:
      match.scoreA = none(int)
      match.scoreB = none(int)
    match.pairAId = pairA
    match.pairBId = pairB

proc slotPair(rows: seq[ClassicStanding], index: int): Option[string] =
  if index < 0 or index >= rows.len:
    none(string)
  else:
    some(rows[index].pairId)

proc propagateBracket*(matches: seq[ClassicMatch],
                       groups: array[4, seq[string]]): seq[ClassicMatch] =
  ## v1 `propagateBracket`, step for step: seed the QF from the group
  ## standings (A1-B2, C2-D1, C1-D2, A2-B1), then push winners and losers
  ## forward. Standings are computed once, before any update.
  result = matches
  let a = computeGroupStandings(ga, groups[ord(ga)], result)
  let b = computeGroupStandings(gb, groups[ord(gb)], result)
  let c = computeGroupStandings(gc, groups[ord(gc)], result)
  let d = computeGroupStandings(gd, groups[ord(gd)], result)
  updateMatch(result, QfIds[0], slotPair(a, 0), slotPair(b, 1))
  updateMatch(result, QfIds[1], slotPair(c, 1), slotPair(d, 0))
  updateMatch(result, QfIds[2], slotPair(c, 0), slotPair(d, 1))
  updateMatch(result, QfIds[3], slotPair(a, 1), slotPair(b, 0))
  updateMatch(result, SfIds[0], winnerOf(result, QfIds[0]),
    winnerOf(result, QfIds[1]))
  updateMatch(result, SfIds[1], winnerOf(result, QfIds[2]),
    winnerOf(result, QfIds[3]))
  updateMatch(result, FinalId, winnerOf(result, SfIds[0]),
    winnerOf(result, SfIds[1]))
  updateMatch(result, ThirdPlaceId, loserOf(result, SfIds[0]),
    loserOf(result, SfIds[1]))

proc generateTournament*(name, date: string, pairs: seq[Pair],
                         seed: int64): ClassicTournament =
  ## A complete, unscored snapshot: drawn groups, 24 group matches, the
  ## knockout skeleton, and QF references seeded from the initial standings.
  ## With no score every row is tied, so the stable sort keeps the group order
  ## and the QF slots resolve to A1/B2, C2/D1, C1/D2 and A2/B1 — the same result
  ## the v1 wizard got from propagating an empty bracket.
  var pairIds: seq[string] = @[]
  for pair in pairs:
    pairIds.add(pair.id)
  let groups = drawGroups(pairIds, seed)
  var matches: seq[ClassicMatch] = @[]
  for groupId in GroupIds:
    matches.add generateGroupMatches(groupId, groups[ord(groupId)])
  matches.add initKnockoutMatches()
  ClassicTournament(version: none(int), name: name, date: date, pairs: pairs,
    groups: groups, matches: propagateBracket(matches, groups))
