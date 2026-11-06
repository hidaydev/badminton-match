## Classic tournament rules, frozen from v1.
##
## Structural invariants come from the Go validator
## (apps/api/internal/domain/tournament.go, a port of
## bm.validate_tournament_snapshot). Bracket wiring comes from the deleted web
## generator recovered from git history
## (00e2150^:apps/web/src/utils/tournament.ts, `propagateBracket`). Anything the
## v1 client computed but the Go validator does not check (QF seeding from the
## group standings) is generated in classic_draw but not enforced here.
##
## v1 snapshot shape: 16 pairs, four groups A-D (0 or 4 pairs each), and
## exactly 32 matches — 24 group, 4 qf, 2 sf, 1 third-place, 1 final. Knockout
## pair references stay nullable until the feeder matches are decided.

import std/[options, strutils]
import player/domain/player

type
  GroupId* = enum
    ga = "A"
    gb = "B"
    gc = "C"
    gd = "D"

  ClassicPhase* = enum
    cpGroup = "group"
    cpQf = "qf"
    cpSf = "sf"
    cpThird = "3rd"
    cpFinal = "final"

  Pair* = object
    id*: string
    name*: string

  ClassicMatch* = object
    ## Both scores absent means unplayed. A knockout match keeps empty pair
    ## references until its feeder is decided (v1 `pairAId: string | null`).
    id*: string
    phase*: ClassicPhase
    groupId*: Option[GroupId]
    pairAId*: Option[string]
    pairBId*: Option[string]
    scoreA*: Option[int]
    scoreB*: Option[int]
    picName*: Option[string]

  ClassicTournament* = object
    version*: Option[int]
    name*: string
    date*: string
    pairs*: seq[Pair]
    ## Indexed by GroupId ord: A, B, C, D.
    groups*: array[4, seq[string]]
    matches*: seq[ClassicMatch]

  ClassicIssueKind* = enum
    ciBlankName = "blank_name"
    ciBlankDate = "blank_date"
    ciInvalidDate = "invalid_date"
    ciPairCount = "pair_count"
    ciBlankPairId = "blank_pair_id"
    ciBlankPairName = "blank_pair_name"
    ciDuplicatePairId = "duplicate_pair_id"
    ciDuplicatePairName = "duplicate_pair_name"
    ciDuplicatePairPlayer = "duplicate_pair_player"
    ciPairNameParts = "pair_name_parts"
    ciGroupSize = "group_size"
    ciUnknownGroupPair = "unknown_group_pair"
    ciDuplicateGroupPair = "duplicate_group_pair"
    ciMatchCount = "match_count"
    ciBlankMatchId = "blank_match_id"
    ciDuplicateMatchId = "duplicate_match_id"
    ciPhaseCount = "phase_count"
    ciPairReference = "pair_reference"
    ciSelfMatch = "self_match"
    ciPartialScore = "partial_score"
    ciNegativeScore = "negative_score"
    ciScoreTooHigh = "score_too_high"
    ciTiedMatch = "tied_match"
    ciBracketProgression = "bracket_progression"

  ClassicIssue* = object
    kind*: ClassicIssueKind
    detail*: string

const
  GroupIds* = [ga, gb, gc, gd]
  QfIds* = ["qf-1", "qf-2", "qf-3", "qf-4"]
  SfIds* = ["sf-1", "sf-2"]
  ThirdPlaceId* = "3rd-1"
  FinalId* = "final-1"

  PairCount* = 16
  GroupSize* = 4
  GroupMatchCount* = 24
  MatchCount* = 32

  # v1 round-robin over the four group slots; the order fixes the match ids.
  RoundRobin*: array[6, array[2, int]] = [
    [0, 1], [2, 3], [0, 2], [1, 3], [0, 3], [1, 2]]

  # v1 daily score guard (domain/transform.go ValidateScore and the
  # matches_score_range check in the database).
  MaxScore* = 99

proc pairNameParts*(display: string): seq[string] =
  ## The pair display name is "A & B" (also "vs", "," or "/"). This is the one
  ## splitter both the store and the validator use, so what is validated is
  ## exactly what gets resolved into players.
  var cleaned = display
  for separator in [" & ", " vs ", " VS ", ",", "/"]:
    cleaned = cleaned.replace(separator, "|")
  for part in cleaned.split('|'):
    if part.strip().len > 0:
      result.add(part.strip())

