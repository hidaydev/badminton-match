import std/[options, unittest]
import account/domain/roles
import ../src/auth_middleware
import ../src/community_context

proc actor(owner = false): Option[Actor] =
  some(Actor(userId: "u1", isPlatformOwner: owner, sessionToken: "t1"))

proc ctx(role: Role): Option[CommunityContext] =
  some(CommunityContext(communityId: "c1", slug: "demo", name: "Demo",
    role: role, timezone: "Asia/Jakarta"))

suite "authorization gate":
  test "public routes never need a session":
    check gate(Access(isPublic: true), none(Actor), none(CommunityContext)) == gAllowed

  test "missing session is 401 before any membership lookup":
    check gate(Access(isSession: true, roles: @[rMember]), none(Actor),
      none(CommunityContext)) == gUnauthenticated

  test "foreign community is 404, not 403":
    check gate(Access(isSession: true, roles: @[rMember]), actor(),
      none(CommunityContext)) == gNotFound

  test "member can read, host can write":
    let read = Access(isSession: true, roles: @[rMember])
    let write = Access(isSession: true, roles: @[rHost, rAdmin])
    check gate(read, actor(), ctx(rMember)) == gAllowed
    check gate(write, actor(), ctx(rMember)) == gForbidden
    check gate(write, actor(), ctx(rHost)) == gAllowed
    check gate(write, actor(), ctx(rAdmin)) == gAllowed

  test "platform owner bypasses management actions only":
    let management = Access(isSession: true, ownerOnly: true)
    check gate(management, actor(owner = true), none(CommunityContext)) == gAllowed
    check gate(management, actor(owner = false), none(CommunityContext)) == gForbidden
    let write = Access(isSession: true, roles: @[rHost, rAdmin])
    check gate(write, actor(owner = true), ctx(rMember)) == gForbidden

  test "status codes match the gate":
    check statusFor(gAllowed) == 200
    check statusFor(gUnauthenticated) == 401
    check statusFor(gForbidden) == 403
    check statusFor(gNotFound) == 404
