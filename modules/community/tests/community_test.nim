import std/[json, options, unittest]
import ../domain/community

suite "community domain":
  test "slugs normalise to the global form":
    check normalizeSlug("  Demo Club ") == "demo-club"
    check normalizeSlug("demo__club") == "demo-club"
    check normalizeSlug("A-b") == "a-b"

  test "unusable slugs are rejected instead of silently rewritten":
    expect ValueError:
      discard normalizeSlug("demo/club")
    expect ValueError:
      discard normalizeSlug("a")
    expect ValueError:
      discard normalizeSlug("--")

  test "create requires a slug, a name and an admin email":
    let missing = checkCreate("", "", "", "Asia/Jakarta", none(string))
    check cpInvalidSlug in missing.problems
    check cpInvalidName in missing.problems
    check cpInvalidAdminEmail in missing.problems

  test "the timezone defaults to the registry value":
    let check = checkCreate("demo-club", "Demo", "admin@example.com",
      "Asia/Jakarta", none(string))
    check check.problems.len == 0
    check check.timezone == "Asia/Jakarta"
    check checkCreate("demo-club", "Demo", "admin@example.com",
      "Asia/Jakarta", some("Asia/Makassar")).timezone == "Asia/Makassar"

  test "email validation rejects obvious noise":
    check validEmail("admin@example.com")
    check not validEmail("admin")
    check not validEmail("admin@localhost")
    check not validEmail("a b@example.com")

  test "the directory is opt-in and members-only":
    check not directoryVisible(false, true)
    check not directoryVisible(true, false)
    check directoryVisible(true, true)
    check not directoryEnabled(false, newJObject(), "community.directory_enabled")
    check directoryEnabled(false,
      %*{"community.directory_enabled": true}, "community.directory_enabled")

  test "a directory entry carries only the slug and the name":
    let entry = directoryEntry("demo-club", "Demo Club")
    check entry.len == 2
    check entry["slug"].getStr() == "demo-club"
    check entry["name"].getStr() == "Demo Club"
