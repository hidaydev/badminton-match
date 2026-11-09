import std/[json, options]
import db/db
import platform/config/store
import rating/domain/rating as ratingDomain
import rating/infrastructure/ingest as ratingIngest
import rating/infrastructure/params as ratingParams

type
  MergeError* = enum
    meOk = "ok"
    mePlayerNotFound = "player_not_found"
    meSamePlayer = "same_player"
    mePairInUse = "pair_in_use"
    meSessionCollision = "session_collision"
    mePairCollision = "pair_collision"
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
    sessionsMoved*: int
    gamesMoved*: int
    skipsMoved*: int
    teamPlayersMoved*: int

  MergeOutcome* = object
    error*: MergeError
    result*: MergeResult

proc totalRows(values: MergeResult): int =
  values.aliasesMoved + values.claimsMoved + values.deltasMoved +
    values.snapshotsMoved + values.achievementsMoved + values.pairsMoved +
    values.ratingStateMoved + values.sessionsMoved + values.gamesMoved +
    values.skipsMoved + values.teamPlayersMoved

proc loadParams(db: Db, communityId: string): ratingDomain.RatingParams =
  ## The same numbers every rating route reads. The merge can move games that
  ## already fed the counters, so it must be able to replay the ledger; reading
  ## them here keeps the signature stable for the route.
  let snapshot = loadSnapshot(db)
  let stored = db.queryOne(
    "select values::text as values from community.settings where community_id = $1::uuid",
    @[textParam(communityId)])
  let settings =
    if stored.isSome: parseJson(stored.get.get("values")) else: newJObject()
  loadRatingParams(snapshot, settings)

