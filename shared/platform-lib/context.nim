import std/[options, times]

type
  Role* = enum
    roleNone
    roleMember
    roleHost
    roleAdmin
    rolePlatformOwner

  UserId* = distinct string
  CommunityId* = distinct string

  Ctx* = object
    ## Per-request context. Passed explicitly; never stored in a threadvar.
    requestId*: string
    userId*: Option[UserId]
    communityId*: Option[CommunityId]
    role*: Role
    clientIp*: string
    now*: DateTime

proc `$`*(id: UserId): string {.borrow.}
proc `$`*(id: CommunityId): string {.borrow.}
