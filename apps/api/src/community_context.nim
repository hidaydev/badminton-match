import std/[json, options]
import db/db
import account/domain/roles
import community/infrastructure/community_store

type
  CommunityContext* = object
    ## The only way a route reaches community-scoped data. Built from a slug and
    ## a session; no slug, no membership and no role means no context at all.
    communityId*: string
    slug*: string
    name*: string
    role*: Role
    timezone*: string
    ## The community's overrides, read once while the context is built, so every
    ## helper in one request sees the same values and pays no second query.
    settings*: JsonNode

proc loadCommunity*(db: Db, userId, slug: string): Option[CommunityContext] =
  ## Unknown slug and foreign membership are indistinguishable on purpose: both
  ## return none so the caller answers 404 and the route does not leak existence.
  ##
  ## This is the one read that *produces* the community context, so it runs
  ## before any tenant is installed. `community.membership` is the privilege
  ## table, and step 2's policy set leaves it without one, so the join below
  ## stays the identity check under the policy set: the definer function takes
  ## its place once installed, and both paths answer zero rows for an unknown
  ## slug and for a foreign user alike. The choice is per call, never cached, so
  ## a process that started before the migration cannot keep reading through the
  ## path the migration was meant to close.
  var row: Option[Row] = none(Row)
  if db.functionExists("community.membership_context(text,uuid)"):
    row = db.queryOne(
      """select id, slug, name, timezone, role
         from community.membership_context($1, $2::uuid)""",
      @[textParam(slug), textParam(userId)])
  else:
    row = db.queryOne(
      """select c.id, c.slug, c.name, c.timezone, m.role
         from platform.community c
         join community.membership m
           on m.community_id = c.id and m.user_id = $2::uuid
         where c.slug = $1""",
      @[textParam(slug), textParam(userId)])
  if row.isNone:
    return none(CommunityContext)
  let value = row.get
  let communityId = value.get("id")
  some(CommunityContext(
    communityId: communityId,
    slug: value.get("slug"),
    name: value.get("name"),
    timezone: value.get("timezone"),
    role: parseRole(value.get("role")),
    # `community.settings` carries the tenant policy, so the read has to declare
    # the community it was just resolved for. On the plain pool it returns no
    # row under the policy set, `settingsFrom(none)` yields `{}`, and every
    # override a community configured silently reverts to the platform default
    # on every `/c/{slug}` request.
    settings: currentSettings(db.scoped(communityId), communityId),
  ))
