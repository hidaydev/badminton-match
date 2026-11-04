## Group schedule, day-of draw placement and editor diffing.
##
## Ported from the deleted v1 web generator recovered from git history
## (00e2150^:apps/web/src/utils/teamTournament.ts); the fixed draw comes from
## `generateTeamDraw` and the final constructor mirrors the team page's
## "Buat final" action. The v1 schedule is fixed, so no randomness is ported.

import std/[options, tables]
import ./team

type
  TeamDrawItem* = object
    teamA*: string
    teamB*: string
    court*: string

const
  # One court entry per partai, all three equal in the editor.
  DefaultTeamCourts* = ["Court 12", "Court 13", "Court 14"]

  # Fixed draw over slot indices: 3 sessions x 3 courts, every team plays
  # three times and no pairing repeats.
  GroupDrawSlots = [
    (0, 1, "Court 12"), (2, 3, "Court 13"), (4, 5, "Court 14"),
    (3, 5, "Court 12"), (0, 2, "Court 13"), (1, 4, "Court 14"),
    (2, 4, "Court 12"), (1, 5, "Court 13"), (0, 3, "Court 14")]

proc generateGroupDraw*(teamIds: seq[string]): seq[TeamDrawItem] =
  ## The fixed nine-match group schedule, with team ids taken in draw-slot
  ## order (slot 0..5). Raises ValueError for any team count but six, exactly
  ## like the client generator.
  if teamIds.len != 6:
    raise newException(ValueError, "a group draw needs exactly 6 teams")
  for slot in GroupDrawSlots:
    result.add(TeamDrawItem(teamA: teamIds[slot[0]], teamB: teamIds[slot[1]],
      court: slot[2]))

proc drawGroupMatches*(teamIds: seq[string]): seq[TeamMatch] =
  ## The client's "Undian" action: nine unscored group team-matches whose three
  ## court slots all carry the draw's court for that pairing.
  let draw = generateGroupDraw(teamIds)
  for index, item in draw:
    result.add(TeamMatch(id: "g-" & $(index + 1), phase: tpGroup,
      teamA: item.teamA, teamB: item.teamB,
      partai: newSeq[TeamPartai](3),
      courts: [item.court, item.court, item.court]))

proc finalMatch*(teamA, teamB: string): TeamMatch =
  ## The final is a single team-match on Court 12, with three unplayed partai.
  TeamMatch(id: "final", phase: tpFinal, teamA: teamA, teamB: teamB,
    partai: newSeq[TeamPartai](3),
    courts: [DefaultTeamCourts[0], DefaultTeamCourts[0],
      DefaultTeamCourts[0]])

proc buildTeamsByDraw*(teams: seq[TeamInfo],
                       slotToNamed: seq[int]): seq[TeamInfo] =
  ## Day-of draw: `slotToNamed[slot]` is the canonical team name index that
  ## takes that slot. The whole entry moves (new id "t{slot+1}", canonical
  ## name, roster), so a roster always follows its name. Unknown indices are
  ## skipped, as in the client.
  var rosters = initTable[string, seq[TeamPlayer]]()
  for team in teams:
    rosters[team.name] = team.players
  for slot, named in slotToNamed:
    if named < 0 or named >= TeamNames.len:
      continue
    let name = TeamNames[named]
    result.add(TeamInfo(id: "t" & $(slot + 1), name: name,
      players: rosters.getOrDefault(name)))

proc teamMatchDirty*(local: TeamMatch, server: Option[TeamMatch]): bool =
  ## True when the editor copy differs from the server copy in courts or any
  ## partai score. A team-match that is not on the server yet is always dirty.
  if server.isNone:
    return true
  let remote = server.get
  if local.courts != remote.courts:
    return true
  if local.partai.len != remote.partai.len:
    return true
  for index in 0 ..< local.partai.len:
    if local.partai[index].scoreA != remote.partai[index].scoreA:
      return true
    if local.partai[index].scoreB != remote.partai[index].scoreB:
      return true
  false