proc merge*(db: Db, communityId, targetId, sourceId, actorId: string): MergeOutcome =
  ## Moves every row that names the source player onto the target and deletes the
  ## source. Where both players already own a row in the same slot the target
  ## wins: the duplicate source row is dropped (aliases, snapshots, achievements,
  ## skips, roster spots) or closed (claims), so nothing is silently double
  ## counted. A game naming both players cannot be split, so a merge that meets
  ## itself on one side is refused instead. Two pairs that would end up with the
  ## same partner inside one tournament are refused as well, since they would
  ## become the same pair.
  result.error = meOk
  if targetId == sourceId:
    result.error = meSamePlayer
    return
  let params = loadParams(db, communityId)

  var outcome: MergeOutcome
  try:
    db.tx(proc(conn: DbConn) =
      let locked = conn.query(
        """select id from player.players
           where community_id = $1::uuid and id in ($2::uuid, $3::uuid)
           for update""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)]).len
      if locked != 2:
        outcome.error = mePlayerNotFound
        return

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
          return

      # Two pairs that share the same partner become the same pair once both
      # merged players land on the target: (target, X) twice, which the
      # tournament would count twice. A self-pair cannot match here, because
      # its partner is the other merged player, so the equality below only
      # finds real duplicates and refuses them before the first write.
      let pairCollision = conn.queryOne(
        """select 1 as found
           from tournament.pairs s
           join tournament.pairs t
             on t.community_id = s.community_id
            and t.tournament_id = s.tournament_id and t.id <> s.id
           where s.community_id = $1::uuid
             and (s.player_a_id = $2::uuid or s.player_b_id = $2::uuid)
             and (t.player_a_id = $3::uuid or t.player_b_id = $3::uuid)
             and case when s.player_a_id = $2::uuid then s.player_b_id
                      else s.player_a_id end
               = case when t.player_a_id = $3::uuid then t.player_b_id
                      else t.player_a_id end
           limit 1""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      if pairCollision.isSome:
        outcome.error = mePairCollision
        return

      outcome.result.targetPlayerId = targetId
      outcome.result.sourcePlayerId = sourceId

      # A game that lists both players would turn into a self-match once the
      # source rows become the target's. No rewrite can split such a game, so
      # the merge is refused here, before the first write.
      let sessionCollision = conn.queryOne(
        """select 1 as found from session.games
           where community_id = $1::uuid
             and $2::uuid in (side_a1, side_a2, side_b1, side_b2)
             and $3::uuid in (side_a1, side_a2, side_b1, side_b2)
           limit 1""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      if sessionCollision.isSome:
        outcome.error = meSessionCollision
        return

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

      # Snapshots and achievements share a uniqueness key with the player id,
      # so a target row in the same slot wins over the source row. The rating
      # ledger is gone, so there is no per-game row left to move.
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

      var movedPairs: seq[string] = @[]
      for pair in conn.query(
        """select id from tournament.pairs
           where community_id = $1::uuid
             and (player_a_id = $2::uuid or player_b_id = $2::uuid)""",
        @[textParam(communityId), textParam(sourceId)]):
        movedPairs.add(pair.get("id"))
      outcome.result.pairsMoved = conn.execUpdate(
        """update tournament.pairs set player_a_id = $2::uuid
           where community_id = $1::uuid and player_a_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      outcome.result.pairsMoved += conn.execUpdate(
        """update tournament.pairs set player_b_id = $2::uuid
           where community_id = $1::uuid and player_b_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      # The display name is what the bracket shows; it still named the source.
      for pairId in movedPairs:
        let names = conn.queryOne(
          """select a.canonical_name as a_name, b.canonical_name as b_name
             from tournament.pairs p
             join player.players a
               on a.community_id = p.community_id and a.id = p.player_a_id
             join player.players b
               on b.community_id = p.community_id and b.id = p.player_b_id
             where p.community_id = $1::uuid and p.id = $2::uuid""",
          @[textParam(communityId), textParam(pairId)])
        if names.isSome:
          discard conn.execUpdate(
            """update tournament.pairs set display_name = $3
               where community_id = $1::uuid and id = $2::uuid""",
            @[textParam(communityId), textParam(pairId),
              textParam(names.get.get("a_name") & " & " & names.get.get("b_name"))])

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

      # Session history now belongs to the target. A game points at the
      # participant row of its session, so the rows move in this order: give
      # the target a participant row in every session it does not attend yet,
      # rewrite the games, then drop the source participant rows. Moving a
      # participant row first would break the games that still name it.
      outcome.result.sessionsMoved = conn.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id, is_absent)
           select p.community_id, p.session_id, $2::uuid, p.is_absent
           from session.participants p
           where p.community_id = $1::uuid and p.player_id = $3::uuid
             and not exists (select 1 from session.participants t
                             where t.session_id = p.session_id
                               and t.player_id = $2::uuid)""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      # The collision check above guarantees the target is absent from every
      # game the source plays, so no slot can end up naming it twice.
      outcome.result.gamesMoved = conn.execUpdate(
        """update session.games
              set side_a1 = case when side_a1 = $3::uuid then $2::uuid else side_a1 end,
                  side_a2 = case when side_a2 = $3::uuid then $2::uuid else side_a2 end,
                  side_b1 = case when side_b1 = $3::uuid then $2::uuid else side_b1 end,
                  side_b2 = case when side_b2 = $3::uuid then $2::uuid else side_b2 end
            where community_id = $1::uuid
              and $3::uuid in (side_a1, side_a2, side_b1, side_b2)""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      # Whatever participant row is left names a session the target already
      # attends, and its games were rewritten above.
      discard conn.execUpdate(
        """delete from session.participants
           where community_id = $1::uuid and player_id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)])

      # A skip is keyed by session, round and court, so a source skip collides
      # with the target's own skip for the same game and is dropped first.
      discard conn.execUpdate(
        """delete from session.game_skips s
           where s.community_id = $1::uuid and s.player_id = $2::uuid
             and exists (select 1 from session.game_skips t
                         where t.community_id = $1::uuid
                           and t.session_id = s.session_id
                           and t.round_no = s.round_no
                           and t.court_no = s.court_no
                           and t.player_id = $3::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      outcome.result.skipsMoved = conn.execUpdate(
        """update session.game_skips set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])

      # A player holds one roster spot per team, so the target keeps its own.
      discard conn.execUpdate(
        """delete from tournament.team_players s
           where s.community_id = $1::uuid and s.player_id = $2::uuid
             and exists (select 1 from tournament.team_players t
                         where t.community_id = $1::uuid
                           and t.team_id = s.team_id
                           and t.player_id = $3::uuid)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId)])
      outcome.result.teamPlayersMoved = conn.execUpdate(
        """update tournament.team_players set player_id = $2::uuid
           where community_id = $1::uuid and player_id = $3::uuid""",
        @[textParam(communityId), textParam(targetId), textParam(sourceId)])
      # The roster renders the stored name, not the player row, so the spots
      # that just changed owner must stop showing the deleted player's name.
      discard conn.execUpdate(
        """update tournament.team_players tp
           set player_name = p.canonical_name
           from player.players p
           where tp.community_id = $1::uuid and tp.player_id = $2::uuid
             and p.community_id = tp.community_id and p.id = tp.player_id""",
        @[textParam(communityId), textParam(targetId)])

      discard conn.execUpdate(
        """delete from player.players
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sourceId)])

      # The rewritten games now name the target, so the counters derived from
      # them have to be replayed. Moving one state row and deleting the other
      # left `games_played` smaller than the history behind it.
      discard ratingIngest.rebuildConn(conn, communityId, params)

      discard conn.execUpdate(
        """insert into player.merge_log
             (community_id, source_id, target_id, rows_moved, actor_id, rebuilt)
           values ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, true)""",
        @[textParam(communityId), textParam(sourceId), textParam(targetId),
          intParam(totalRows(outcome.result).int64), textParam(actorId)]))
  except DbError as error:
    # The transaction rolled back, so neither player changed. A constraint
    # violation means the two players cannot be combined cleanly.
    if error.sqlState.len >= 2 and error.sqlState[0 .. 1] == "23":
      outcome.error = meConflict
      return outcome
    raise

  outcome
