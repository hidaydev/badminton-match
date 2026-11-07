## The rows a database suite starts from, written once.
##
## Every constructor mirrors the SQL the API suites already wrote by hand, so a
## column change lands here instead of in fifty test files. This module lives
## under platform-lib and imports no `modules/*`: a suite may use it from either
## tree, and platform-lib must not start depending on the domain modules.
##
## These are constructors, not a DSL. A test that needs a row shape none of them
## can express should still write its own statement next to the case that needs
## it, because a fixture that hides its SQL hides its assumptions.

import std/options
import db/db
import sha256

proc newUser*(db: Db, sub, email: string; displayName = "",
              owner = false): string =
  ## `email_hash` is the only form of the address the schema keeps, so the
  ## caller hands over the address and this hashes it. A blank display name
  ## falls back to the subject, which is what the hand-written fixtures did.
  let name = if displayName.len > 0: displayName else: sub
  db.queryOne(
    """insert into platform.user
         (google_sub, email_hash, display_name, is_platform_owner)
       values ($1, $2, $3, $4) returning id""",
    @[textParam(sub), textParam(sha256Hex(email)), textParam(name),
      boolParam(owner)]).get.getUuid("id")

proc newCommunity*(db: Db, slug, name: string;
                   timezone = "Asia/Jakarta"): string =
  ## A bare community row. A suite that needs the first-admin invitation must
  ## still call `community_store.create`, because that rule is the module's, not
  ## a fixture's.
  db.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ($1, $2, $3) returning id""",
    @[textParam(slug), textParam(name), textParam(timezone)]).get.getUuid("id")

proc newMember*(db: Db, communityId, userId: string; role = "member") =
  discard db.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, $3)""",
    @[textParam(communityId), textParam(userId), textParam(role)])

proc newPlayer*(db: Db, communityId, name: string; gender = "M", tier = "",
                userId = ""): string =
  ## `canonical_key` is a generated column, so only the display name is written
  ## here. Empty `tier` stays NULL instead of becoming a string the ladder does
  ## not know, and an empty `userId` leaves the player unclaimed.
  db.queryOne(
    """insert into player.players
         (community_id, canonical_name, gender, tier, user_id)
       values ($1::uuid, $2, $3, nullif($4, '')::text,
               nullif($5, '')::uuid)
       returning id""",
    @[textParam(communityId), textParam(name), textParam(gender),
      textParam(tier), textParam(userId)]).get.getUuid("id")

proc newSession*(db: Db, communityId, title: string; sessionDate = "",
                 startTime = "18:00", slotMinutes = 30, status = "draft",
                 source = "manual", approved = false): string =
  ## `approved = true` stamps `approved_at` together with the status, the same
  ## pair the write path produces. `sessionDate = ""` means today, which is
  ## what the ported fixtures used `current_date` for.
  db.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, start_time, slot_minutes,
          status, source, approved_at)
       values ($1::uuid, $2, coalesce(nullif($3, '')::date, current_date),
               $4::time, $5::int, $6, $7,
               case when $8 then now() else null end)
       returning id""",
    @[textParam(communityId), textParam(title), textParam(sessionDate),
      textParam(startTime), intParam(slotMinutes.int64), textParam(status),
      textParam(source), boolParam(approved)]).get.getUuid("id")

proc newGame*(db: Db, communityId, sessionId: string, roundNo, courtNo: int;
              sideA, sideB: openArray[string]; status = "scheduled",
              scoreA = -1, scoreB = -1) =
  ## Slots past the end of a side stay NULL, so a singles game writes only
  ## `side_a1` and `side_b1`. A negative score means "no score yet"; the column
  ## cannot hold one, and NULL is what a scheduled game really has. Sets are not
  ## written here: a suite that needs them states its own `session.game_sets`
  ## row, because a set and its game can differ and the reader joins them.
  let a1 = if sideA.len > 0: sideA[0] else: ""
  let a2 = if sideA.len > 1: sideA[1] else: ""
  let b1 = if sideB.len > 0: sideB[0] else: ""
  let b2 = if sideB.len > 1: sideB[1] else: ""
  let scoredA = if scoreA < 0: nullParam() else: intParam(scoreA.int64)
  let scoredB = if scoreB < 0: nullParam() else: intParam(scoreB.int64)
  discard db.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, score_a, score_b,
          status, side_a1, side_a2, side_b1, side_b2)
       values ($1::uuid, $2::uuid, $3::int, $4::int, $5, $6, $7,
               nullif($8, '')::uuid, nullif($9, '')::uuid,
               nullif($10, '')::uuid, nullif($11, '')::uuid)""",
    @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
      intParam(courtNo.int64), scoredA, scoredB, textParam(status),
      textParam(a1), textParam(a2), textParam(b1), textParam(b2)])

proc purgeCommunity*(db: Db, slug: string) =
  ## Removes one community and everything that names it, from the catalog
  ## instead of a list a test has to remember to extend. A hand-kept list was
  ## already 13 tables behind the schema, and the rows it left behind were what
  ## made suites depend on the order they ran in.
  ##
  ## The scope is the slug, never the table: each delete names the one community
  ## id, so a shared database loses nothing outside it. Community-scoped tables
  ## go first because several of them reference `platform.community` with
  ## `on delete restrict`; the cascade only has to tidy the rest.
  db.tx(proc(conn: DbConn) =
    let community = conn.queryOne(
      "select id from platform.community where slug = $1",
      @[textParam(slug)])
    if community.isNone:
      return
    let communityId = community.get.getUuid("id")
    for row in conn.query(
      """select c.table_schema || '.' || c.table_name as relation
         from information_schema.columns c
         join information_schema.tables t
           on t.table_schema = c.table_schema and t.table_name = c.table_name
         where c.column_name = 'community_id'
           and t.table_type = 'BASE TABLE'
           and c.table_schema not in ('pg_catalog', 'information_schema')
         order by 1"""):
      discard conn.execUpdate(
        "delete from " & row.get("relation") & " where community_id = $1::uuid",
        @[textParam(communityId)])
    # `cascade` covers a table that references this community without its own
    # `community_id` column; the statement is still scoped to the one id.
    discard conn.execUpdate(
      "delete from platform.community where id = $1::uuid cascade",
      @[textParam(communityId)]))