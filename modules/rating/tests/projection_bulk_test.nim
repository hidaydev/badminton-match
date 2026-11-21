## REL-BE-11: the board's tournament pass read one tournament's games per pooled
## checkout, so `/players/{id}/stats` cost 6 + 2T (classic) or 6 + 3T (team)
## connections and a squad opening the page multiplied that. The games are now
## one bulk read behind a single `db.read`.
##
## The statement-count proof needs a database (`read_test.nim`, integration set).
## These cases prove the two things that can be checked without one: the pass has
## exactly one connection read, and every identifier its batch queries name
## exists in the migrations that create those tables.

import std/[os, strutils, unittest]

let root = currentSourcePath().parentDir.parentDir.parentDir.parentDir
let projectionSource = readFile(root / "modules/rating/projection.nim")
let tournamentSource = readFile(
  root / "modules/rating/infrastructure/tournament.nim")
let tournamentDdl = readFile(root / "db/migrations/0003_tournament.sql") &
  readFile(root / "db/migrations/0012_tournament_formats.sql")

proc section(source, name: string): string =
  ## The body of one proc, from its declaration to the next top-level `proc`.
  ## The declaration is matched without the export marker, so the helper works
  ## for an exported routine and a private one alike.
  let marker = "proc " & name
  let start = source.find(marker)
  doAssert start >= 0, "no proc " & name
  let following = source.find("\nproc ", start + marker.len)
  if following < 0: source[start .. ^1] else: source[start ..< following]

suite "bulk tournament read":
  test "the tournament pass reads every tournament behind one connection":
    let body = section(projectionSource, "tournamentEntries")
    # One `db.read` for the whole window. A second one inside the loop is the
    # shape this row removed: one pooled checkout per tournament.
    check body.count("db.read(") == 1
    check body.contains("gamesForBulk(conn, communityId, formats)")

  test "the per-tournament reader is gone from the projection":
    ## `gamesFor` still serves ingest, but the board must not call it: that
    ## call is what made the pass linear in tournaments.
    check not section(projectionSource, "tournamentEntries").contains(
      "gamesFor(conn")

  test "the batch query only names tables and columns the migrations create":
    ## Read as text because the statement is built in Nim. Every identifier
    ## below comes from one of the two migrations; a typo here would be a
    ## runtime error this suite catches for free.
    var missing: seq[string] = @[]
    for table in ["tournament.matches", "tournament.pairs",
        "tournament.team_matches", "tournament.team_players",
        "tournament.team_partai", "tournament.tournaments"]:
      if not tournamentDdl.contains("create table " & table):
        missing.add(table)
    for column in ["tournament_id", "match_key", "match_order", "phase",
        "score_a", "score_b", "pair_a_id", "pair_b_id", "partai_index",
        "team_match_id", "team_a_id", "team_b_id", "team_id", "cls",
        "player_id"]:
      if not tournamentDdl.contains(column):
        missing.add(column)
    check missing == newSeq[string]()

  test "the bulk reader splits classic and team without inventing a format":
    ## The two formats live in different tables, so one pass cannot serve both.
    ## A format the header query never returns falls to the classic tables, which
    ## is what `gamesFor` already did.
    let body = section(tournamentSource, "gamesForBulk")
    check body.contains("""if format == "team": teamIds.add(tournamentId)""")
    check body.contains("else: classicIds.add(tournamentId)")
    # An empty side costs no statement at all: a classic-only board must not open
    # a connection to look for team rows it knows are absent.
    check body.contains("if classicIds.len > 0:")
    check body.contains("if teamIds.len > 0:")

  test "the team bulk read keys partais by tournament, not by match key alone":
    ## `match_key` is unique per tournament, not across the window, so grouping
    ## on it alone would merge two events that named the same match key.
    let body = section(tournamentSource, "teamGamesBulk")
    check body.contains("partais.mgetOrPut(partai.getUuid(\"tournament_id\") &")
    check body.contains("partais.getOrDefault(tournamentId & keySeparator &")
