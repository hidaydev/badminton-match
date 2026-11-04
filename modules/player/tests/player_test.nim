import std/[json, options, unittest]
import ../domain/player

suite "player domain":
  test "names are trimmed and whitespace is collapsed":
    check normalizeName("  Ani   Lestari ") == "Ani Lestari"
    check normalizeName("\tBudi\n") == "Budi"

  test "tertiary tiers keep their plus sign":
    check $parseTier("B+") == "B+"
    check $parseTier("D") == "D"
    expect ValueError:
      discard parseTier("E")

  test "gender accepts lower case but stores the canonical letter":
    check $parseGender("f") == "F"
    check $parseGender("M") == "M"
    expect ValueError:
      discard parseGender("female")

  test "create check reports every problem at once":
    check checkCreate("", "X", "Z") == @[ppName, ppGender, ppTier]
    check checkCreate("Ani", "F", "").len == 0

  test "a patch without a tier leaves it alone":
    let patch = parsePatch(%*{"name": "Ani"})
    check patch.name == some("Ani")
    check patch.tier.isNone
    check not patch.clearTier

  test "an explicit null clears the tier":
    let patch = parsePatch(%*{"tier": newJNull()})
    check patch.clearTier
    check patch.tier.isNone

  test "a patch with a tier sets it":
    check parsePatch(%*{"tier": "A+"}).tier == some(tAPlus)
