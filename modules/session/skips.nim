import db/db

proc clearStaleSkips*(conn: DbConn, communityId, sessionId: string): int =
  ## A skip is scoped to a slot, so it stops meaning anything the moment the
  ## player it names is no longer in that game's four slots. A stale row is not
  ## harmless: the projection reads the skip and silently drops the player from a
  ## game he is in. Called after any write that can move players.
  conn.execUpdate(
    """delete from session.game_skips k
       where k.community_id = $1::uuid and k.session_id = $2::uuid
         and not exists (
           select 1 from session.games g
           where g.community_id = k.community_id
             and g.session_id = k.session_id
             and g.round_no = k.round_no
             and g.court_no = k.court_no
             and k.player_id in (g.side_a1, g.side_a2, g.side_b1, g.side_b2))""",
    @[textParam(communityId), textParam(sessionId)])