proc splitPairNames*(display: string): (string, string) =
  ## v1 registered the players it could split; the schema needs two, so a lone
  ## name is paired with a deterministic second label instead of leaving a
  ## NOT NULL hole.
  let names = pairNameParts(display)
  if names.len == 0:
    return ("TBD A", "TBD B")
  if names.len == 1:
    return (names[0], names[0] & " #2")
  if normalizeName(names[0]).toLowerAscii() ==
     normalizeName(names[1]).toLowerAscii():
    return (names[0], names[1] & " #2")
  (names[0], names[1])

proc groupMatchId*(groupId: GroupId, index: int): string =
  ## Group match ids are positional, exactly like the v1 generator:
  ## group-A-0 … group-D-5.
  "group-" & $groupId & "-" & $index

proc matchDecided*(match: ClassicMatch): bool =
  ## v1 `getMatchWinner` only reads a match when both scores and both pair
  ## references are present.
  match.scoreA.isSome and match.scoreB.isSome and
    match.pairAId.isSome and match.pairAId.get.strip().len > 0 and
    match.pairBId.isSome and match.pairBId.get.strip().len > 0

proc matchWinner*(match: ClassicMatch): Option[string] =
  ## v1 resolves anything that is not an A win in favour of B, so an impossible
  ## tie also yields B; validation is the gate that keeps such input out.
  if not matchDecided(match):
    return none(string)
  if match.scoreA.get > match.scoreB.get:
    some(match.pairAId.get)
  else:
    some(match.pairBId.get)

proc matchLoser*(match: ClassicMatch): Option[string] =
  ## Mirror of `getMatchLoser`: anything that is not an A loss goes to B.
  if not matchDecided(match):
    return none(string)
  if match.scoreA.get < match.scoreB.get:
    some(match.pairAId.get)
  else:
    some(match.pairBId.get)

