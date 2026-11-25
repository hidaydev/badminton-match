## The two `./task sharekeys` data tools under the 0061 policy set.
##
## Both read and wrote `session.links` on the plain pool. Under the policy set a
## statement with no tenant declared sees no row, so:
##
##   - `retire-legacy` reported "bounded 0 ... retired 0" and left the row
##     `legacy_id_ok = true, expires_at = null`, a permanent public capability.
##   - `rotate --dry-run` reported "0 link(s) would move", which is the exact
##     number an operator reads before retiring a key. `SHARE_CODE_KEYS` is the
##     only copy of those keys, so acting on that zero makes every live link
##     sealed with the key permanently unreadable.
##
## The suite runs both paths as `bm2_app` with no tenant preset, then asserts the
## end state through a scoped facade. On the owner DSN every one of these
## statements matches rows whether the fix is present or not, which is why the
## existing `links_test.nim` stayed green.
##
## The precondition is an assertion: a green run on a policy-free database proves
## nothing for this file.
import std/[options, os, unittest]
import db/db
import share/crypto
import share/store
import tests/fixtures
import tests/app_role_fixture

const
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","2":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}"""
  slug = "policy-share-tools"
  hostSub = "policy-share-host"

var
  database: Db
  keyring: Keyring
  communityId, hostId, legacySession, sealedSession: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc cleanup() =
  purgeCommunity(database, slug)
  discard database.execUpdate(
    "delete from platform.user where google_sub = $1", @[textParam(hostSub)])

database = openDb(dsn(), 1)
let policiesOn = database.queryOne(
  """select count(*)::int as n from pg_policies
     where schemaname = 'session' and tablename = 'links'""").get.getInt("n") > 0
doAssert policiesOn, "policy_share_tools needs a database with the 0061 policy " &
  "set; run it in the job that applies 0061 (./task policy-test)"
keyring = loadKeyring(keysJson, "2")
cleanup()

proc seed() =
  ## One legacy row with no expiry and old enough for a 30 day window, and one
  ## ordinary row sealed with key 1.
  cleanup()
  communityId = newCommunity(database, slug, "Policy Share Tools")
  hostId = newUser(database, hostSub, "policy-share@example.com", "Host")
  legacySession = newSession(database, communityId, "Legacy", status = "locked")
  sealedSession = newSession(database, communityId, "Sealed", status = "locked")
  discard issue(database, loadKeyring(keysJson, "1"), communityId,
    legacySession, hostId, 30)
  discard issue(database, loadKeyring(keysJson, "1"), communityId, sealedSession,
    hostId, 30)
  discard database.execUpdate(
    """update session.links
       set legacy_id_ok = true, expires_at = null,
           created_at = now() - interval '40 days'
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(legacySession)])

proc linkState(): tuple[legacyOpen, keyOne, keyTwo: int] =
  ## Read through a scoped facade, the way a caller that knows its tenant reads.
  let scoped = database.scoped(communityId)
  result.legacyOpen = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and legacy_id_ok and expires_at is null""",
    @[textParam(communityId)]).get.getInt("n")
  result.keyOne = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and key_id = '1'""",
    @[textParam(communityId)]).get.getInt("n")
  result.keyTwo = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and key_id = '2'""",
    @[textParam(communityId)]).get.getInt("n")

proc appLinkState(app: Db): tuple[legacyOpen, keyOne, keyTwo: int] =
  ## The same three counts on the facade the tool runs on, inside the transaction
  ## `asApp` rolls back: a probe outside it would read the pre-run state.
  let scoped = app.scoped(communityId)
  result.legacyOpen = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and legacy_id_ok and expires_at is null""",
    @[textParam(communityId)]).get.getInt("n")
  result.keyOne = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and key_id = '1'""",
    @[textParam(communityId)]).get.getInt("n")
  result.keyTwo = scoped.queryOne(
    """select count(*)::int as n from session.links
       where community_id = $1::uuid and key_id = '2'""",
    @[textParam(communityId)]).get.getInt("n")

suite "share tool sweeps under the policy set":
  test "retire-legacy bounds and retires the row, then finds nothing":
    seed()
    var first, second: LegacyRetirement
    var state: tuple[legacyOpen, keyOne, keyTwo: int]
    asApp(database, proc(app: Db, conn: DbConn) =
      first = retireLegacy(app, 30)
      # The second-run property the tool promises an operator: a sweep that fixes
      # nothing must say 0, not report the same work twice.
      second = retireLegacy(app, 30)
      state = appLinkState(app))
    # Before the fix: bounded 0, retired 0, and the row kept `expires_at = null`.
    check first.bounded == 1
    check first.retired == 1
    check second.bounded == 0
    check second.retired == 0
    check state.legacyOpen == 0

  test "rotate reports the row it will move and really moves it":
    seed()
    # Retire the legacy row first so the rotation count is the sealed row alone.
    discard database.execUpdate(
      """delete from session.links
         where community_id = $1::uuid and legacy_id_ok""",
      @[textParam(communityId)])
    var planned, moved, again = 0
    var state: tuple[legacyOpen, keyOne, keyTwo: int]
    asApp(database, proc(app: Db, conn: DbConn) =
      # The number an operator trusts before retiring a key.
      planned = rotateKeys(app, keyring, "1", "2", dryRun = true)
      moved = rotateKeys(app, keyring, "1", "2")
      again = rotateKeys(app, keyring, "1", "2")
      state = appLinkState(app))
    # Before the fix the dry run said 0 while one row still carried key 1.
    check planned == 1
    check moved == 1
    check again == 0
    check state.keyOne == 0
    check state.keyTwo == 1
    # Rolled back by `asApp`, so the next case still starts from two sealed rows.
    check linkState().keyOne == 1

  teardown:
    cleanup()
