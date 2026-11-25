## `./task account anonymize` under the 0061 policy set.
##
## The tool connects as `bm2_app` and used to build its community list from
## `player.claims`, `player.players` and `community.membership` on the raw
## connection. All three carry `tenant_isolation`, and a statement with no tenant
## declared sees no row, so the list came back empty: claims were never released,
## players never unlinked, membership never deleted, and the tool still printed
## success. The account could not sign in again, its sessions were gone, the audit
## row existed — and the anonymised identity was still an admin of its community,
## which also keeps `soleAdmin` refusing every demotion there.
##
## The suite therefore runs the tool path as `bm2_app` and asserts the end state
## through scoped facades, not through the owner's connection: on a superuser DSN
## every one of these statements matches rows whether the fix is present or not,
## which is exactly why the old suite (`lifecycle_test.nim`) stayed green.
##
## The victim is admin in TWO communities, and the pending claim sits in the one
## that does not sort last, so a fix that only handles one community fails here.
##
## The precondition is an assertion: a green run on a policy-free database proves
## nothing for this file.
import std/[options, os, unittest]
import db/db
import sha256
import account/infrastructure/lifecycle_store
import tests/fixtures
import tests/app_role_fixture

const
  slugA = "policy-life-a"
  slugB = "policy-life-b"
  victimSub = "policy-life-victim"
  actorSub = "policy-life-actor"
  reason = "account_anonymized"

var
  database: Db
  communityA, communityB, victimId, actorId: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc cleanup() =
  for slug in [slugA, slugB]:
    purgeCommunity(database, slug)
  # The victim's sub is rewritten to sha256(sub) by the run, so both shapes have
  # to go or a second run starts from an already-anonymised account.
  discard database.execUpdate(
    """delete from account.audit where actor_id in
         (select id from platform.user where google_sub like 'policy-life-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'policy-life-%'")
  discard database.execUpdate(
    "delete from platform.user where google_sub = $1",
    @[textParam(sha256Hex(victimSub))])

proc seed() =
  communityA = newCommunity(database, slugA, "Policy Life A")
  communityB = newCommunity(database, slugB, "Policy Life B")
  actorId = newUser(database, actorSub, "policy-life-actor@example.com", "Actor",
    owner = true)
  victimId = newUser(database, victimSub, "policy-life-victim@example.com",
    "Leaving Person")
  # Admin in both: the row the tool failed to delete is the one that keeps an
  # anonymised identity in charge of a community.
  newMember(database, communityA, victimId, "admin")
  newMember(database, communityB, victimId, "admin")

  let playerA = newPlayer(database, communityA, "Linked Player",
    userId = victimId)
  # One decided claim, which must become `released`, and one pending claim in the
  # other community, which must become `rejected` and carry the reason.
  discard database.execUpdate(
    """insert into player.claims
         (community_id, player_id, user_id, status, decided_by, decided_at, reason)
       values ($1::uuid, $2::uuid, $3::uuid, 'approved', $4::uuid, now(), 'seed')""",
    @[textParam(communityA), textParam(playerA), textParam(victimId),
      textParam(actorId)])
  let playerB = newPlayer(database, communityB, "Pending Player",
    userId = victimId)
  discard newClaim(database, communityB, playerB, victimId)

proc countIn(scoped: Db, sql: string, communityId, userId: string): int =
  scoped.queryOne(sql, @[textParam(communityId), textParam(userId)])
    .get.getInt("n")

database = openDb(dsn(), 1)
let policiesOn = database.queryOne(
  """select count(*)::int as n from pg_policies
     where schemaname = 'community' and tablename = 'membership'""").get.getInt("n") > 0
doAssert policiesOn, "policy_lifecycle needs a database with the 0061 policy " &
  "set; run it in the job that applies 0061 (./task policy-test)"
cleanup()
seed()

suite "anonymize under the policy set":
  test "membership, claims and player links are gone in every community":
    var outcome = lrOk
    var membership, openClaims, linkedPlayers: seq[int]
    var auditRows = 0
    var rewritten = ""
    asApp(database, proc(app: Db, conn: DbConn) =
      outcome = anonymize(app, victimId, actorId, reason)
      for communityId in [communityA, communityB]:
        let scoped = app.scoped(communityId)
        membership.add countIn(scoped,
          """select count(*)::int as n from community.membership
             where community_id = $1::uuid and user_id = $2::uuid""",
          communityId, victimId)
        openClaims.add countIn(scoped,
          """select count(*)::int as n from player.claims
             where community_id = $1::uuid and user_id = $2::uuid
               and status in ('approved', 'pending')""",
          communityId, victimId)
        linkedPlayers.add countIn(scoped,
          """select count(*)::int as n from player.players
             where community_id = $1::uuid and user_id = $2::uuid""",
          communityId, victimId)
      # The evidence is a platform-level row: `community_id is null` is what 0061
      # allows on purpose, and it must stay that way.
      auditRows = app.queryOne(
        """select count(*)::int as n from account.audit
           where action = 'account.anonymize' and target_id = $1
             and community_id is null""",
        @[textParam(victimId)]).get.getInt("n")
      rewritten = app.queryOne(
        "select google_sub from platform.user where id = $1::uuid",
        @[textParam(victimId)]).get.get("google_sub"))

    check outcome == lrOk
    # Before the fix these were 1/1, 1/1 and 1/1 while the tool printed ok.
    check membership == @[0, 0]
    check openClaims == @[0, 0]
    check linkedPlayers == @[0, 0]
    check auditRows == 1
    # The identity rewrite is the part that always landed; asserting it keeps the
    # suite from passing on a run that did nothing at all.
    check rewritten == sha256Hex(victimSub)

  teardown:
    cleanup()