proc isLeapYear(year: int): bool =
  (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0

proc isIsoDate(value: string): bool =
  ## Go parses the tournament date with the layout 2006-01-02, so the same
  ## shape and the same calendar limits apply.
  if value.len != 10 or value[4] != '-' or value[7] != '-':
    return false
  for index in 0 ..< value.len:
    if index == 4 or index == 7:
      continue
    if value[index] notin {'0' .. '9'}:
      return false
  let year = parseInt(value[0 ..< 4])
  let month = parseInt(value[5 ..< 7])
  let day = parseInt(value[8 ..< 10])
  if month < 1 or month > 12:
    return false
  const monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  var lastDay = monthDays[month - 1]
  if month == 2 and isLeapYear(year):
    lastDay = 29
  day >= 1 and day <= lastDay

proc addIssue(issues: var seq[ClassicIssue], kind: ClassicIssueKind,
              detail = "") =
  issues.add(ClassicIssue(kind: kind, detail: detail))

proc validateIdentity(tournament: ClassicTournament,
                      issues: var seq[ClassicIssue]) =
  if normalizeName(tournament.name).len == 0:
    issues.addIssue(ciBlankName)
  # v1 checks the raw value for blank, then parses; a whitespace-only date is
  # therefore reported as an invalid date rather than a blank one.
  if tournament.date.len == 0:
    issues.addIssue(ciBlankDate)
  elif not isIsoDate(tournament.date):
    issues.addIssue(ciInvalidDate, tournament.date)

proc validatePairs(pairs: seq[Pair], issues: var seq[ClassicIssue]) =
  if pairs.len != PairCount:
    issues.addIssue(ciPairCount, $pairs.len)
  var seen: seq[string] = @[]
  var seenNames: seq[string] = @[]
  var seenPlayers: seq[string] = @[]
  for pair in pairs:
    if pair.id.strip().len == 0:
      issues.addIssue(ciBlankPairId)
    elif pair.id in seen:
      issues.addIssue(ciDuplicatePairId, pair.id)
    else:
      seen.add(pair.id)
    # normalizeName collapses whitespace, so a name of spaces counts as blank.
    let name = normalizeName(pair.name)
    if name.len == 0:
      issues.addIssue(ciBlankPairName, pair.id)
    else:
      # Two pairs with the same display name resolve to the same players, which
      # put one player on both sides of every match and doubled their games.
      let key = name.toLowerAscii()
      if key in seenNames:
        issues.addIssue(ciDuplicatePairName, pair.name)
      else:
        seenNames.add(key)
    # A display name resolves through the same splitter the store uses; a name
    # with three parts would silently lose one, and the same player may not be
    # registered in two pairs.
    let parts = pairNameParts(pair.name)
    if parts.len > 2:
      issues.addIssue(ciPairNameParts, pair.name)
    let (firstPlayer, secondPlayer) = splitPairNames(pair.name)
    for playerName in [firstPlayer, secondPlayer]:
      let key = normalizeName(playerName).toLowerAscii()
      if key.len == 0:
        continue
      if key in seenPlayers:
        issues.addIssue(ciDuplicatePairPlayer, playerName)
      else:
        seenPlayers.add(key)

proc validateGroups(groups: array[4, seq[string]], pairIds: seq[string],
                    issues: var seq[ClassicIssue]) =
  ## Each group holds either nobody (before the draw) or four distinct pairs.
  ## v1 does not require every pair to be assigned, so an all-empty snapshot is
  ## structurally legal.
  var grouped: seq[string] = @[]
  for groupId in GroupIds:
    let members = groups[ord(groupId)]
    if members.len != 0 and members.len != GroupSize:
      issues.addIssue(ciGroupSize, $groupId & ": " & $members.len)
    for pairId in members:
      if pairId.strip().len == 0 or pairId notin pairIds:
        issues.addIssue(ciUnknownGroupPair, $groupId & ": " & pairId)
      elif pairId in grouped:
        issues.addIssue(ciDuplicateGroupPair, pairId)
      else:
        grouped.add(pairId)

proc validateMatchIds(matches: seq[ClassicMatch],
                      issues: var seq[ClassicIssue]) =
  var seen: seq[string] = @[]
  for match in matches:
    if match.id.strip().len == 0:
      issues.addIssue(ciBlankMatchId)
    elif match.id in seen:
      issues.addIssue(ciDuplicateMatchId, match.id)
    else:
      seen.add(match.id)

proc validatePhaseCounts(matches: seq[ClassicMatch],
                         issues: var seq[ClassicIssue]) =
  if matches.len != MatchCount:
    issues.addIssue(ciMatchCount, $matches.len)
  var counts: array[ClassicPhase, int]
  for match in matches:
    counts[match.phase].inc
  const expected = [(cpGroup, GroupMatchCount), (cpQf, 4), (cpSf, 2),
    (cpThird, 1), (cpFinal, 1)]
  for entry in expected:
    if counts[entry[0]] != entry[1]:
      issues.addIssue(ciPhaseCount, $entry[0] & ": " & $counts[entry[0]])

proc validatePairRefs(matches: seq[ClassicMatch], pairIds: seq[string],
                      issues: var seq[ClassicIssue]) =
  ## Blank references mean "not decided yet" and are not reported, exactly like
  ## the Go validator. A known reference must never face itself.
  for match in matches:
    var hasA = false
    var hasB = false
    if match.pairAId.isSome and match.pairAId.get.strip().len > 0:
      hasA = true
      if match.pairAId.get notin pairIds:
        issues.addIssue(ciPairReference, match.id & ": " & match.pairAId.get)
    if match.pairBId.isSome and match.pairBId.get.strip().len > 0:
      hasB = true
      if match.pairBId.get notin pairIds:
        issues.addIssue(ciPairReference, match.id & ": " & match.pairBId.get)
    if hasA and hasB and match.pairAId.get == match.pairBId.get:
      issues.addIssue(ciSelfMatch, match.id)

proc validateScores(match: ClassicMatch, issues: var seq[ClassicIssue]) =
  ## Both scores or neither. A decided match needs a winner (no deuce), and the
  ## v1 score guard caps both sides at 99.
  if match.scoreA.isNone and match.scoreB.isNone:
    return
  if match.scoreA.isNone or match.scoreB.isNone:
    issues.addIssue(ciPartialScore, match.id)
    return
  let scoreA = match.scoreA.get
  let scoreB = match.scoreB.get
  if scoreA < 0 or scoreB < 0:
    issues.addIssue(ciNegativeScore, match.id & ": " & $scoreA & "-" & $scoreB)
  if scoreA > MaxScore or scoreB > MaxScore:
    issues.addIssue(ciScoreTooHigh, match.id & ": " & $scoreA & "-" & $scoreB)
  if scoreA == scoreB:
    issues.addIssue(ciTiedMatch, match.id & ": " & $scoreA)

proc findMatch(matches: seq[ClassicMatch], id: string): Option[ClassicMatch] =
  for match in matches:
    if match.id == id:
      return some(match)
  none(ClassicMatch)

proc expectPairing(upstreamA, upstreamB, downstream: ClassicMatch,
                   takeLoser: bool, issues: var seq[ClassicIssue]) =
  ## A downstream slot must agree with the feeder result whenever both sides of
  ## it are already set. Unset slots are legal, mirroring the nullable pair
  ## references v1 writes before a feeder is decided.
  if downstream.pairAId.isNone or downstream.pairBId.isNone:
    return
  let first = if takeLoser: matchLoser(upstreamA) else: matchWinner(upstreamA)
  let second = if takeLoser: matchLoser(upstreamB) else: matchWinner(upstreamB)
  if first.isNone or second.isNone:
    return
  if downstream.pairAId.get != first.get or
     downstream.pairBId.get != second.get:
    issues.addIssue(ciBracketProgression, downstream.id)

proc validateSemifinals(matches: seq[ClassicMatch],
                        issues: var seq[ClassicIssue]) =
  let qf1 = findMatch(matches, QfIds[0])
  let qf2 = findMatch(matches, QfIds[1])
  let qf3 = findMatch(matches, QfIds[2])
  let qf4 = findMatch(matches, QfIds[3])
  let sf1 = findMatch(matches, SfIds[0])
  let sf2 = findMatch(matches, SfIds[1])
  if qf1.isSome and qf2.isSome and sf1.isSome:
    expectPairing(qf1.get, qf2.get, sf1.get, false, issues)
  if qf3.isSome and qf4.isSome and sf2.isSome:
    expectPairing(qf3.get, qf4.get, sf2.get, false, issues)

proc validateFinals(matches: seq[ClassicMatch], issues: var seq[ClassicIssue]) =
  let sf1 = findMatch(matches, SfIds[0])
  let sf2 = findMatch(matches, SfIds[1])
  let final = findMatch(matches, FinalId)
  let third = findMatch(matches, ThirdPlaceId)
  if sf1.isSome and sf2.isSome and final.isSome:
    expectPairing(sf1.get, sf2.get, final.get, false, issues)
  if sf1.isSome and sf2.isSome and third.isSome:
    expectPairing(sf1.get, sf2.get, third.get, true, issues)

proc validateBracketProgression(matches: seq[ClassicMatch],
                                issues: var seq[ClassicIssue]) =
  ## Wiring from v1 `propagateBracket`: sf-1 takes the qf-1/qf-2 winners, sf-2
  ## the qf-3/qf-4 winners, the final the sf winners and the third-place match
  ## the sf losers.
  validateSemifinals(matches, issues)
  validateFinals(matches, issues)

proc validate*(tournament: ClassicTournament): seq[ClassicIssue] =
  ## Every structural rule from the v1 Go validator, accumulated instead of
  ## short-circuited so a caller can report all problems in one response.
  validateIdentity(tournament, result)
  validatePairs(tournament.pairs, result)
  var pairIds: seq[string] = @[]
  for pair in tournament.pairs:
    if pair.id.strip().len > 0:
      pairIds.add(pair.id)
  validateGroups(tournament.groups, pairIds, result)
  validateMatchIds(tournament.matches, result)
  validatePhaseCounts(tournament.matches, result)
  validatePairRefs(tournament.matches, pairIds, result)
  for match in tournament.matches:
    validateScores(match, result)
  validateBracketProgression(tournament.matches, result)
