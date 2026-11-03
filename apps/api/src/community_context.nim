import std/[options]
import db/db
import account/domain/roles

type
  CommunityContext* = object
    ## The only way a route reaches community-scoped data. Built from a slug and
    ## a session; no slug, no membership and no role means no context at all.
    communityId*: string
    slug*: string
    name*: string
    role*: Role
    timezone*: string

proc loadCommunity*(db: Db, userId, slug: string): Option[CommunityContext] =
  ## Unknown slug and foreign membership are indistinguishable on purpose: both
  ## return none so the caller answers 404 and the route does not leak existence.
  let row = db.queryOne(
    """select c.id, c.slug, c.name, c.timezone, m.role
       from platform.community c
       join community.membership m
         on m.community_id = c.id and m.user_id = $2::uuid
       where c.slug = $1""",
    @[textParam(slug), textParam(userId)])
  if row.isNone:
    return none(CommunityContext)
  let value = row.get
  some(CommunityContext(
    communityId: value.get("id"),
    slug: value.get("slug"),
    name: value.get("name"),
    timezone: value.get("timezone"),
    role: parseRole(value.get("role")),
  ))
