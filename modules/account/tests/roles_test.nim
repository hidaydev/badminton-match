import std/unittest
import ../domain/roles

suite "role ladder":
  test "rank is a domain fact, not the declaration order":
    check rank(rMember) == 1
    check rank(rHost) == 2
    check rank(rAdmin) == 3

  test "only a higher role is a promotion":
    # 9 pairs, the same verdict the old accept-invite ladder encoded in SQL.
    let roles = [rMember, rHost, rAdmin]
    let expected = [
      [false, true, true],
      [false, false, true],
      [false, false, false],
    ]
    for current in 0 ..< roles.len:
      for wanted in 0 ..< roles.len:
        checkpoint($roles[current] & " -> " & $roles[wanted])
        check promotes(roles[current], roles[wanted]) == expected[current][wanted]