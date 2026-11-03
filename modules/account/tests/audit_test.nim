import std/[json, unittest]
import ../domain/audit

suite "audit evidence":
  test "keeps allow-listed scalar fields":
    let evidence = sanitizeEvidence(%*{
      "slug": "demo-club", "status": "draft", "version": 3,
    })
    check evidence["slug"].getStr() == "demo-club"
    check evidence["status"].getStr() == "draft"
    check evidence["version"].getInt() == 3

  test "drops fields that are not allow-listed":
    let evidence = sanitizeEvidence(%*{"email": "a@b.c", "slug": "x"})
    check not evidence.hasKey("email")
    check evidence.hasKey("slug")

  test "drops nested objects and arrays":
    let evidence = sanitizeEvidence(%*{
      "slug": "x", "name": {"nested": "value"}, "count": [1, 2],
    })
    check evidence.len == 1
    check evidence.hasKey("slug")

  test "forbid rejects secret-bearing names":
    check forbid("shareCode")
    check forbid("email")
    check forbid("clientIp")
    check forbid("ticket")
    check not forbid("slug")

  test "event without evidence serialises empty objects":
    let event = auditEvent("community.create", "c1", actorId = "u1",
      actorRole = "admin", targetKind = "community", targetId = "c1")
    let sanitized = sanitizeEvidence(event.after)
    check sanitized.kind == JObject
    check sanitized.len == 0
