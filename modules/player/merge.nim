import std/options
import db/db

type
  MergeError* = enum
    meOk = "ok"
    mePlayerNotFound = "player_not_found"
    meSamePlayer = "same_player"
    mePairInUse = "pair_in_use"
    meConflict = "merge_conflict"

  MergeResult* = object
    targetPlayerId*: string
    sourcePlayerId*: string
    aliasesMoved*: int
    claimsMoved*: int
    deltasMoved*: int
    snapshotsMoved*: int
    achievementsMoved*: int
    pairsMoved*: int
    ratingStateMoved*: int

  MergeOutcome* = object
    error*: MergeError
    result*: MergeResult

proc totalRows(values: MergeResult): int =
  values.aliasesMoved + values.claimsMoved + values.deltasMoved +
    values.snapshotsMoved + values.achievementsMoved + values.pairsMoved +
    values.ratingStateMoved

proc merge*(db: Db, communityId, targetId, sourceId, actorId: string): MergeOutcome =
  ## Moves every row that names the source player onto the target and deletes the
  ## source. Where both players already own a row in the same slot the target
  ## wins: the duplicate source row is dropped (aliases, rating, achievements) or
  ## closed (claims), so nothing is silently double counted.
  result.error = meOk
  if targetId == sourceId:
    result.error = meSamePlayer
    return

  var outcome: MergeOutcome
  try:
    discard db.tx(proc(conn: DbConn): int =
      let locked = conn.query(
        """select id from player.players
           where community_id = $1::uuid and id in ($2::uuid, $3::uuid)
           for update""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)]).len
      if locked != 2:
        outcome.error = mePlayerNotFound
        return 0

      # A pair naming both merged players becomes a self-pair. It can only be
      # dropped while no match refers to it; otherwise the merge is refused.
      # The check must run before the first write: returning from inside `tx`
      # commits, so a late refusal would leave rows already moved.
      let selfPairs = conn.query(
        """select id from tournament.pairs
           where community_id = $1::uuid
             and ((player_a_id = $2::uuid and player_b_id = $3::uuid)
               or (player_a_id = $3::uuid and player_b_id = $2::uuid))
           for update""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      for pair in selfPairs:
        let used = conn.queryOne(
          """select 1 as found from tournament.matches
             where community_id = $1::uuid
               and (pair_a_id = $2::uuid or pair_b_id = $2::uuid) limit 1""",
          @[textParam(communityId), textParam(pair.get("id"))])
        if used.isSome:
          outcome.error = mePairInUse
          return 0

      outcome.result.targetPlayerId = targetId
      outcome.result.sourcePlayerId = sourceId

      # Aliases are unique per community, so the source row blocks an insert of
      # the same key for the target. Drop the duplicates first, then re-own the
      # rest, which leaves the alias text and key untouched.
      discard conn.execUpdate(
        """delete from player.aliases s
           where s.community_id = $1::uuid and s.player_id = $3::uuid
             and exists (select 1 from player.aliases t
                         where t.community_id = $1::uuid
                           and t.player_id = $2::uuid
                           and t.alias_key = s.alias_key)""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      outcome.result.aliasesMoved = conn.execUpdate(
        """update player.aliases set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      # Claims: a second approval or a second pending claim cannot survive the
      # move, so the source copy is closed before the rows change owner.
      discard conn.execUpdate(
        """update player.claims c
           set status = 'released', reason = 'merged',
               decided_by = $4::uuid, decided_at = now()
           where c.community_id = $1::uuid and c.player_id = $2::uuid
             and c.status = 'approved'
             and exists (select 1 from player.claims t
                         where t.community_id = $1::uuid
                           and t.player_id = $3::uuid
                           and t.status = 'approved')""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId),
          textParam(actorId)])
      discard conn.execUpdate(
        """update player.claims c
           set status = 'rejected', reason = 'merged',
               decided_by = $4::uuid, decided_at = now()
           where c.community_id = $1::uuid and c.player_id = $2::uuid
             and c.status = 'pending'
             and exists (select 1 from player.claims t
                         where t.community_id = $1::uuid
                           and t.player_id = $3::uuid
                           and t.status = 'pending')""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId),
          textParam(actorId)])
      outcome.result.claimsMoved = conn.execUpdate(
        """update player.claims set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      # Rating deltas, snapshots and achievements share a uniqueness key with the
      # player id, so a target row in the same slot wins over the source row.
      discard conn.execUpdate(
        """delete from rating.deltas s
           where s.community_id = $1::uuid and s.player_id = $2::uuid
             and exists (select 1 from rating.deltas t
                         where t.community_id = $1::uuid
                           and t.event_id = s.event_id and t.side = s.side
                           and t.player_id = $3::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      outcome.result.deltasMoved = conn.execUpdate(
        """update rating.deltas set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      discard conn.execUpdate(
        """delete from rating.snapshots s
           where s.community_id = $1::uuid and s.player_id = $2::uuid
             and exists (select 1 from rating.snapshots t
                         where t.community_id = $1::uuid
                           and t.taken_on = s.taken_on
                           and t.player_id = $3::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      outcome.result.snapshotsMoved = conn.execUpdate(
        """update rating.snapshots set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      discard conn.execUpdate(
        """delete from achievement.earned s
           where s.community_id = $1::uuid and s.player_id = $2::uuid
             and exists (select 1 from achievement.earned t
                         where t.community_id = $1::uuid
                           and t.achievement_key = s.achievement_key
                           and t.player_id = $3::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      outcome.result.achievementsMoved = conn.execUpdate(
        """update achievement.earned set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      # The self-pairs were checked above; they hold no matches, so dropping
      # them cannot violate a match reference.
      for pair in selfPairs:
        discard conn.execUpdate(
          """delete from tournament.pairs
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(pair.get("id"))])

      outcome.result.pairsMoved = conn.execUpdate(
        """update tournament.pairs set player_a_id = $2::uuid
           where community_id = $1::uuid and player_a_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      outcome.result.pairsMoved += conn.execUpdate(
        """update tournament.pairs set player_b_id = $2::uuid
           where community_id = $1::uuid and player_b_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      # A derived rating row is only useful if the target has none; otherwise the
      # source copy is stale by definition and gets dropped.
      outcome.result.ratingStateMoved = conn.execUpdate(
        """update rating.player_state set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid
             and not exists (select 1 from rating.player_state t
                             where t.community_id = $1::uuid
                               and t.player_id = $2::uuid)""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      discard conn.execUpdate(
        """delete from rating.player_state
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)])

      discard conn.execUpdate(
        """delete from player.players
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)])

      discard conn.execUpdate(
        """insert into player.merge_log
             (community_id, source_id, target_id, rows_moved, actor_id)
           values ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId),
          intParam(totalRows(outcome.result).int64), textParam(actorId)])
      1)
  except DbError as error:
    # The transaction rolled back, so neither player changed. A constraint
    # violation means the two players cannot be combined cleanly.
    if error.sqlState.len >= 2 and error.sqlState[0 .. 1] == "23":
      outcome.error = meConflict
      return outcome
    raise

  outcome
